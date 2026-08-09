local WidgetContainer = require("ui/widget/container/widgetcontainer")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local MultiConfirmBox = require("ui/widget/multiconfirmbox")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local T = require("ffi/util").template
local Math = require("optmath")
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local logger = require("logger")
local _ = require("gettext")
local Queue = require("queue")
local NetworkMgr = require("ui/network/manager")
local Async = require("async")

-- 3s per-socket-operation bound (DL-004). Without it the pull GET inherits
-- luasocket's 60s default and freezes book-open against an unreachable server.
local SYNC_TIMEOUT_SECS = 3

local function timedTCP()
    local s = require("socket").tcp()
    s:settimeout(SYNC_TIMEOUT_SECS)
    return s
end

-- ─── Module-level HTTP (runs in the async child or, in tests, inline) ──
-- These take every input as an argument and touch no `self`, so they are
-- safe to call from a forked subprocess. The parent owns all settings/queue
-- state; results travel back through the async callback.

local PREEMPTIVE_REFRESH_SECS = 50 * 60

local EBOOK_TYPES = {
    EPUB = true, FB2 = true, MOBI = true, AZW3 = true,
}

local EXTENSION_TYPES = {
    epub = "EPUB", fb2 = "FB2", mobi = "MOBI", azw = "AZW3", azw3 = "AZW3",
    pdf = "PDF", cbz = "CBX", cbr = "CBX", cb7 = "CBX",
}

local function normalizeFileType(file_type, path)
    local normalized = type(file_type) == "string" and file_type:upper() or nil
    if normalized == "AZW" then normalized = "AZW3" end
    if normalized == "CBZ" or normalized == "CBR" or normalized == "CB7" then
        normalized = "CBX"
    end
    if EBOOK_TYPES[normalized] or normalized == "PDF" or normalized == "CBX" then
        return normalized
    end
    local ext = type(path) == "string" and path:match("%.([^%./]+)$") or nil
    return ext and EXTENSION_TYPES[ext:lower()] or nil
end

local function requestFunction(server_url)
    if server_url:match("^https://") then
        local ok_ssl, ssl_https = pcall(require, "ssl.https")
        if ok_ssl then return ssl_https.request end
    end
    return http.request
end

-- Raw request result. A nil code is a network/transport failure, not an HTTP
-- response. Keeping that distinction is what lets refresh preserve valid
-- credentials during timeouts and server outages.
local function httpRequest(server_url, path, method, token, body)
    local sink = {}
    local headers = {}
    if token and token ~= "" then
        headers["Authorization"] = "Bearer " .. token
    end
    if body then
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#body)
    end
    local ok_req, code = pcall(function()
        local dummy, c = requestFunction(server_url){
            url = server_url .. path,
            method = method,
            headers = headers,
            source = body and ltn12.source.string(body) or nil,
            sink = ltn12.sink.table(sink),
            create = timedTCP,
        }
        return c
    end)
    if not ok_req then
        return { code = nil, body = "", transport_error = tostring(code) }
    end
    return { code = tonumber(code), body = table.concat(sink) }
end

local function isDefinitiveRefreshRejection(code)
    return code == 400 or code == 401 or code == 403
end

local function refreshAccess(server_url, credentials)
    if not credentials.refresh_token or credentials.refresh_token == "" then
        return false, "no-refresh-token"
    end
    local response = httpRequest(server_url, "/api/v1/auth/refresh", "POST", nil,
        json.encode({ refreshToken = credentials.refresh_token }))
    if response.code ~= 200 then
        if isDefinitiveRefreshRejection(response.code) then
            credentials.clear_tokens = true
            credentials.token = nil
            credentials.refresh_token = nil
            credentials.token_time = nil
            return false, "refresh-rejected"
        end
        return false, response.code and ("HTTP " .. tostring(response.code))
            or (response.transport_error or "refresh-network-error")
    end
    local ok, decoded = pcall(json.decode, response.body)
    if not ok or type(decoded) ~= "table"
            or type(decoded.accessToken) ~= "string"
            or type(decoded.refreshToken) ~= "string" then
        -- A malformed 200 response is a server/proxy problem. It is not proof
        -- that the stored refresh token is invalid, so preserve credentials.
        return false, "invalid-refresh-response"
    end
    credentials.token = decoded.accessToken
    credentials.refresh_token = decoded.refreshToken
    credentials.token_time = os.time()
    credentials.rotated = true
    return true
