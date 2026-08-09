--[[
    Token lifecycle + refresh-aware API dispatch.

    Owns the access/refresh token pair persisted in the plugin settings and
    the single dispatcher (call) every authenticated GrimmoryApi request goes
    through. Standalone module — no KOReader widget dependencies — so the
    401-retry / silent-renewal / token-clearing state machine is
    unit-testable off device. The only UI side effect (the "Session expired"
    notice) is delegated to the on_expired callback injected by main.lua.

    Token state is loaded as-is; expiry is determined reactively by the
    refresh flow in call() (401-driven) and pre-emptively by token_time
    against PREEMPTIVE_REFRESH_SECS. A client-side age heuristic (DL-008,
    rejected) would discard a valid refresh token and force a manual
    re-login that silent renewal makes unnecessary. (ref: DL-003)
]]

local logger = require("logger")

local Session = {}
Session.__index = Session

-- True when an error string came from the server responding (an HTTP status),
-- as opposed to a connection-class failure. api.lua wraps a real status as
-- "HTTP <number>: ..." and a luasocket connect/timeout error as "HTTP
-- <word>: ..." (e.g. "HTTP timeout"), so a leading digit after "HTTP "
-- distinguishes "server rejected us" from "couldn't reach the server".
local function serverRejected(err)
    return type(err) == "string" and err:match("^HTTP %d") ~= nil
end

-- 50 min chosen so long reading sessions refresh well before the 10-hour
-- server access-token TTL without excessive refresh calls for short
-- sessions. (ref: DL-002)
local PREEMPTIVE_REFRESH_SECS = 50 * 60

-- Any api method routed through call() MUST be registered here --
-- unregistered calls fail at runtime with unmapped-api-method.
local METHOD_ARG_LAYOUT = {
    getBooks           = "token-second",
    getBook            = "token-second",
    getRecommendations = "token-second",
    getShelves         = "token-second",
    getLibraries  = "token-second",
    downloadBook  = "download-book",
    downloadCover = "download-cover",
}

--- @param opts table:
--   settings    LuaSettings instance holding token / refresh_token / token_time
--   api         GrimmoryApi (or a test double with the same surface)
--   on_expired  function|nil: invoked when the server confirms the session
--               is unrecoverable and the user must log in again
--   now         function|nil: clock override for specs (defaults to os.time)
function Session.new(opts)
    local self = setmetatable({}, Session)
    self.settings = opts.settings
    self.api = opts.api
    self.on_expired = opts.on_expired or function() end
    self.now = opts.now or os.time
    self.token = self.settings:readSetting("token")
    self.refresh_token = self.settings:readSetting("refresh_token")
    self.token_time = self.settings:readSetting("token_time")
    return self
end

function Session:isLoggedIn()
    return (self.token or self.refresh_token) ~= nil
end

--- Persist a freshly issued token pair (login or refresh).
-- Refresh token persisted: revocable and scoped, not reusable across
-- services. Storing credentials (DL-010, rejected) trades revocability for
-- convenience; refresh tokens carry lower blast-radius on exfiltration than
-- passwords. (ref: DL-004, DL-010)
function Session:setTokens(token, refresh_token)
    self.token = token
    self.refresh_token = refresh_token
    -- token_time seeds the pre-emptive refresh threshold in call(). (ref: DL-002)
    self.token_time = self.now()
    self.settings:saveSetting("token", token)
    self.settings:saveSetting("refresh_token", refresh_token)
    self.settings:saveSetting("token_time", self.token_time)
    self.settings:flush()
end

-- delSetting, not saveSetting(k, nil), so keys are absent on next init
-- rather than present-but-nil. (ref: DL-005)
function Session:clearTokens()
    self.token = nil
    self.refresh_token = nil
    self.token_time = nil
    self.settings:delSetting("token")
    self.settings:delSetting("refresh_token")
    self.settings:delSetting("token_time")
    self.settings:flush()
end

-- ─── Multi-account store ─────────────────────────────────────────────
-- A device can hold several Grimmory logins (e.g. a shared household
-- Kindle). The active account is the flat token/refresh_token/token_time
-- triple above; every known account (including the active one) is also
-- mirrored into the `accounts` list so the user can switch back without
-- retyping a password. Switching snapshots the CURRENT active tokens into
-- the store before loading the target, so a background refresh that rotated
-- the pair is never lost. An inactive account's tokens are frozen (only the
-- active account ever refreshes), so its stored refresh_token stays valid
-- for resume until the server revokes it. (ref: DL-004)

