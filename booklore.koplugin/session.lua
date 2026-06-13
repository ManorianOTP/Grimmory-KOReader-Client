--[[
    Token lifecycle + refresh-aware API dispatch.

    Owns the access/refresh token pair persisted in the plugin settings and
    the single dispatcher (call) every authenticated BookLoreApi request goes
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
--   api         BookLoreApi (or a test double with the same surface)
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
        logger.warn("BookLore Session:call unmapped method", method_name,
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

return Session