end

local function ensureFreshAccess(server_url, credentials)
    local token_stale = not credentials.token or credentials.token == ""
        or not credentials.token_time
        or (os.time() - credentials.token_time) > PREEMPTIVE_REFRESH_SECS
    if not token_stale then return true end
    -- Builds predating refresh-token persistence may still hold a usable
    -- access token. Let Grimmory validate it instead of treating its age as
    -- proof of revocation; a 401 remains queued and never clears credentials.
    if credentials.token and credentials.token ~= ""
            and (not credentials.refresh_token or credentials.refresh_token == "") then
        return true
    end
    return refreshAccess(server_url, credentials)
end

local function requestWithAuth(server_url, credentials, path, method, body)
    local ready, refresh_err = ensureFreshAccess(server_url, credentials)
    if not ready then
        return { code = nil, body = "", auth_error = refresh_err }
    end
    local response = httpRequest(server_url, path, method, credentials.token, body)
    if response.code ~= 401 or not credentials.refresh_token then
        return response
    end

    -- The access token may have expired earlier than its local age suggests.
    -- Refresh once and retry the original request; transient refresh failures
    -- leave both credentials and queued progress intact.
    local refreshed, reactive_err = refreshAccess(server_url, credentials)
    if not refreshed then
        return { code = 401, body = response.body, auth_error = reactive_err }
    end
    return httpRequest(server_url, path, method, credentials.token, body)
end

-- Grimmory's app progress endpoint accepts the generic per-file contract.
-- With a selected file id, the server validates that identity, stores a
-- UserBookFileProgress row, and cross-populates the web-reader field for the
-- file's actual type. Existing Grimmory registry entries predate file ids, so
-- the format-specific fallback remains correct for their primary download.
local function buildProgressPayload(file_id, file_type, percentage, position_data)
    file_type = normalizeFileType(file_type)
    if file_id then
        return {
            fileProgress = {
                bookFileId = file_id,
                positionData = position_data,
                progressPercent = percentage,
            },
        }
    elseif EBOOK_TYPES[file_type] then
        return { epubProgress = { cfi = position_data, percentage = percentage } }
    elseif file_type == "PDF" then
        return { pdfProgress = { page = tonumber(position_data), percentage = percentage } }
    elseif file_type == "CBX" then
        return { cbxProgress = { page = tonumber(position_data), percentage = percentage } }
    end
    return nil
end

local function httpPushProgress(server_url, book_id, file_id, file_type,
        percentage, position_data, credentials)
    if not book_id or not server_url then return { success = false, auth = credentials } end
    local payload = buildProgressPayload(file_id, file_type, percentage, position_data)
    if not payload then
        logger.warn("GrimmorySync: unsupported progress type:", tostring(file_type))
        return { success = false, auth = credentials }
    end
    local response = requestWithAuth(server_url, credentials,
        "/api/v1/app/books/" .. tostring(book_id) .. "/progress",
        "PUT", json.encode(payload))
    if response.code == 200 then
        logger.dbg("GrimmorySync: pushed progress", tostring(file_type),
            percentage, "%", position_data and ("position=" .. tostring(position_data)) or "no-position")
        return { success = true, auth = credentials }
    end
    logger.warn("GrimmorySync: push failed, HTTP", response.code,
        response.auth_error and ("auth=" .. response.auth_error) or "")
    return { success = false, auth = credentials }
end

local function httpPullProgress(server_url, book_id, credentials)
    local response = requestWithAuth(server_url, credentials,
        "/api/v1/app/books/" .. tostring(book_id) .. "/progress", "GET")
    response.auth = credentials
    return response
end

local GrimmorySync = WidgetContainer:extend{
    name = "grimmory_sync",
    is_doc_only = true,
}

-- Lazily create the async gateway. Specs construct sync objects without
-- init(), so this must work on a bare instance; on device init() is always
-- called first. One shared instance keeps pull/drain/push strictly ordered.
function GrimmorySync:_getAsync()
    if not self._async then self._async = Async.new{} end
    return self._async
end