local function sameAccount(entry, server_url, username)
    return entry ~= nil
        and entry.server_url == server_url
        and entry.username == username
end

function Session:_accounts()
    return self.settings:readSetting("accounts") or {}
end

function Session:_saveAccounts(accounts)
    self.settings:saveSetting("accounts", accounts)
    self.settings:flush()
end

function Session:activeAccount()
    return self.settings:readSetting("active_account")
end

--- Set the flat active triple WITHOUT reseeding token_time (unlike
-- setTokens): resuming a saved account must preserve when its tokens were
-- issued so the pre-emptive refresh window counts from the real issue time.
function Session:loadTokens(token, refresh_token, token_time)
    self.token = token
    self.refresh_token = refresh_token
    self.token_time = token_time
    local function put(key, value)
        if value == nil then self.settings:delSetting(key)
        else self.settings:saveSetting(key, value) end
    end
    put("token", token)
    put("refresh_token", refresh_token)
    put("token_time", token_time)
    self.settings:flush()
end

--- Snapshot the current active tokens into the store under (server_url,
-- username) and mark that account active. Call after a successful login,
-- and BEFORE a setTokens() that would overwrite a different account's live
-- tokens, so the outgoing account's freshest pair is preserved.
function Session:rememberActive(server_url, username)
    if not server_url or not username then return end
    local accounts = self:_accounts()
    local entry
    for i = 1, #accounts do
        if sameAccount(accounts[i], server_url, username) then
            entry = accounts[i]
            break
        end
    end
    if not entry then
        entry = { server_url = server_url, username = username }
        table.insert(accounts, entry)
    end
    entry.token = self.token
    entry.refresh_token = self.refresh_token
    entry.token_time = self.token_time
    self.settings:saveSetting("active_account",
        { server_url = server_url, username = username })
    self:_saveAccounts(accounts)
end

--- One-time migration: fold a pre-multi-account login (flat tokens, no
-- accounts list) into the store. No-op once migrated or when logged out.
function Session:ensureMigrated(server_url, username)
    if #self:_accounts() > 0 then return end
    if not self:isLoggedIn() then return end
    self:rememberActive(server_url, username)
end

--- Accounts with display/status info for the switcher UI. resumable means
-- a refresh token is stored; whether it is still ACCEPTED is only known once
-- the next request validates it (a revoked token then triggers on_expired).
function Session:listAccounts()
    local accounts = self:_accounts()
    local active = self:activeAccount() or {}
    local out = {}
    for i = 1, #accounts do
        local a = accounts[i]
        out[i] = {
            server_url = a.server_url,
            username = a.username,
            token_time = a.token_time,
            resumable = a.refresh_token ~= nil,
            active = sameAccount(a, active.server_url, active.username),
        }
    end
    return out
end

--- Switch the active account: snapshot the current (possibly just-refreshed)
-- active tokens back into the store, then load the target account's stored
-- tokens into the flat active triple. Returns the target identity table, or
-- nil if no such account is stored.
function Session:switchTo(server_url, username)
    local active = self:activeAccount()
    if active and not sameAccount(active, server_url, username) then
        self:rememberActive(active.server_url, active.username)
    end
    local accounts = self:_accounts()
    local target
    for i = 1, #accounts do
        if sameAccount(accounts[i], server_url, username) then
            target = accounts[i]
            break
        end
    end
    if not target then return nil end
    self:loadTokens(target.token, target.refresh_token, target.token_time)
    self.settings:saveSetting("active_account",
        { server_url = server_url, username = username })
    self.settings:flush()
    return { server_url = target.server_url, username = target.username }
end

--- Sign out the active account: clear the live tokens and drop the account
-- from the store so it no longer appears in the switcher.
function Session:signOutActive()
    local active = self:activeAccount()
    self:clearTokens()
    if not active then return end
    local accounts = self:_accounts()
    local kept = {}
    for i = 1, #accounts do
        if not sameAccount(accounts[i], active.server_url, active.username) then
            table.insert(kept, accounts[i])
        end
    end
    self:_saveAccounts(kept)
    self.settings:delSetting("active_account")
    self.settings:flush()
end

