--[[
  Token lifecycle spec for booklore.koplugin/session.lua.

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
        -- Present on the API but absent from METHOD_ARG_LAYOUT (G2 test).
        function api:unmappedMethod() end
        return api
    end

    -- ctx: { session, api, settings, expired() }
    local function make_ctx(tokens)
        local settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/booklore.lua")
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
            ctx.api.refresh_queue = { { err = "refresh rejected" } }
            local result, err = ctx.session:call(SERVER, "getBooks")
            assert.is_nil(result)
            assert.are.equal("refresh rejected", err)
            assert.is_false(ctx.session:isLoggedIn())
            assert.are.equal(1, ctx.expired())
        end)

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
    end)
end)