function GrimmorySync:lookupBookId(file_path)
    local registry = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/grimmory_downloads.lua"
    )
    local data = registry.data or {}
    for dummy, entry in pairs(data) do
        if type(entry) == "table" and entry.path == file_path then
            return entry.server_id, entry.server_url,
                entry.file_id or entry.selected_file_id,
                normalizeFileType(entry.book_type
                    or entry.selected_file_type or entry.file_type, file_path)
        end
    end
    return nil, nil
end

-- Resolve file identity for queued entries created before the queue carried
-- it. Existing Grimmory download entries contain path/book/server only; their
-- file type is safely inferred from the exact registered path. File id remains
-- nil, selecting the format-specific primary-file fallback payload.
function GrimmorySync:lookupRegisteredFile(book_id, server_url)
    local registry = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/grimmory_downloads.lua"
    )
    for dummy, entry in pairs(registry.data or {}) do
        if type(entry) == "table"
                and tostring(entry.server_id) == tostring(book_id)
                and (not server_url or not entry.server_url or entry.server_url == server_url) then
            return entry.file_id or entry.selected_file_id,
                normalizeFileType(entry.book_type
                    or entry.selected_file_type or entry.file_type, entry.path)
        end
    end
    return nil, nil
end

function GrimmorySync:_readCredentials()
    local settings = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/grimmory.lua"
    )
    local active_account = settings:readSetting("active_account") or {}
    return {
        token = settings:readSetting("token"),
        refresh_token = settings:readSetting("refresh_token"),
        token_time = settings:readSetting("token_time"),
        -- Only the explicit active-account record is authoritative enough for
        -- a cross-server ownership guard. Older settings have no such record;
        -- their flat server URL describes configuration, not token provenance.
        server_url = active_account.server_url,
        username = active_account.username,
    }
end

-- Apply child-side token rotation/clearing in the parent. The account mirror
-- is updated alongside the flat active credentials so switching away and back
-- cannot resurrect a refresh token which Grimmory definitively rejected.
function GrimmorySync:_applyCredentials(credentials, server_url, username)
    if type(credentials) ~= "table" then return end
    if not credentials.rotated and not credentials.clear_tokens then return end

    local settings = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/grimmory.lua"
    )
    -- Always repair the saved account whose refresh token the child used.
    local accounts = settings:readSetting("accounts")
    if type(accounts) == "table" then
        for _, account in ipairs(accounts) do
            if type(account) == "table"
                    and account.server_url == server_url
                    and account.username == username then
                account.token = credentials.token
                account.refresh_token = credentials.refresh_token
                account.token_time = credentials.token_time
            end
        end
        settings:saveSetting("accounts", accounts)
    end

    -- The user may switch accounts while the child is in flight. Do not
    -- replace or clear the newly-active account's flat credentials when the
    -- old account's result eventually reaches this callback.
    local active_account = settings:readSetting("active_account")
    local still_active = type(active_account) == "table"
        and active_account.server_url == server_url
        and active_account.username == username
    if still_active then
        local function put(key, value)
            if value == nil then settings:delSetting(key)
            else settings:saveSetting(key, value) end
        end
        put("token", credentials.token)
        put("refresh_token", credentials.refresh_token)
        put("token_time", credentials.token_time)
        self.token = credentials.token
    end
    settings:flush()
end

function GrimmorySync:init()
    local settings = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/grimmory.lua"
    )
    self.server_url = settings:readSetting("server_url")

    -- Progress capture is decoupled from token validity: page turns enqueue
    -- to the on-disk queue regardless of whether a live token exists, and only
    -- PUSHING requires one (the drain reads the token from settings fresh and
    -- passes it to the async push). Gating capture on token age would silently
    -- discard progress made offline once the access token expired -- the exact
    -- case we must keep tracking until the user is online again. Only a missing
    -- server URL disables.
    if not self.server_url or self.server_url == "" then
        self.enabled = false
        return
    end

    self.token = settings:readSetting("token")          -- may be nil / expired
    self.username = settings:readSetting("username")    -- tags queued progress
    self.enabled = true
    self.book_id = nil
    self.has_pages = nil
    self.queue = nil
    self._flush_fn = nil
end

-- ─── Status menu (read-only view into the otherwise-silent sync engine) ──