-- _performRefresh: exchanges the stored refresh_token for a rotated pair.
-- Single-flight: if another call is already inside this function, return
-- refresh-in-progress immediately. Actual wait loops are not portable on
-- KOReader without coroutines; callers treat the transient error by
-- surfacing Session-expired and letting the user retry. (ref: DL-005, DL-006)
function Session:_performRefresh(server_url)
    if self._refreshing then
        return false, "refresh-in-progress"
    end
    self._refreshing = true

    local ok, inner_success, inner_err = pcall(function()
        local new_access, new_refresh, ref_err = self.api:refreshToken(
            server_url, self.refresh_token)

        if not new_access or not new_refresh then
            return false, ref_err or "refresh failed"
        end

        self.token = new_access
        self.refresh_token = new_refresh
        self.token_time = self.now()

        self.settings:saveSetting("token", new_access)
        self.settings:saveSetting("refresh_token", new_refresh)
        self.settings:saveSetting("token_time", self.token_time)
        self.settings:flush()

        return true, nil
    end)

    self._refreshing = false
    if ok then
        if inner_success == false then
            -- Refresh call returned failure; clear all token state.
            self:clearTokens()
            return false, inner_err
        end
        return true, nil
    else
        -- pcall caught a Lua error; inner_success holds the error object.
        self:clearTokens()
        return false, tostring(inner_success)
    end
end

-- call: token-injecting, refresh-aware dispatcher for api methods.
-- Call sites pass only method-specific args (no server_url slot juggling,
-- no token) and this helper splices self.token into the slot
-- METHOD_ARG_LAYOUT specifies. unpack (NOT table.unpack) is used because
-- KOReader on Kindle is LuaJIT/5.1 where table.unpack does not exist.
-- (ref: DL-001, DL-011)
function Session:call(server_url, method_name, ...)
    local extra_args = {...}

    -- G1: unknown-api-method
    if type(self.api[method_name]) ~= "function" then
        return nil, "unknown-api-method:" .. tostring(method_name)
    end

    -- G2: unmapped-api-method
    if METHOD_ARG_LAYOUT[method_name] == nil then
        logger.warn("Grimmory Session:call unmapped method", method_name,
            "-- add entry to METHOD_ARG_LAYOUT")
        return nil, "unmapped-api-method:" .. tostring(method_name)
    end

    -- G3: not-logged-in
    if not self.token and not self.refresh_token then
        return nil, "not-logged-in"
    end

    -- Pre-emptive refresh when token is stale or absent but refresh token exists
    if self.refresh_token and (
        not self.token
        or not self.token_time
        or (self.now() - self.token_time) > PREEMPTIVE_REFRESH_SECS
    ) then
        local ok, ref_err = self:_performRefresh(server_url)
        if not ok then
            -- A reachable server that REJECTED the refresh (any HTTP status:
            -- 401 expired token, or 4xx from an endpoint mismatch) means the
            -- stored credentials are unrecoverable -- signal expiry so the UI
            -- can prompt a re-login instead of silently degrading to the cached
            -- copy. A transient network failure (no HTTP status) or a
            -- concurrent refresh is recoverable, so it stays silent. This
            -- mirrors the reactive-401 path below; the pre-emptive path
            -- previously missed it. (ref: DL-006)
            if serverRejected(ref_err) then
                self.on_expired()
            end
            return nil, ref_err
        end
    end

    local function dispatch()
        local layout = METHOD_ARG_LAYOUT[method_name]
        if layout == "token-second" then
            return self.api[method_name](self.api, server_url, self.token, unpack(extra_args))
        elseif layout == "download-book" then
            -- extra_args: book_id, dest_path, expected_size_kb
            return self.api:downloadBook(server_url, extra_args[1], self.token, extra_args[2], extra_args[3])
        elseif layout == "download-cover" then
            -- extra_args: book_id, cover_updated_on, cache_dir
            return self.api:downloadCover(server_url, extra_args[1], extra_args[2], self.token, extra_args[3])
        end
    end

    local result, err = dispatch()

    -- 401 handling — anchored match covers both "HTTP 401:" (get/post)
    -- and bare "HTTP 401" (downloadCover/downloadBook) formats.
    if err and err:match("^HTTP 401") then
        if self.refresh_token then
            -- Case A: refresh token present — attempt silent renewal then retry once
            local ok, ref_err = self:_performRefresh(server_url)
            if not ok then
                if ref_err ~= "refresh-in-progress" then
                    self:clearTokens()
                    self.on_expired()
                end
                return nil, ref_err
            end
            result, err = dispatch()
            if err and err:match("^HTTP 401") then
                self:clearTokens()
                self.on_expired()
                return nil, err
            end
        else
            -- Case B: legacy install — no refresh token; clear and prompt re-login
            self:clearTokens()
            self.on_expired()
            return nil, err
        end
    end

    return result, err
