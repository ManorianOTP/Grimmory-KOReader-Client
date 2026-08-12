--[[
  Token lifecycle spec for grimmory.koplugin/session.lua.

  Drives the dispatcher against a scripted API double (no HTTP: the wire
  contract is api_spec.lua's job) and asserts the state machine the device
  depends on: dispatch gates, pre-emptive refresh, the 401 -> silent
  renewal -> single retry path, token clearing on unrecoverable failure,
  and the single-flight refresh guard.
]]
local spec_helper = require("spec_helper")

describe("Session", function()
    local Session, LuaSettings, DataStorage

    local SERVER = "http://srv"

    before_each(function()
        spec_helper.setup()
        Session = require("session")
        LuaSettings = require("luasettings")
        DataStorage = require("datastorage")
    end)

    after_each(function()
        spec_helper.teardown()
    end)

    -- API double: responses are consumed queues; every call is recorded.
    local function make_api()
        local api = { calls = {}, books_queue = {}, refresh_queue = {} }
        function api:getBooks(server_url, token)
            table.insert(api.calls, { method = "getBooks", server_url = server_url, token = token })
            local r = table.remove(api.books_queue, 1) or { result = {} }
            return r.result, r.err
        end
        function api:refreshToken(server_url, refresh_token)
            table.insert(api.calls, { method = "refreshToken", refresh_token = refresh_token })
            local r = table.remove(api.refresh_queue, 1) or {}
            return r.access, r.refresh, r.err
        end
        function api:downloadBookFile(server_url, book_id, file_id, token,
                dest_path, expected_size_kb)
            table.insert(api.calls, {
                method = "downloadBookFile",
                server_url = server_url,
                book_id = book_id,
                file_id = file_id,
                token = token,
                dest_path = dest_path,
                expected_size_kb = expected_size_kb,
            })
            return true, nil
        end
        -- Present on the API but absent from METHOD_ARG_LAYOUT (G2 test).
        function api:unmappedMethod() end
        return api
    end

    -- ctx: { session, api, settings, expired() }
    local function make_ctx(tokens, now)
        local settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/grimmory.lua")
        if tokens then
            settings:saveSetting("token", tokens.token)
            settings:saveSetting("refresh_token", tokens.refresh_token)
            settings:saveSetting("token_time", tokens.token_time)
            settings:flush()
        end
        local api = make_api()
        local expired_count = 0
        local session = Session.new{
            settings = settings,
            api = api,
            on_expired = function() expired_count = expired_count + 1 end,
            now = now,
        }
        return {
            session = session,
            api = api,
            settings = settings,
            expired = function() return expired_count end,
        }
    end

    local function fresh_tokens()
        return { token = "t1", refresh_token = "r1", token_time = os.time() }
    end

    -- Older than the 50-minute pre-emptive refresh threshold.
    local function stale_tokens()
        return { token = "t1", refresh_token = "r1", token_time = os.time() - 51 * 60 }
    end

    local function deep_copy(value)
        if type(value) ~= "table" then return value end
        local out = {}
        for k, v in pairs(value) do out[deep_copy(k)] = deep_copy(v) end
        return out
    end

    local function seed_unrelated(ctx)
        local values = {
            server_url = "https://library.example",
            username = "reader",
            download_dir = "/mnt/us/books",
            view_filters = { shelf = "later", nested = { keep = true } },
            tailscale_autostart = true,
            future_setting = { version = 7, label = "untouched" },
        }
        for key, value in pairs(values) do ctx.settings:saveSetting(key, deep_copy(value)) end
        ctx.settings:flush()
        return values
    end

    local function settings_file_bytes(ctx)
        local f = assert(io.open(ctx.settings._path, "rb"))
        local bytes = f:read("*a")
        f:close()
        return bytes
    end

    local function assert_settings_exact(ctx, expected)
        assert.are.same(expected, ctx.settings.data)
        local reopened = LuaSettings:open(ctx.settings._path)
        assert.are.same(expected, reopened.data)
    end

    describe("dispatch gates", function()
        it("rejects unknown api methods", function()
            local ctx = make_ctx(fresh_tokens())
            local result, err = ctx.session:call(SERVER, "noSuchMethod")
            assert.is_nil(result)
            assert.matches("unknown%-api%-method", err)
        end)

        it("rejects api methods missing from the arg layout map", function()
            local ctx = make_ctx(fresh_tokens())
            local result, err = ctx.session:call(SERVER, "unmappedMethod")
            assert.is_nil(result)
            assert.matches("unmapped%-api%-method", err)
        end)

        it("rejects calls when no tokens are held", function()
            local ctx = make_ctx(nil)
            local result, err = ctx.session:call(SERVER, "getBooks")
            assert.is_nil(result)
            assert.are.equal("not-logged-in", err)
            assert.are.equal(0, #ctx.api.calls)
        end)

        it("splices the access token into the dispatched call", function()
            local ctx = make_ctx(fresh_tokens())
            ctx.api.books_queue = { { result = { "book" } } }
            local result, err = ctx.session:call(SERVER, "getBooks")
            assert.is_nil(err)
            assert.are.same({ "book" }, result)
            assert.are.same(
                { method = "getBooks", server_url = SERVER, token = "t1" },
                ctx.api.calls[1])
        end)

        it("routes an alternative download with exact book and file IDs", function()
            local ctx = make_ctx(fresh_tokens())
            local ok, err = ctx.session:call(
                SERVER, "downloadBookFile", 7, 701, "/tmp/seven.pdf", 64)
            assert.is_nil(err)
            assert.is_true(ok)
            assert.are.same({
                method = "downloadBookFile",
                server_url = SERVER,
                book_id = 7,
                file_id = 701,
                token = "t1",
                dest_path = "/tmp/seven.pdf",
                expected_size_kb = 64,
            }, ctx.api.calls[1])
        end)
    end)

    describe("pre-emptive refresh", function()
        it("rotates the token pair before dispatching when token_time is stale", function()
            local ctx = make_ctx(stale_tokens())
            ctx.api.refresh_queue = { { access = "t2", refresh = "r2" } }
            local _, err = ctx.session:call(SERVER, "getBooks")
            assert.is_nil(err)
            assert.are.equal("refreshToken", ctx.api.calls[1].method)
            assert.are.equal("r1", ctx.api.calls[1].refresh_token)
            assert.are.equal("t2", ctx.api.calls[2].token)
            -- rotated pair persisted for the next KOReader start
            assert.are.equal("t2", ctx.settings:readSetting("token"))
            assert.are.equal("r2", ctx.settings:readSetting("refresh_token"))
        end)

        it("refreshes when only a refresh token is held", function()
            local ctx = make_ctx({ refresh_token = "r1" })
            ctx.api.refresh_queue = { { access = "t2", refresh = "r2" } }
            local _, err = ctx.session:call(SERVER, "getBooks")
            assert.is_nil(err)
            assert.are.equal("t2", ctx.api.calls[2].token)
        end)

        it("clears all token state when the refresh is rejected", function()
            local ctx = make_ctx(stale_tokens())
            ctx.api.refresh_queue = { { err = "HTTP 401: refresh revoked" } }
            local result, err = ctx.session:call(SERVER, "getBooks")
            assert.is_nil(result)
            assert.matches("refresh revoked", err)
            assert.is_false(ctx.session:isLoggedIn())
            -- delSetting, not nil-save: keys absent on next init (DL-005)
            assert.is_nil(ctx.settings:readSetting("token"))
            assert.is_nil(ctx.settings:readSetting("refresh_token"))
            assert.is_nil(ctx.settings:readSetting("token_time"))
        end)

        it("fires on_expired when a reachable server REJECTS the pre-emptive refresh", function()
            -- The signal the UI needs to prompt a re-login (vs degrade to the
            -- cached copy): the server responded and refused our stored creds.
            local ctx = make_ctx(stale_tokens())
            ctx.api.refresh_queue = { { err = "HTTP 401: refresh revoked" } }
            ctx.session:call(SERVER, "getBooks")
            assert.are.equal(1, ctx.expired())
        end)

        it("does NOT fire on_expired when the pre-emptive refresh can't reach the server", function()
            -- A connection-class failure (no HTTP status) is recoverable -- the
            -- token may still be valid once online -- so the UI stays in the
            -- quiet offline path rather than wrongly telling the user to log in.
            local ctx = make_ctx(stale_tokens())
            ctx.api.refresh_queue = { { err = "HTTP timeout" } }
            ctx.session:call(SERVER, "getBooks")
            assert.are.equal(0, ctx.expired())
            assert.is_true(ctx.session:isLoggedIn())
            assert.are.equal("t1", ctx.settings:readSetting("token"))
            assert.are.equal("r1", ctx.settings:readSetting("refresh_token"))
        end)

        for _, case in ipairs({
            { label = "rate limit", err = "HTTP 429: retry later" },
            { label = "server failure", err = "HTTP 503: unavailable" },
        }) do
            it("preserves credentials on a transient refresh " .. case.label, function()
                local ctx = make_ctx(stale_tokens())
                ctx.api.refresh_queue = { { err = case.err } }
                local result, err = ctx.session:call(SERVER, "getBooks")
                assert.is_nil(result)
                assert.are.equal(case.err, err)
                assert.is_true(ctx.session:isLoggedIn())
                assert.are.equal("t1", ctx.settings:readSetting("token"))
                assert.are.equal("r1", ctx.settings:readSetting("refresh_token"))
                assert.are.equal(0, ctx.expired())
            end)
        end
    end)

    describe("401 handling", function()
        it("silently renews and retries once on a 401", function()
            local ctx = make_ctx(fresh_tokens())
            ctx.api.books_queue = {
                { err = "HTTP 401: expired" },
                { result = { "book" } },
            }
            ctx.api.refresh_queue = { { access = "t2", refresh = "r2" } }
            local result, err = ctx.session:call(SERVER, "getBooks")
            assert.is_nil(err)
            assert.are.same({ "book" }, result)
            assert.are.same(
                { "getBooks", "refreshToken", "getBooks" },
                { ctx.api.calls[1].method, ctx.api.calls[2].method, ctx.api.calls[3].method })
            assert.are.equal("t2", ctx.api.calls[3].token)
            assert.are.equal(0, ctx.expired())
        end)

        it("expires the session when the retry also 401s", function()
            local ctx = make_ctx(fresh_tokens())
            ctx.api.books_queue = {
                { err = "HTTP 401: expired" },
                { err = "HTTP 401: still expired" },
            }
            ctx.api.refresh_queue = { { access = "t2", refresh = "r2" } }
            local result, err = ctx.session:call(SERVER, "getBooks")
            assert.is_nil(result)
            assert.matches("HTTP 401", err)
            assert.is_false(ctx.session:isLoggedIn())
            assert.are.equal(1, ctx.expired())
        end)

        it("expires the session when the post-401 refresh fails", function()
            local ctx = make_ctx(fresh_tokens())
            ctx.api.books_queue = { { err = "HTTP 401: expired" } }
            ctx.api.refresh_queue = { { err = "HTTP 401: refresh rejected" } }
            local result, err = ctx.session:call(SERVER, "getBooks")
            assert.is_nil(result)
            assert.are.equal("HTTP 401: refresh rejected", err)
            assert.is_false(ctx.session:isLoggedIn())
            assert.are.equal(1, ctx.expired())
        end)

        for _, case in ipairs({
            { label = "timeout", err = "HTTP timeout" },
            { label = "429", err = "HTTP 429: retry later" },
            { label = "5xx", err = "HTTP 500: server error" },
        }) do
            it("keeps credentials when post-401 refresh hits " .. case.label, function()
                local ctx = make_ctx(fresh_tokens())
                ctx.api.books_queue = { { err = "HTTP 401: access expired" } }
                ctx.api.refresh_queue = { { err = case.err } }
                local result, err = ctx.session:call(SERVER, "getBooks")
                assert.is_nil(result)
                assert.are.equal(case.err, err)
                assert.is_true(ctx.session:isLoggedIn())
                assert.are.equal("t1", ctx.settings:readSetting("token"))
                assert.are.equal("r1", ctx.settings:readSetting("refresh_token"))
                assert.are.equal(0, ctx.expired())
            end)
        end

        it("expires a legacy install (access token only) on 401 without retrying", function()
            local ctx = make_ctx({ token = "t1", token_time = os.time() })
            ctx.api.books_queue = { { err = "HTTP 401: expired" } }
            local result, err = ctx.session:call(SERVER, "getBooks")
            assert.is_nil(result)
            assert.matches("HTTP 401", err)
            assert.are.equal(1, ctx.expired())
            -- no refresh attempt was possible
            assert.are.equal(1, #ctx.api.calls)
        end)

        it("treats a concurrent refresh as transient: no expiry, no token clearing", function()
            local ctx = make_ctx(fresh_tokens())
            ctx.api.books_queue = { { err = "HTTP 401: expired" } }
            ctx.session._refreshing = true  -- another call is mid-refresh
            local result, err = ctx.session:call(SERVER, "getBooks")
            assert.is_nil(result)
            assert.are.equal("refresh-in-progress", err)
            assert.are.equal(0, ctx.expired())
            assert.is_true(ctx.session:isLoggedIn())
        end)
    end)

    describe("setTokens", function()
        it("persists the pair and seeds token_time for the refresh threshold", function()
            local ctx = make_ctx(nil)
            ctx.session:setTokens("t9", "r9")
            assert.is_true(ctx.session:isLoggedIn())
            assert.are.equal("t9", ctx.settings:readSetting("token"))
            assert.are.equal("r9", ctx.settings:readSetting("refresh_token"))
            assert.is_number(ctx.settings:readSetting("token_time"))
        end)

        it("mutates exactly the token triple and preserves every unrelated setting", function()
            local issued_at = 1700000123
            local ctx = make_ctx(nil, function() return issued_at end)
            local expected = deep_copy(seed_unrelated(ctx))
            ctx.session:setTokens("t9", "r9")
            expected.token = "t9"
            expected.refresh_token = "r9"
            expected.token_time = issued_at
            assert_settings_exact(ctx, expected)
        end)

        it("clearTokens removes exactly the token triple", function()
            local ctx = make_ctx(fresh_tokens())
            seed_unrelated(ctx)
            local expected = deep_copy(ctx.settings.data)
            expected.token = nil
            expected.refresh_token = nil
            expected.token_time = nil
            ctx.session:clearTokens()
            assert_settings_exact(ctx, expected)
        end)

        it("a transient refresh failure preserves exact persisted bytes and fields", function()
            local ctx = make_ctx(stale_tokens())
            seed_unrelated(ctx)
            local expected = deep_copy(ctx.settings.data)
            local before_bytes = settings_file_bytes(ctx)
            ctx.api.refresh_queue = { { err = "HTTP timeout" } }
            local result, err = ctx.session:call(SERVER, "getBooks")
            assert.is_nil(result)
            assert.are.equal("HTTP timeout", err)
            assert_settings_exact(ctx, expected)
            assert.are.equal(before_bytes, settings_file_bytes(ctx))
        end)
    end)

    -- The account switcher lets a shared device hold several logins and
    -- resume one without retyping a password. The load-bearing property:
    -- switching snapshots the CURRENT active tokens before loading the
    -- target, so a background refresh that rotated the pair is never lost,
    -- and an inactive account's refresh token stays valid for resume.
    describe("multi-account store", function()
        -- Log a named account in as the active one (mirrors main.lua's
        -- post-login: setTokens then rememberActive).
        local function login(ctx, server, user, token, refresh)
            ctx.session:setTokens(token, refresh)
            ctx.session:rememberActive(server, user)
        end

        it("remembers the active account and lists it as active + resumable", function()
            local ctx = make_ctx(nil)
            login(ctx, "http://a", "alice", "ta", "ra")
            local accounts = ctx.session:listAccounts()
            assert.are.equal(1, #accounts)
            assert.are.equal("http://a", accounts[1].server_url)
            assert.are.equal("alice", accounts[1].username)
            assert.is_true(accounts[1].active)
            assert.is_true(accounts[1].resumable)
            assert.is_number(accounts[1].token_time)
        end)

        it("switchTo loads the target tokens, preserving their token_time", function()
            local ctx = make_ctx(nil)
            login(ctx, "http://a", "alice", "ta", "ra")
            -- Freeze account B's issue time well in the past, then switch away
            -- and back: loadTokens must NOT reseed token_time to now.
            login(ctx, "http://b", "bob", "tb", "rb")
            local b_time = ctx.session.token_time
            ctx.session:switchTo("http://a", "alice")
            local back = ctx.session:switchTo("http://b", "bob")
            assert.are.same({ server_url = "http://b", username = "bob" }, back)
            assert.are.equal("tb", ctx.session.token)
            assert.are.equal("rb", ctx.session.refresh_token)
            assert.are.equal(b_time, ctx.session.token_time)
            -- active flat keys reflect the switch for the next KOReader start
            assert.are.equal("tb", ctx.settings:readSetting("token"))
        end)

        it("returns nil for an unknown account with zero persistence side effects", function()
            local ctx = make_ctx(nil)
            login(ctx, "http://a", "alice", "ta", "ra")
            -- Rotate only the live triple. The stored account is intentionally
            -- stale, making an accidental outgoing-account snapshot visible.
            ctx.session:setTokens("ta2", "ra2")
            local expected = deep_copy(ctx.settings.data)
            local before_bytes = settings_file_bytes(ctx)
            local real_flush = ctx.settings.flush
            local flushes = 0
            ctx.settings.flush = function(self)
                flushes = flushes + 1
                return real_flush(self)
            end
            assert.is_nil(ctx.session:switchTo("http://x", "nobody"))
            -- active account is untouched
            assert.are.equal("ta2", ctx.session.token)
            assert.are.equal(0, flushes)
            assert.are.same(expected, ctx.settings.data)
            assert.are.equal(before_bytes, settings_file_bytes(ctx))
        end)

        it("captures a rotation that happened while active before leaving", function()
            -- Account A's tokens get refreshed (setTokens) after login; when we
            -- switch away to B and back to A, the rotated pair — not the login
            -- pair — must come back. This is what keeps resume working after a
            -- silent background refresh.
            local ctx = make_ctx(nil)
            login(ctx, "http://a", "alice", "ta", "ra")
            login(ctx, "http://b", "bob", "tb", "rb")
            ctx.session:switchTo("http://a", "alice")
            ctx.session:setTokens("ta2", "ra2")  -- simulates a refresh while A active
            ctx.session:switchTo("http://b", "bob")
            ctx.session:switchTo("http://a", "alice")
            assert.are.equal("ta2", ctx.session.token)
            assert.are.equal("ra2", ctx.session.refresh_token)
        end)

        it("marks an account with no refresh token as not resumable", function()
            local ctx = make_ctx(nil)
            ctx.session:loadTokens("ta", nil, os.time())
            ctx.session:rememberActive("http://a", "alice")
            assert.is_false(ctx.session:listAccounts()[1].resumable)
        end)

        it("ensureMigrated folds a legacy flat login into the store once", function()
            -- Pre-multi-account install: flat tokens present, no accounts list.
            local ctx = make_ctx(fresh_tokens())
            assert.are.equal(0, #ctx.session:listAccounts())
            ctx.session:ensureMigrated("http://a", "alice")
            local accounts = ctx.session:listAccounts()
            assert.are.equal(1, #accounts)
            assert.is_true(accounts[1].active)
            -- idempotent: a second call does not duplicate the entry
            ctx.session:ensureMigrated("http://a", "alice")
            assert.are.equal(1, #ctx.session:listAccounts())
        end)

        it("ensureMigrated is a no-op when logged out", function()
            local ctx = make_ctx(nil)
            ctx.session:ensureMigrated("http://a", "alice")
            assert.are.equal(0, #ctx.session:listAccounts())
        end)

        it("signOutActive clears tokens and drops the account from the store", function()
            local ctx = make_ctx(nil)
            login(ctx, "http://a", "alice", "ta", "ra")
            login(ctx, "http://b", "bob", "tb", "rb")  -- B now active
            ctx.session:signOutActive()
            assert.is_false(ctx.session:isLoggedIn())
            assert.is_nil(ctx.settings:readSetting("token"))
            assert.is_nil(ctx.session:activeAccount())
            local accounts = ctx.session:listAccounts()
            assert.are.equal(1, #accounts)  -- only A remains
            assert.are.equal("alice", accounts[1].username)
        end)

        it("signOutActive removes only the active identity and token keys", function()
            local ctx = make_ctx(nil)
            login(ctx, "http://a", "alice", "ta", "ra")
            login(ctx, "http://b", "bob", "tb", "rb")
            seed_unrelated(ctx)
            local expected = deep_copy(ctx.settings.data)
            expected.token = nil
            expected.refresh_token = nil
            expected.token_time = nil
            expected.active_account = nil
            expected.accounts = { deep_copy(expected.accounts[1]) }
            ctx.session:signOutActive()
            assert_settings_exact(ctx, expected)
        end)
    end)

    -- buildCallTask runs in the forked child; applyCallResult runs in the
    -- parent. Specs execute the task closure directly (same contract as the
    -- inline executor) and assert the fork-boundary invariants: the child
    -- never touches parent state, and apply persists exactly the rotation
    -- the child reports.
    describe("async task bridge", function()
        it("round-trips a plain result without touching parent tokens", function()
            local ctx = make_ctx(fresh_tokens())
            ctx.api.books_queue = { { result = { { id = 7 } } } }
            local payload = ctx.session:buildCallTask(SERVER, "getBooks")()
            -- Parent state untouched until apply.
            assert.are.equal("t1", ctx.session.token)
            assert.are.equal("t1", ctx.settings:readSetting("token"))
            local result, err = ctx.session:applyCallResult(payload)
            assert.same({ { id = 7 } }, result)
            assert.is_nil(err)
            -- No rotation happened, so nothing was rewritten.
            assert.are.equal("t1", ctx.settings:readSetting("token"))
            assert.are.equal(0, ctx.expired())
        end)

        it("persists a child-side pre-emptive refresh rotation on apply", function()
            local ctx = make_ctx(stale_tokens())
            ctx.api.refresh_queue = { { access = "t2", refresh = "r2" } }
            ctx.api.books_queue = { { result = {} } }
            local payload = ctx.session:buildCallTask(SERVER, "getBooks")()
            -- Child refreshed; parent must not know yet.
            assert.are.equal("t1", ctx.session.token)
            local result, err = ctx.session:applyCallResult(payload)
            assert.same({}, result)
            assert.is_nil(err)
            assert.are.equal("t2", ctx.session.token)
            assert.are.equal("r2", ctx.session.refresh_token)
            assert.are.equal("t2", ctx.settings:readSetting("token"))
            assert.are.equal("r2", ctx.settings:readSetting("refresh_token"))
        end)

        it("clears parent tokens and fires on_expired when the child hit a dead 401", function()
            local ctx = make_ctx(fresh_tokens())
            ctx.api.books_queue = { { err = "HTTP 401: expired" } }
            ctx.api.refresh_queue = { { err = "HTTP 401: refresh dead" } }
            local payload = ctx.session:buildCallTask(SERVER, "getBooks")()
            assert.is_true(ctx.session:isLoggedIn()) -- parent untouched pre-apply
            local result, err = ctx.session:applyCallResult(payload)
            assert.is_nil(result)
            assert.is_truthy(err)
            assert.is_false(ctx.session:isLoggedIn())
            assert.is_nil(ctx.settings:readSetting("token"))
            assert.are.equal(1, ctx.expired())
        end)

        it("reads parent token state at execution time, not build time", function()
            local ctx = make_ctx(fresh_tokens())
            ctx.api.books_queue = { { result = {} } }
            local task = ctx.session:buildCallTask(SERVER, "getBooks")
            -- An earlier queued task rotates the pair before this one runs.
            ctx.session:setTokens("t5", "r5")
            task()
            local books_call = ctx.api.calls[#ctx.api.calls]
            assert.are.equal("getBooks", books_call.method)
            assert.are.equal("t5", books_call.token)
        end)

        it("rejects a malformed payload without crashing", function()
            local ctx = make_ctx(fresh_tokens())
            local result, err = ctx.session:applyCallResult(nil)
            assert.is_nil(result)
            assert.are.equal("bad-async-payload", err)
            assert.is_true(ctx.session:isLoggedIn())
        end)

        it("batch task shares ONE child refresh across all calls and aligns results", function()
            local ctx = make_ctx(stale_tokens())
            ctx.api.refresh_queue = { { access = "t2", refresh = "r2" } }
            ctx.api.books_queue = { { result = { "books" } } }
            function ctx.api:getShelves(server_url, token)
                table.insert(ctx.api.calls, { method = "getShelves", token = token })
                return { "shelves" }, nil
            end
            function ctx.api:getLibraries(server_url, token)
                table.insert(ctx.api.calls, { method = "getLibraries", token = token })
                return { "libraries" }, nil
            end

            local payload = ctx.session:buildBatchTask(SERVER, {
                { method = "getBooks" },
                { method = "getShelves" },
                { method = "getLibraries" },
            })()

            local refreshes = 0
            for i = 1, #ctx.api.calls do
                if ctx.api.calls[i].method == "refreshToken" then
                    refreshes = refreshes + 1
                end
            end
            assert.are.equal(1, refreshes)
            assert.same({ "books" }, payload.results[1].result)
            assert.same({ "shelves" }, payload.results[2].result)
            assert.same({ "libraries" }, payload.results[3].result)
            -- Every call after the shared refresh used the rotated token.
            assert.are.equal("t2", ctx.api.calls[#ctx.api.calls].token)

            ctx.session:applyTokenSync(payload)
            assert.are.equal("t2", ctx.settings:readSetting("token"))
            assert.are.equal("r2", ctx.settings:readSetting("refresh_token"))
        end)

        it("batch task records per-call errors without aborting the batch", function()
            local ctx = make_ctx(fresh_tokens())
            ctx.api.books_queue = { { err = "HTTP 503: down" } }
            function ctx.api:getShelves(server_url, token)
                table.insert(ctx.api.calls, { method = "getShelves", token = token })
                return { "shelves" }, nil
            end
            local payload = ctx.session:buildBatchTask(SERVER, {
                { method = "getBooks" },
                { method = "getShelves" },
            })()
            assert.is_nil(payload.results[1].result)
            assert.matches("HTTP 503", payload.results[1].err)
            assert.same({ "shelves" }, payload.results[2].result)
        end)

        it("batch task carries the expired flag so applyTokenSync prompts re-login", function()
            -- The wiring the library UI depends on: a server-rejected refresh in
            -- the child sets payload.expired, and applying it in the parent
            -- fires on_expired (the "sign-in expired, log in again" notice).
            local ctx = make_ctx(stale_tokens())
            ctx.api.refresh_queue = { { err = "HTTP 401: refresh revoked" } }
            local payload = ctx.session:buildBatchTask(SERVER, {
                { method = "getBooks" },
            })()
            assert.is_true(payload.expired)
            assert.are.equal(0, ctx.expired()) -- parent not notified until apply
            ctx.session:applyTokenSync(payload)
            assert.are.equal(1, ctx.expired())
            assert.is_false(ctx.session:isLoggedIn())
        end)
    end)
end)