-- Short one-line status for the menu item label.
function GrimmorySync:_statusLine()
    if not self.enabled then return _("Sync: off (server not configured)") end
    if not self.book_id then return _("Sync: off for this book") end
    local queued = self.queue and self.queue:size() or 0
    if not self.pulled then return _("Sync: waiting for first pull") end
    if queued > 0 then return T(_("Sync: %1 change(s) queued"), queued) end
    return _("Sync: up to date")
end

-- Verbose status for the InfoMessage shown when the user taps the status line.
function GrimmorySync:_statusDetail()
    if not self.enabled then
        return _("Reading-progress sync is off: no Grimmory server is configured.\n\n"
            .. "Open the Grimmory app and log in first.")
    end
    if not self.book_id then
        return _("This book is not synced.\n\n"
            .. "Only books downloaded through the Grimmory app sync their progress.")
    end
    local queued = self.queue and self.queue:size() or 0
    local lines = {
        T(_("Server: %1"), tostring(self.server_url or "?")),
        self.pulled and _("Server position pulled: yes")
            or _("Server position pulled: not yet (push is paused until it is)"),
        T(_("Queued changes: %1"), queued),
    }
    if not self.token or self.token == "" then
        lines[#lines + 1] = _("No sign-in token — open the Grimmory app to log in.")
    end
    return table.concat(lines, "\n")
end

-- Manual drain. Page turns already enqueue + flush periodically; this is for
-- users who want to push immediately before closing or switching devices.
function GrimmorySync:syncNow()
    if not self.enabled or not self.book_id then
        UIManager:show(InfoMessage:new{ text = _("Nothing to sync for this book.") })
        return
    end
    if not NetworkMgr:isWifiOn() then
        UIManager:show(InfoMessage:new{ text = _("Turn on WiFi to sync.") })
        return
    end
    local queued = self.queue and self.queue:size() or 0
    pcall(function() self:_drainAll() end)
    UIManager:show(InfoMessage:new{
        text = (queued > 0) and _("Syncing your reading position…")
            or _("Nothing to sync right now."),
    })
end

function GrimmorySync:addToMainMenu(menu_items)
    menu_items.grimmory_sync = {
        text = _("Grimmory Sync"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text_func = function() return self:_statusLine() end,
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{ text = self:_statusDetail() })
                end,
            },
            {
                text = _("Sync now"),
                keep_menu_open = true,
                enabled_func = function()
                    return self.enabled == true and self.book_id ~= nil
                end,
                callback = function() self:syncNow() end,
            },
        },
    }
end

function GrimmorySync:onReaderReady()
    if not self.enabled then return end

    local file_path = self.ui.document.file
    local book_id, server_url, file_id, file_type = self:lookupBookId(file_path)
    if not book_id then
        logger.dbg("GrimmorySync: not a Grimmory book, skipping sync")
        self.enabled = false
        return
    end

    self.book_id = book_id
    if server_url then self.server_url = server_url end
    self.file_id = file_id
    self.file_type = file_type
    if not self.file_type then
        logger.warn("GrimmorySync: unsupported or unknown registered file type; sync disabled")
        self.enabled = false
        return
    end
    self.has_pages = self.ui.document.info.has_pages
    self.push_in_progress = false
    self.pulled = false
    self.awaiting_decision = false
    self.cfi = nil
    self.queue = Queue.new{}

    if self.file_type == "EPUB" then
        local ok_req, cfi_mod = pcall(require, "cfi")
        if ok_req then
            local ok_init, init_err = pcall(function()
                local result, err = cfi_mod.initBook(file_path)
                if not result then
                    error(err or "initBook returned nil")
                end
            end)
            if ok_init then
                self.cfi = cfi_mod
            else
                logger.warn("GrimmorySync: CFI init failed:", tostring(init_err))
            end
        else
            logger.warn("GrimmorySync: cfi module require failed:", tostring(cfi_mod))
        end
    end

    UIManager:scheduleIn(1, function()
        local ok, err = pcall(self.pullProgress, self)
        if not ok then
            logger.warn("GrimmorySync: pullProgress crashed:", tostring(err))
            -- pullProgress now only enqueues the GET task synchronously (the
            -- request and decision run later on the async callback), so a crash
            -- here means the network layer was never reached. Server state is
            -- unchanged, so it is safe to open the push gate. A non-200 HTTP
            -- response is handled on the callback and leaves the gate CLOSED:
            -- the server responded with an unknown state, so we must not blindly
            -- overwrite it.
            self.pulled = true
        end
    end)
    self._flush_fn = function() self:_periodicFlush() end
    UIManager:scheduleIn(30, self._flush_fn)