end

-- ─── Async task bridge ───────────────────────────────────────────────
-- buildCallTask/applyCallResult split call() across the async.lua fork
-- boundary: the child runs the full refresh-aware dispatch (so the whole
-- refresh -> request -> 401 retry chain happens off the UI thread as ONE
-- task) and returns a serializable payload; the parent applies token
-- rotation and the expiry notice. The parent process owns the settings
-- file -- the child works on an in-memory shim and never flushes, so a
-- fork can never race the parent's writes.

-- Minimal LuaSettings look-alike over a plain table. flush() is a no-op
-- by contract: the rotated pair travels back in the payload instead.
local function newMemorySettings(data)
    local MemorySettings = {}
    MemorySettings.data = data or {}
    function MemorySettings:readSetting(key) return self.data[key] end
    function MemorySettings:saveSetting(key, value) self.data[key] = value end
    function MemorySettings:delSetting(key) self.data[key] = nil end
    function MemorySettings:flush() end
    return MemorySettings
end

--- Build a child-side task closure for async.Async:run().
-- Token state is read from `self` INSIDE the task, not captured at build
-- time: tasks are queued, and an earlier task may rotate the pair before
-- this one forks. Reading at execution time (post-apply, thanks to the
-- queue's strict serialization) means each task always starts from the
-- freshest tokens the parent knows about.
function Session:buildCallTask(server_url, method_name, ...)
    local parent = self
    local extra_args = {...}
    return function()
        local child = Session.new{
            settings = newMemorySettings{
                token = parent.token,
                refresh_token = parent.refresh_token,
                token_time = parent.token_time,
            },
            api = parent.api,
            now = parent.now,
        }
        local expired = false
        child.on_expired = function() expired = true end
        local result, err = child:call(server_url, method_name, unpack(extra_args))
        return {
            result = result,
            err = err,
            expired = expired,
            tokens = {
                token = child.token,
                refresh_token = child.refresh_token,
                token_time = child.token_time,
            },
        }
    end
end

--- Build a child-side task that dispatches SEVERAL methods through one
-- child session, so a stale token costs one shared refresh instead of one
-- per call. calls is an array of { method = "name", args = {...} }; the
-- payload carries results[i] = { result, err } aligned with the input.
function Session:buildBatchTask(server_url, calls)
    local parent = self
    return function()
        local child = Session.new{
            settings = newMemorySettings{
                token = parent.token,
                refresh_token = parent.refresh_token,
                token_time = parent.token_time,
            },
            api = parent.api,
            now = parent.now,
        }
        local expired = false
        child.on_expired = function() expired = true end
        local results = {}
        for i = 1, #calls do
            local c = calls[i]
            local result, err = child:call(server_url, c.method, unpack(c.args or {}))
            results[i] = { result = result, err = err }
        end
        return {
            results = results,
            expired = expired,
            tokens = {
                token = child.token,
                refresh_token = child.refresh_token,
                token_time = child.token_time,
            },
        }
    end
end

--- Sync the parent's token state from a task payload: persist a rotated
-- pair, clear on child-side clearing, fire on_expired. Shared by single
-- and batch apply paths.
function Session:applyTokenSync(payload)
    local tokens = payload.tokens or {}
    if tokens.token == nil and tokens.refresh_token == nil then
        -- Child cleared the pair (unrecoverable 401 / failed refresh).
        if self.token or self.refresh_token then
            self:clearTokens()
        end
    elseif tokens.token ~= self.token
            or tokens.refresh_token ~= self.refresh_token then
        -- Rotated pair from a child-side refresh. Persist with the child's
        -- token_time (not now()): the refresh happened then, and the
        -- pre-emptive window must count from the actual issue time.
        self.token = tokens.token
        self.refresh_token = tokens.refresh_token
        self.token_time = tokens.token_time
        self.settings:saveSetting("token", tokens.token)
        self.settings:saveSetting("refresh_token", tokens.refresh_token)
        self.settings:saveSetting("token_time", tokens.token_time)
        self.settings:flush()
    end
    if payload.expired then
        self.on_expired()
    end
end

--- Apply a buildCallTask payload in the parent: persist rotated tokens,
-- clear on child-side clearing, fire on_expired, and hand back the
-- dispatch result. Returns (result, err) exactly like call().
function Session:applyCallResult(payload)
    if type(payload) ~= "table" then
        return nil, "bad-async-payload"
    end
    self:applyTokenSync(payload)
    return payload.result, payload.err
end

return Session