end

function GrimmorySync:onCloseDocument()
    if not self.enabled or not self.book_id then return end
    if self._flush_fn then UIManager:unschedule(self._flush_fn); self._flush_fn = nil end
    if self.pulled and not self.awaiting_decision and self.queue then
        local pct = self:getPercentage()
        local pct_100 = math.floor(pct * 10000) / 100
        local position_data = self:getPositionData()
        pcall(function()
            self.queue:enqueue(self.book_id, self.server_url, pct_100,
                position_data, self.username, self.file_id, self.file_type)
        end)
        pcall(function() self:_drainAll() end)
    end
    if self.cfi then
        self.cfi.clearCache()
        self.cfi = nil
    end
end

function GrimmorySync:onPageUpdate()
    if not self.enabled or not self.book_id then return end
    if self.awaiting_decision then return end
    if not self.queue then return end
    local pct = self:getPercentage()
    local pct_100 = math.floor(pct * 10000) / 100
    local position_data = self:getPositionData()
    local ok_q, err_q = pcall(function()
        self.queue:enqueue(self.book_id, self.server_url, pct_100,
            position_data, self.username, self.file_id, self.file_type)
    end)
    if not ok_q then
        logger.warn("GrimmorySync: queue enqueue failed:", tostring(err_q))
    end
end

function GrimmorySync:getPositionData()
    if self.file_type == "PDF" or self.file_type == "CBX" then
        if self.ui.paging and self.ui.paging.getLastProgress then
            local page = self.ui.paging:getLastProgress()
            return page and tostring(page) or nil
        end
        return nil
    end
    if self.file_type == "EPUB" and self.cfi and not self.has_pages then
        local xp = self.ui.document:getXPointer()
        if xp then
            local ok_cfi, cfi_result, cfi_err = pcall(self.cfi.xpointerToCFI, xp)
            if ok_cfi and cfi_result then
                return cfi_result
            end
            local msg = ok_cfi and tostring(cfi_err) or tostring(cfi_result)
            logger.warn("GrimmorySync: CFI generation failed:", msg)
        end
    end
    -- Grimmory still records percentage for FB2/MOBI/AZW3. Their KOReader
    -- position syntax is not EPUB CFI and must not be mislabeled as one.
    return nil
end

function GrimmorySync:getPercentage()
    if self.has_pages then
        return Math.roundPercent(self.ui.paging:getLastPercent())
    else
        return Math.roundPercent(self.ui.rolling:getLastPercent())
    end
end

function GrimmorySync:_periodicFlush()
    if not self.enabled then return end
    if not NetworkMgr:isWifiOn() then
        if self._flush_fn then
            UIManager:scheduleIn(30, self._flush_fn)
        end
        return
    end
    pcall(function() self:_drainAll() end)
    if self._flush_fn then
        UIManager:scheduleIn(30, self._flush_fn)
    end
end

function GrimmorySync:_drainAll()
    if not self.queue then return end
    if self.queue:size() == 0 then return end
    if not NetworkMgr:isWifiOn() then return end
    if self._draining then return end -- one drain in flight; the next tick retries
    -- Read the logged-in user + token fresh at drain time (a re-login may have
    -- switched accounts): queued progress only pushes under the account that
    -- made it, and we pass the token to the child rather than have it re-read.
    local settings = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/grimmory.lua"
    )
    local current_username = settings:readSetting("username")
    local active_account = settings:readSetting("active_account") or {}
    local active_server = active_account.server_url or self.server_url
        or settings:readSetting("server_url")
    local credentials = {
        token = settings:readSetting("token"),
        refresh_token = settings:readSetting("refresh_token"),
        token_time = settings:readSetting("token_time"),
    }
    if (not credentials.token or credentials.token == "")
            and (not credentials.refresh_token or credentials.refresh_token == "") then
        return
    end

    -- Collect drainable slots WITHOUT pushing. The current book's slots are
    -- gated on the pull (push-after-pull); other books drain unconditionally.
    local items = {}
    if self.pulled and self.book_id then
        for _, it in ipairs(self.queue:currentBookDrainable(self.book_id,
                current_username, self.server_url, self.file_id, self.file_type)) do
            items[#items + 1] = it
        end
    end
    for _, it in ipairs(self.queue:othersDrainable(self.book_id,
            current_username, self.server_url, self.file_id, self.file_type)) do
        items[#items + 1] = it
    end
    if #items == 0 then return end

    -- Snapshot the push inputs (plain values, fork-safe). The entry tables
    -- themselves stay in the parent for the identity-guarded removal.
    local jobs = {}
    for i, it in ipairs(items) do
        local entry_server = it.entry.server_url or self.server_url
        if active_server and entry_server ~= active_server then
            -- A Grimmory token is server-scoped. Never present one instance's
            -- credentials to another instance; leave that entry queued until
            -- its account is active.
            items[i].skip = true
        end
        local file_id = it.entry.file_id
        local file_type = normalizeFileType(it.entry.file_type)
        if not file_type or not file_id then
            local registered_id, registered_type = self:lookupRegisteredFile(
                it.entry.book_id or self.book_id, entry_server)
            file_id = file_id or registered_id
            file_type = file_type or registered_type
        end
        -- Queue entries from the previous Grimmory client schema only carried
        -- a CFI, because that client could write EPUB progress exclusively.
        file_type = file_type or "EPUB"
        jobs[i] = {
            book_id    = it.entry.book_id or self.book_id,
            server_url = entry_server,
            percentage = it.entry.percentage,
            position_data = it.entry.position_data or it.entry.cfi,
            file_id    = file_id,
            file_type  = file_type,
            skip       = items[i].skip,
        }
    end

    self._draining = true
    local task = function()
        local results = {}
        for i = 1, #jobs do
            local j = jobs[i]
            if j.skip then
                results[i] = false
            else
                local push_result = httpPushProgress(j.server_url, j.book_id,
                    j.file_id, j.file_type, j.percentage, j.position_data,
                    credentials)
                results[i] = push_result.success
                credentials = push_result.auth or credentials
            end
        end
        return { results = results, auth = credentials }
    end
    self:_getAsync():run(task, function(payload)
        self._draining = false
        if type(payload) ~= "table" then return end
        self:_applyCredentials(payload.auth, active_server, current_username)
        local results = payload.results
        if type(results) ~= "table" then return end
        for i = 1, #items do
            if results[i] then
                -- removeIfUnchanged drops the slot only if a page turn hasn't
                -- replaced it with fresher progress since we collected it.
                self.queue:removeIfUnchanged(items[i].key, items[i].entry)
            end
        end
    end)
end

function GrimmorySync:pushProgress()
    local ok, err = pcall(function()
        local pct = self:getPercentage()
        local pct_100 = math.floor(pct * 10000) / 100
        self.queue = self.queue or Queue.new{}
        self.queue:enqueue(self.book_id, self.server_url, pct_100,
            self:getPositionData(), self.username, self.file_id, self.file_type)
        self:_drainAll()
    end)

    if not ok then
        logger.warn("GrimmorySync: pushProgress error:", tostring(err))
    end
end

function GrimmorySync:pullProgress()
    if self.awaiting_decision then return end
    local credentials = self:_readCredentials()
    if (credentials.server_url and self.server_url
                and credentials.server_url ~= self.server_url)
            or (credentials.username and self.username
                and credentials.username ~= self.username) then
        logger.warn("GrimmorySync: active account does not own this book; skipping pull")
        return
    end
    if (not credentials.token or credentials.token == "")
            and (not credentials.refresh_token or credentials.refresh_token == "") then
        logger.warn("GrimmorySync: no credentials, skipping pull; push gate stays closed")
        return
    end
    -- The GET runs in the async child; the parent decides on the callback.
    -- The push gate (self.pulled) is only ever written here, on the callback,
    -- so the push-after-pull invariant is unaffected by the move off-thread.
    local server_url, book_id = self.server_url, self.book_id
    local username = self.username
    self:_getAsync():run(function()
        return httpPullProgress(server_url, book_id, credentials)
    end, function(res)
        if type(res) == "table" then
            self:_applyCredentials(res.auth, server_url, username)
        end
        if type(res) ~= "table" or res.code ~= 200 then
            local code = type(res) == "table" and res.code or nil
            logger.warn("GrimmorySync: pull failed, HTTP", code, "-- push gate remains closed")
            return
        end

        local ok, book = pcall(json.decode, res.body)
        if not ok or not book then
            logger.warn("GrimmorySync: pull JSON decode failed -- push gate remains closed")
            return
        end

        local effective_file_type = self.file_type
            or normalizeFileType(nil, self.ui and self.ui.document and self.ui.document.file)
            or "EPUB"
        local remote
        if EBOOK_TYPES[effective_file_type] then
            remote = book.epubProgress
        elseif effective_file_type == "PDF" then
            remote = book.pdfProgress
        elseif effective_file_type == "CBX" then
            remote = book.cbxProgress
        end
        if not remote or type(remote.percentage) ~= "number" then
            logger.dbg("GrimmorySync: no remote", tostring(effective_file_type), "progress, pull done")
            self.pulled = true
            UIManager:scheduleIn(0.1, function() pcall(self._drainAll, self) end)
            return
        end

        local local_pct = self:getPercentage()
        local local_pct_100 = math.floor(local_pct * 10000) / 100
        logger.dbg("GrimmorySync: pull", tostring(effective_file_type), "remote=",
            remote.percentage, "% local=", local_pct_100, "% position=",
            tostring(remote.cfi or remote.page))

        if remote.percentage > local_pct_100 + 0.5 then
            local delta = math.floor((remote.percentage - local_pct_100) * 10) / 10
            logger.warn("GrimmorySync: server is ahead by", delta, "%, showing conflict prompt")
            self.awaiting_decision = true
            self:showConflictPrompt(remote, local_pct_100, delta)
            return
        end

        self.pulled = true
        UIManager:scheduleIn(0.1, function() pcall(self._drainAll, self) end)
    end)
end

function GrimmorySync:showConflictPrompt(remote, local_pct_100, delta)
    local self_ref = self
    UIManager:show(MultiConfirmBox:new{
        text = string.format(
            _("Server is %.1f%% ahead (server: %.1f%%, local: %.1f%%).\n\nJump ahead to the server position, or push your local position to the server?"),
            delta, remote.percentage, local_pct_100),
        choice1_text = _("Jump Ahead"),
        choice1_callback = function()
            local navigated = false
            if self_ref.file_type == "EPUB" and self_ref.cfi
                    and not self_ref.has_pages and type(remote.cfi) == "string" then
                local ok_xp, xp = pcall(function()
                    return self_ref.cfi.cfiToXPointer(remote.cfi)
                end)
                if ok_xp and xp then
                    self_ref.ui:handleEvent(Event:new("GotoXPointer", xp))
                    logger.dbg("GrimmorySync: jumped ahead via CFI", remote.cfi, "->", xp)
                    navigated = true
                else
                    logger.warn("GrimmorySync: CFI-to-XPointer failed:", tostring(xp))
                end
            end
            if not navigated and (self_ref.file_type == "PDF" or self_ref.file_type == "CBX")
                    and type(remote.page) == "number" then
                self_ref.ui:handleEvent(Event:new("GotoPage", remote.page))
                logger.dbg("GrimmorySync: jumped ahead to", tostring(self_ref.file_type),
                    "page", remote.page)
                navigated = true
            end
            if not navigated then
                local target = remote.percentage / 100
                if self_ref.has_pages then
                    local page_count = self_ref.ui.document:getPageCount()
                    local target_page = Math.round(target * page_count)
                    self_ref.ui:handleEvent(Event:new("GotoPage", target_page))
                else
                    self_ref.ui:handleEvent(Event:new("GotoPercent", target))
                end
                logger.dbg("GrimmorySync: jumped to server position", remote.percentage, "%")
            end
            self_ref.awaiting_decision = false
            self_ref.pulled = true
        end,
        choice2_text = _("Sync Here"),
        choice2_callback = function()
            self_ref.last_push_time = 0
            self_ref.awaiting_decision = false
            self_ref.pulled = true
            self_ref:pushProgress()
        end,
    })
end

-- Pure contract hooks used by off-device regression specs.
GrimmorySync._buildProgressPayload = buildProgressPayload
GrimmorySync._normalizeFileType = normalizeFileType

return GrimmorySync
