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
local State = require("state")
local Wire = require("wire")
local AnnotationSync = require("annotations")
local Sessions = require("sessions")
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
    local exact_position = position_data
    if file_type == "EPUB" then
        if type(position_data) ~= "string"
                or not position_data:match("^epubcfi%(.+%)$") then
            return nil
        end
    elseif file_type == "PDF" or file_type == "CBX" then
        local page = tonumber(position_data)
        if not page or page ~= page or page == math.huge or page == -math.huge
                or page < 1 or page ~= math.floor(page) then
            return nil
        end
        exact_position = tostring(page)
    end
    if file_id then
        return {
            fileProgress = {
                bookFileId = file_id,
                positionData = exact_position,
                progressPercent = percentage,
            },
        }
    elseif file_type == "EPUB" then
        return { epubProgress = { cfi = exact_position, percentage = percentage } }
    elseif EBOOK_TYPES[file_type] then
        -- KOReader does not expose an EPUB CFI for FB2/MOBI/AZW3. These formats
        -- intentionally degrade to percentage-only web-reader resume.
        return { epubProgress = { percentage = percentage } }
    elseif file_type == "PDF" then
        return { pdfProgress = { page = tonumber(exact_position), percentage = percentage } }
    elseif file_type == "CBX" then
        return { cbxProgress = { page = tonumber(exact_position), percentage = percentage } }
    end
    return nil
end

local function httpPushProgress(server_url, book_id, file_id, file_type,
        percentage, position_data, credentials)
    if not book_id or not server_url then return { success = false, auth = credentials } end
    local payload = buildProgressPayload(file_id, file_type, percentage, position_data)
    if not payload then
        logger.warn("GrimmorySync: invalid/unsupported progress payload; retaining queue:",
            tostring(file_type), tostring(position_data))
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
    -- The queue/status service is useful from FileManager too. Reader hooks
    -- remain guarded by onReaderReady and only run when a document exists.
    is_doc_only = false,
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
                    or entry.selected_file_type or entry.file_type, file_path),
                entry
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

function GrimmorySync:setStatusListener(listener)
    self._status_listener = type(listener) == "function" and listener or nil
end

function GrimmorySync:_notifyStatusChanged()
    local listener = self._status_listener
    if not listener or self._status_notification_scheduled then return end
    self._status_notification_scheduled = true
    UIManager:scheduleIn(0.1, function()
        self._status_notification_scheduled = false
        if self._status_listener == listener then
            local ok, err = pcall(listener)
            if not ok then
                logger.warn("GrimmorySync: status listener failed:", tostring(err))
            end
        end
    end)
end

local function remoteProgressForType(book, file_type)
    file_type = normalizeFileType(file_type)
    if type(book) ~= "table" then return nil end
    if EBOOK_TYPES[file_type] then return book.epubProgress end
    if file_type == "PDF" then return book.pdfProgress end
    if file_type == "CBX" then return book.cbxProgress end
end

function GrimmorySync:_bookMeta(overrides)
    local meta = {
        book_id = self.book_id,
        file_id = self.file_id,
        file_type = self.file_type,
        server_url = self.server_url,
        username = self.username,
        path = self.book_path,
        title = self.book_title,
    }
    for key, value in pairs(overrides or {}) do meta[key] = value end
    return meta
end

local function pendingBookKey(username, server_url, book_id)
    return (username or "") .. "\n" .. (server_url or "") .. "\n"
        .. tostring(book_id or "")
end

local function pendingFileIdentity(entry)
    if entry.file_id ~= nil then return "id:" .. tostring(entry.file_id) end
    local file_type = entry.file_type or entry.book_type
    if file_type then return "type:" .. tostring(file_type):upper() end
    if entry.path then return "path:" .. tostring(entry.path) end
    return "legacy"
end

local function stateActivity(entry)
    local latest = math.max(
        tonumber(entry.device_observed_at) or 0,
        tonumber(entry.server_observed_at) or 0,
        tonumber(entry.annotations_synced_at) or 0)
    local active = entry.active_session
    if type(active) == "table" then
        latest = math.max(latest, tonumber(active.last_event_at) or 0,
            tonumber(active.started_at) or 0)
    end
    for _, session in ipairs(entry.sessions or {}) do
        latest = math.max(latest, tonumber(session.last_event_at) or 0,
            tonumber(session.started_at) or 0)
    end
    return latest
end

-- One Wi-Fi row represents one account/server/book, even when several file
-- formats are queued. Display the newest captured progress. os.time() has
-- one-second resolution, so an exact queue-key tie-break is required: the
-- lexicographically greatest stable key wins. This is deterministic across
-- Lua processes and is shared with the standalone fallback model.
local function preferPending(current, key, entry, score)
    if not current or score > current.score
            or score == current.score and tostring(key) > tostring(current.key) then
        return { key = key, entry = entry, score = score }
    end
    return current
end

-- Public read-only model consumed by the Grimmory library's Wi-Fi menu.
-- Multiple dirty formats/features collapse to one row per account/server/book.
function GrimmorySync:pendingBooks()
    self.queue = self.queue or Queue.new{}
    self.state = self.state or State.new{}
    local settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/grimmory.lua")
    local active = settings:readSetting("active_account") or {}
    local displays = {}
    local downloads = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/grimmory_downloads.lua")
    for registry_key, entry in pairs(downloads.data or {}) do
        if type(entry) == "table" and entry.server_id ~= nil then
            local key = (entry.server_url or "") .. "\n" .. tostring(entry.server_id)
            displays[key] = displays[key] or {}
            displays[key][#displays[key] + 1] = {
                key = registry_key, entry = entry,
            }
        end
    end

    local function displayFor(entry)
        local candidates = displays[(entry.server_url or "") .. "\n"
            .. tostring(entry.book_id)] or {}
        table.sort(candidates, function(a, b)
            return tostring(a.key) < tostring(b.key)
        end)
        local identity = pendingFileIdentity(entry)
        local primary
        for _, candidate in ipairs(candidates) do
            if pendingFileIdentity(candidate.entry) == identity then
                return candidate.entry
            end
            if not primary and candidate.entry.is_primary == true then
                primary = candidate.entry
            end
        end
        return primary or (candidates[1] and candidates[1].entry) or {}
    end

    local books = {}
    local function ensure(entry)
        local key = pendingBookKey(entry.username, entry.server_url, entry.book_id)
        local row = books[key]
        if not row then
            local display = displayFor(entry)
            row = {
                key = key, book_id = entry.book_id, server_url = entry.server_url,
                username = entry.username, title = entry.title or display.title,
                path = entry.path or display.path,
                file_type = entry.file_type or display.book_type,
                features = {},
            }
            row.title = row.title or (row.path and row.path:match("([^/\\]+)$"))
                or ("Book " .. tostring(row.book_id))
            books[key] = row
        end
        row.active = (not active.server_url or not row.server_url
                or active.server_url == row.server_url)
            and (not active.username or not row.username
                or active.username == row.username)
        return row
    end

    local selected_progress = {}
    for queue_key, entry in pairs(self.queue._store.data or {}) do
        if type(entry) == "table" and entry.book_id ~= nil then
            local key = pendingBookKey(entry.username, entry.server_url, entry.book_id)
            selected_progress[key] = preferPending(selected_progress[key],
                queue_key, entry, tonumber(entry.enqueued_at) or 0)
        end
    end

    local state_items = self.state:entries()
    local dirty_groups, selected_state = {}, {}
    for _, item in ipairs(state_items) do
        local entry = item.entry
        local has_sessions = #(entry.sessions or {}) > 0
        local has_conflicts = type(entry.annotation_conflicts) == "table"
            and next(entry.annotation_conflicts) ~= nil
        local key = pendingBookKey(entry.username, entry.server_url, entry.book_id)
        local dirty = entry.annotations_dirty or has_sessions or has_conflicts
        if dirty then
            dirty_groups[key] = true
        end
        local progress = selected_progress[key]
        local matches_progress = not progress
            or pendingFileIdentity(entry) == pendingFileIdentity(progress.entry)
        if matches_progress and (progress or dirty) then
            selected_state[key] = preferPending(selected_state[key], item.key,
                entry, stateActivity(entry))
        end
    end


    for key, selected in pairs(selected_progress) do
        local entry = selected.entry
        local row = ensure(entry)
        local display = displayFor(entry)
        row.title = entry.title or display.title or row.title
        row.path = entry.path or display.path or row.path
        row.file_type = entry.file_type or display.book_type or row.file_type
        row.features.progress = true
        row.device_percentage = entry.percentage
        row.device_position = entry.position_data or entry.cfi
        local state = selected_state[key] and selected_state[key].entry
        if state then
            row.server_percentage = state.server_percentage
            row.server_position = state.server_position
        end
    end
    for key in pairs(dirty_groups) do
        if not books[key] and selected_state[key] then
            local entry = selected_state[key].entry
            local row = ensure(entry)
            row.device_percentage = entry.device_percentage
            row.device_position = entry.device_position
            row.server_percentage = entry.server_percentage
            row.server_position = entry.server_position
        end
    end
    for _, item in ipairs(state_items) do
        local entry = item.entry
        local has_sessions = #(entry.sessions or {}) > 0
        local has_conflicts = type(entry.annotation_conflicts) == "table"
            and next(entry.annotation_conflicts) ~= nil
        local key = pendingBookKey(entry.username, entry.server_url, entry.book_id)
        local row = books[key]
        if row and (entry.annotations_dirty or has_sessions or has_conflicts) then
            row.features.annotations = row.features.annotations
                or entry.annotations_dirty or has_conflicts or nil
            row.features.sessions = row.features.sessions or has_sessions or nil
        end
    end
    for key, selected in pairs(selected_state) do
        local row = books[key]
        if row then row.annotation_conflicts = selected.entry.annotation_conflicts end
    end

    local out = {}
    for _, row in pairs(books) do out[#out + 1] = row end
    table.sort(out, function(a, b)
        if a.active ~= b.active then return a.active == true end
        local at, bt = tostring(a.title):lower(), tostring(b.title):lower()
        if at ~= bt then return at < bt end
        return tostring(a.key) < tostring(b.key)
    end)
    return out
end

function GrimmorySync:pendingCount()
    return #self:pendingBooks()
end

function GrimmorySync:init()
    local settings = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/grimmory.lua"
    )
    local active_account = settings:readSetting("active_account") or {}
    self.server_url = active_account.server_url
        or settings:readSetting("server_url")
    self.username = active_account.username
        or settings:readSetting("username")
    self.queue = Queue.new{}
    self.state = State.new{}
    self.sync_annotations = settings:readSetting("sync_annotations", false) == true
    self.sync_reading_sessions = settings:readSetting(
        "sync_reading_sessions", false) == true
    self.session_min_seconds = tonumber(settings:readSetting(
        "session_min_seconds", 30)) or 30
    self.session_idle_seconds = tonumber(settings:readSetting(
        "session_idle_seconds", 1800)) or 1800

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
    self.enabled = true
    self.book_id = nil
    self.has_pages = nil
    self._flush_fn = nil
end

-- ─── Status menu (read-only view into the otherwise-silent sync engine) ──

-- Short one-line status for the menu item label.
function GrimmorySync:_statusLine()
    if not self.enabled then return _("Sync: off (server not configured)") end
    local queued = self:pendingCount()
    if self.book_id and not self.pulled then return _("Sync: waiting for first pull") end
    if queued > 0 then return T(_("Sync: %1 book(s) pending"), queued) end
    return _("Sync: up to date")
end

-- Verbose status for the InfoMessage shown when the user taps the status line.
function GrimmorySync:_statusDetail()
    if not self.enabled then
        return _("Reading-progress sync is off: no Grimmory server is configured.\n\n"
            .. "Open the Grimmory app and log in first.")
    end
    local queued = self:pendingCount()
    local lines = {
        T(_("Server: %1"), tostring(self.server_url or "?")),
        T(_("Books waiting to sync: %1"), queued),
    }
    if self.book_id then
        lines[#lines + 1] = self.pulled and _("Current book server position: checked")
            or _("Current book server position: not checked yet")
    end
    if not self.token or self.token == "" then
        lines[#lines + 1] = _("No sign-in token — open the Grimmory app to log in.")
    end
    return table.concat(lines, "\n")
end

-- Manual drain. Page turns already enqueue + flush periodically; this is for
-- users who want to push immediately before closing or switching devices.
function GrimmorySync:syncAllNow(callback)
    if not self.enabled then
        if callback then callback(false, "server-not-configured") end
        return
    end
    if not NetworkMgr:isWifiOn()
            or (NetworkMgr.isConnected and not NetworkMgr:isConnected()) then
        local after = function() self:syncAllNow(callback) end
        if NetworkMgr.turnOnWifiAndWaitForConnection then
            NetworkMgr:turnOnWifiAndWaitForConnection(after)
        else
            NetworkMgr:turnOnWifi(after)
        end
        return
    end
    if self.book_id and self.sync_annotations then pcall(self._syncAnnotations, self) end
    pcall(self._drainAll, self)
    if callback then callback(true) end
end

function GrimmorySync:syncNow()
    local queued = self:pendingCount()
    self:syncAllNow()
    UIManager:show(InfoMessage:new{
        text = (queued > 0) and _("Syncing Grimmory changes…")
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
                    return self.enabled == true
                end,
                callback = function() self:syncNow() end,
            },
        },
    }
end

function GrimmorySync:onReaderReady()
    if not self.enabled then return end

    local file_path = self.ui.document.file
    local book_id, server_url, file_id, file_type, registry_entry = self:lookupBookId(file_path)
    if not book_id then
        logger.dbg("GrimmorySync: not a Grimmory book, skipping sync")
        self.enabled = false
        return
    end

    self.book_id = book_id
    if server_url then self.server_url = server_url end
    self.file_id = file_id
    self.file_type = file_type
    self.book_path = file_path
    self.is_primary = not registry_entry or registry_entry.is_primary ~= false
    self.book_title = registry_entry and (registry_entry.title
        or registry_entry.file_name) or file_path:match("([^/\\]+)$")
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
    self.queue = self.queue or Queue.new{}
    self.state = self.state or State.new{}

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
    if self.sync_reading_sessions then self:_beginReadingSession() end
    if self.sync_annotations and self.file_type == "EPUB" and self.is_primary then
        UIManager:scheduleIn(2, function()
            local ok, err = pcall(self._syncAnnotations, self)
            if not ok then logger.warn("GrimmorySync: annotation sync crashed:", tostring(err)) end
        end)
    end
    self._flush_fn = function() self:_periodicFlush() end
    UIManager:scheduleIn(30, self._flush_fn)
end

function GrimmorySync:onCloseDocument()
    if not self.enabled or not self.book_id then return end
    if self._flush_fn then UIManager:unschedule(self._flush_fn); self._flush_fn = nil end
    if self._annotation_flush_fn then
        UIManager:unschedule(self._annotation_flush_fn)
        self._annotation_flush_fn = nil
    end
    if self.sync_reading_sessions then pcall(self._finishReadingSession, self) end
    if self.sync_annotations and self.file_type == "EPUB" and self.is_primary then
        pcall(self._syncAnnotations, self)
    end
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
        -- Annotation reconciliation may still be converting the final remote
        -- snapshot on its async callback. Keep the book cache alive until that
        -- callback has finished, then release it exactly once.
        if self._syncing_annotations then
            self._clear_cfi_after_annotations = true
        else
            self.cfi.clearCache()
            self.cfi = nil
        end
    end
end

function GrimmorySync:onPageUpdate()
    if not self.enabled or not self.book_id then return end
    if self.awaiting_decision then return end
    if not self.queue then return end
    local pct = self:getPercentage()
    local pct_100 = math.floor(pct * 10000) / 100
    local position_data = self:getPositionData()
    if self.state then
        pcall(self.state.setDevice, self.state, self:_bookMeta(), pct_100,
            position_data)
    end
    if self.sync_reading_sessions then
        pcall(self._updateReadingSession, self, pct_100, position_data)
    end
    local ok_q, err_q = pcall(function()
        self.queue:enqueue(self.book_id, self.server_url, pct_100,
            position_data, self.username, self.file_id, self.file_type)
    end)
    if not ok_q then
        logger.warn("GrimmorySync: queue enqueue failed:", tostring(err_q))
    end
    self:_notifyStatusChanged()
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
            logger.warn("GrimmorySync: CFI generation failed:", msg,
                "xpointer=", tostring(xp))
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

function GrimmorySync:_readingSample()
    local pct = math.floor(self:getPercentage() * 10000) / 100
    return { at = os.time(), percentage = pct, position = self:getPositionData() }
end

function GrimmorySync:_beginReadingSession()
    if not self.state or not self.book_id then return end
    local meta, sample = self:_bookMeta(), self:_readingSample()
    local existing = self.state:get(meta)
    if existing and existing.active_session then
        -- Recover the last durable activity after a crash. It ends at its last
        -- recorded event, never at startup (which would invent reading time).
        self.state:finalizeSession(meta, nil, self.session_min_seconds)
    end
    self.state:beginSession(meta, sample)
end

function GrimmorySync:_updateReadingSession(percentage, position)
    if not self.state or not self.book_id then return end
    local meta = self:_bookMeta()
    local entry = self.state:get(meta)
    local now = os.time()
    if entry and entry.active_session
            and now - (tonumber(entry.active_session.last_event_at) or now)
                > self.session_idle_seconds then
        self.state:finalizeSession(meta, nil, self.session_min_seconds)
        self.state:beginSession(meta, {
            at = now, percentage = percentage, position = position,
        })
        return
    end
    self.state:updateSession(meta, {
        at = now, percentage = percentage, position = position,
    })
end

function GrimmorySync:_finishReadingSession()
    if not self.state or not self.book_id then return end
    local meta, sample = self:_bookMeta(), self:_readingSample()
    local entry = self.state:get(meta)
    local active = entry and entry.active_session
    if active and sample.at - (tonumber(active.last_event_at) or sample.at)
            > self.session_idle_seconds then
        sample.at = (tonumber(active.last_event_at) or sample.at)
            + self.session_idle_seconds
        sample.percentage = active.end_percentage
        sample.position = active.end_position
    end
    self.state:finalizeSession(meta, sample, self.session_min_seconds)
    self:_notifyStatusChanged()
end

function GrimmorySync:onSuspend()
    if self.sync_reading_sessions then pcall(self._finishReadingSession, self) end
    pcall(self._drainAll, self)
end

function GrimmorySync:onPowerOff()
    if self.sync_reading_sessions then pcall(self._finishReadingSession, self) end
    pcall(self._drainAll, self)
end

function GrimmorySync:onResume()
    if self.sync_reading_sessions and self.enabled and self.book_id then
        pcall(self._beginReadingSession, self)
    end
end

function GrimmorySync:_localAnnotations()
    if self.ui and self.ui.annotation
            and type(self.ui.annotation.annotations) == "table" then
        return self.ui.annotation.annotations
    end
    if self.ui and self.ui.doc_settings then
        return self.ui.doc_settings:readSetting("annotations") or {}
    end
    return {}
end


function GrimmorySync:_saveLocalAnnotations(annotations)
    if not (self.ui and self.ui.doc_settings) then return false end
    self.ui.doc_settings:saveSetting("annotations", annotations)
    self.ui.doc_settings:saveSetting("annotations_externally_modified", true)
    self.ui.doc_settings:flush()
    if self.ui.annotation then
        self.ui.annotation.annotations = annotations
        if self.ui.annotation.updateAnnotations then
            pcall(self.ui.annotation.updateAnnotations, self.ui.annotation, true, true)
        end
    end
    return true
end

function GrimmorySync:onAnnotationsModified()
    if not self.sync_annotations or self.file_type ~= "EPUB"
            or not self.is_primary or not self.state then return end
    self.state:markAnnotationsDirty(self:_bookMeta(), true)
    self:_notifyStatusChanged()
    if self._annotation_flush_fn then UIManager:unschedule(self._annotation_flush_fn) end
    self._annotation_flush_fn = function()
        self._annotation_flush_fn = nil
        local ok, err = pcall(self._syncAnnotations, self)
        if not ok then
            logger.warn("GrimmorySync: annotation flush crashed:", tostring(err))
        end
    end
    UIManager:scheduleIn(2, self._annotation_flush_fn)
end

local function decodedBody(response)
    if type(response) ~= "table" or type(response.body) ~= "string" then return nil end
    local ok, decoded = pcall(json.decode, response.body)
    return ok and decoded or nil
end

function GrimmorySync:_syncAnnotations()
    if not self.sync_annotations or self.file_type ~= "EPUB" or not self.is_primary
            or not self.book_id or not self.cfi or not self.state then return end
    if self._syncing_annotations then
        -- A highlight changed (or the document closed) after the in-flight
        -- snapshot was taken. Serialize one follow-up pass so that edit is not
        -- accidentally marked clean by the earlier callback.
        self._annotations_resync_requested = true
        return
    end
    if not NetworkMgr:isWifiOn() then return end
    local credentials = self:_readCredentials()
    if (not credentials.token or credentials.token == "")
            and (not credentials.refresh_token or credentials.refresh_token == "") then
        return
    end
    local meta = self:_bookMeta()
    local local_annotations = self:_localAnnotations()
    local local_items, rejected = AnnotationSync.fromLocal(
        local_annotations, self.cfi, self.book_id)
    local shadow = self.state:getAnnotationShadow(meta)
    local server_url, book_id, username = self.server_url, self.book_id, self.username
    self._syncing_annotations = true
    self:_getAsync():run(function()
        local first = Wire.getAnnotations(server_url, book_id, credentials)
        if first.code ~= 200 then
            return { auth = first.auth or credentials,
                error = "annotations-get-" .. tostring(first.code) }
        end
        local remote = decodedBody(first)
        if type(remote) ~= "table" then
            return { auth = first.auth or credentials, error = "annotations-json" }
        end
        local plan = AnnotationSync.plan(local_items, remote, shadow)
        local errors = {}
        local conflicts = plan.conflicts
        for _, item in ipairs(plan.deletes) do
            local response = Wire.deleteAnnotation(server_url, item.id, credentials)
            if not ((response.code and response.code >= 200 and response.code < 300)
                    or response.code == 404) then
                errors[#errors + 1] = "delete:" .. tostring(item.id)
                conflicts[tostring(item.id)] = "delete-failed"
            end
        end
        for _, item in ipairs(plan.updates) do
            local response = Wire.updateAnnotation(server_url, item.id,
                item.body, credentials)
            if not (response.code and response.code >= 200 and response.code < 300) then
                errors[#errors + 1] = "update:" .. tostring(item.id)
                conflicts[tostring(item.id)] = "update-failed"
            end
        end
        for _, item in ipairs(plan.creates) do
            local response = Wire.createAnnotation(server_url, item.body, credentials)
            -- 409 is ambiguous (usually an earlier response was lost). The
            -- final GET below adopts the exact-CFI record instead of retrying.
            if not ((response.code and response.code >= 200 and response.code < 300)
                    or response.code == 409) then
                errors[#errors + 1] = "create:" .. tostring(item.index)
            end
        end
        local final = Wire.getAnnotations(server_url, book_id, credentials)
        local final_remote = final.code == 200 and decodedBody(final) or nil
        if type(final_remote) ~= "table" then
            errors[#errors + 1] = "final-get:" .. tostring(final.code)
            final_remote = nil
        end
        return {
            auth = final.auth or credentials,
            remote = final_remote,
            conflicts = conflicts,
            errors = errors,
        }
    end, function(payload)
        self._syncing_annotations = false
        local function releaseDeferredCfi()
            if self._clear_cfi_after_annotations and self.cfi then
                self.cfi.clearCache()
                self.cfi = nil
                self._clear_cfi_after_annotations = nil
            end
        end
        local function finishAnnotationTask()
            self:_notifyStatusChanged()
            if self._annotations_resync_requested and self.cfi then
                self._annotations_resync_requested = nil
                self.state:markAnnotationsDirty(meta, true)
                self:_syncAnnotations()
            else
                self._annotations_resync_requested = nil
                releaseDeferredCfi()
            end
        end
        if type(payload) ~= "table" then
            self.state:setAnnotationResult(meta, shadow, {}, true,
                "annotation-task-failed")
            finishAnnotationTask()
            return
        end
        self:_applyCredentials(payload.auth, server_url, username)
        if type(payload.remote) ~= "table" then
            self.state:setAnnotationResult(meta, shadow, {}, true, payload.error)
            finishAnnotationTask()
            return
        end
        local conflicts = payload.conflicts or {}
        local merged, conversion_errors = AnnotationSync.mergeLocal(local_annotations,
            payload.remote, self.cfi, conflicts)
        local saved = self:_saveLocalAnnotations(merged)
        local next_shadow = AnnotationSync.shadowFor(payload.remote)
        for id in pairs(conflicts) do next_shadow[id] = shadow[id] end
        local dirty = not saved or #rejected > 0
            or #(payload.errors or {}) > 0 or #conversion_errors > 0
            or next(conflicts) ~= nil
        local all_errors = {}
        for _, err in ipairs(payload.errors or {}) do all_errors[#all_errors + 1] = err end
        for _, err in ipairs(conversion_errors) do
            all_errors[#all_errors + 1] = "convert:" .. tostring(err)
        end
        local last_error = #all_errors > 0 and table.concat(all_errors, ", ") or nil
        self.state:setAnnotationResult(meta, next_shadow, conflicts,
            dirty, last_error)
        finishAnnotationTask()
    end)
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

function GrimmorySync:_drainSessions(current_username, active_server, credentials)
    if not self.sync_reading_sessions or self._draining_sessions
            or not self.state or not NetworkMgr:isWifiOn() then return end
    local candidates = self.state:pendingSessions(current_username, active_server)
    local jobs, items = {}, {}
    for _, item in ipairs(candidates) do
        if not item.session.permanent_error then
            local payload, err = Sessions.buildPayload(item.session)
            if not payload then
                self.state:setSessionError(item, err, true)
            else
                jobs[#jobs + 1] = {
                    payload = payload,
                    was_attempted = item.session.attempted == true,
                    server_url = item.entry.server_url or active_server,
                }
                items[#items + 1] = item
                -- Persist before HTTP. A crash after the server accepts POST
                -- will make the retry search server history before inserting.
                self.state:markSessionAttempted(item)
            end
        end
    end
    if #jobs == 0 then return end

    self._draining_sessions = true
    self:_getAsync():run(function()
        local results = {}
        for i, job in ipairs(jobs) do
            local duplicate = false
            if job.was_attempted then
                for page = 0, 4 do
                    local response = Wire.getSessions(job.server_url,
                        job.payload.bookId, page, credentials)
                    if response.code ~= 200 then break end
                    local decoded = decodedBody(response)
                    local remote_items = Sessions.responseItems(decoded)
                    for _, remote in ipairs(remote_items) do
                        if Sessions.matchesRemote(job.payload, remote) then
                            duplicate = true
                            break
                        end
                    end
                    if duplicate or #remote_items < 100 then break end
                end
            end
            if duplicate then
                results[i] = { success = true, deduplicated = true }
            else
                local response = Wire.recordSession(job.server_url,
                    job.payload, credentials)
                local success = response.code and response.code >= 200
                    and response.code < 300
                results[i] = { success = success, code = response.code,
                    permanent = response.code == 400 or response.code == 404 }
            end
        end
        return { results = results, auth = credentials }
    end, function(payload)
        self._draining_sessions = false
        if type(payload) ~= "table" then return end
        self:_applyCredentials(payload.auth, active_server, current_username)
        for i, result in ipairs(payload.results or {}) do
            if result.success then
                self.state:removeSessionIfUnchanged(items[i])
            else
                self.state:setSessionError(items[i],
                    "HTTP " .. tostring(result.code), result.permanent)
            end
        end
        self:_notifyStatusChanged()
    end)
end

function GrimmorySync:_drainAll()
    self.queue = self.queue or Queue.new{}
    self.state = self.state or State.new{}
    if not NetworkMgr:isWifiOn() then return end
    if self._draining then return end -- one drain in flight; the next tick retries
    -- Read the logged-in user + token fresh at drain time (a re-login may have
    -- switched accounts): queued progress only pushes under the account that
    -- made it, and we pass the token to the child rather than have it re-read.
    local settings = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/grimmory.lua"
    )
    local active_account = settings:readSetting("active_account") or {}
    local current_username = active_account.username
        or settings:readSetting("username")
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

    if self.queue:size() == 0 then
        self:_drainSessions(current_username, active_server, credentials)
        return
    end

    -- Collect drainable slots WITHOUT pushing. The current book's slots are
    -- gated on the pull (push-after-pull); other books drain unconditionally.
    local items = {}
    local active_file_type = self.file_type
        or normalizeFileType(nil,
            self.ui and self.ui.document and self.ui.document.file)
        or "EPUB"
    if self.pulled and self.book_id then
        for _, it in ipairs(self.queue:currentBookDrainable(self.book_id,
                current_username, self.server_url, self.file_id, active_file_type)) do
            -- pullProgress has already reconciled this exact open-file slot.
            -- Avoid a redundant second GET, but never grant this exemption to
            -- another format or a closed book collected below.
            it.prechecked = true
            items[#items + 1] = it
        end
    end
    for _, it in ipairs(self.queue:othersDrainable(self.book_id,
            current_username, self.server_url, self.file_id, active_file_type)) do
        items[#items + 1] = it
    end
    if #items == 0 then
        self:_drainSessions(current_username, active_server, credentials)
        return
    end

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
            prechecked = items[i].prechecked == true,
        }
    end

    self._draining = true
    local task = function()
        local results = {}
        for i = 1, #jobs do
            local j = jobs[i]
            if j.skip then
                results[i] = { success = false, skipped = true }
            elseif j.prechecked then
                local push_result = httpPushProgress(j.server_url, j.book_id,
                    j.file_id, j.file_type, j.percentage, j.position_data,
                    credentials)
                credentials = push_result.auth or credentials
                results[i] = { success = push_result.success,
                    remote_percentage = push_result.success and j.percentage or nil,
                    remote_position = push_result.success and j.position_data or nil }
            else
                -- Every bulk push is preceded by a fresh pull. Closed-book
                -- queue entries used to overwrite a newer server position.
                local pull = httpPullProgress(j.server_url, j.book_id, credentials)
                credentials = pull.auth or credentials
                if pull.code ~= 200 then
                    results[i] = { success = false, pull_failed = true,
                        code = pull.code }
                else
                    local ok, book = pcall(json.decode, pull.body)
                    local remote = ok and remoteProgressForType(book, j.file_type) or nil
                    local remote_pct = remote and tonumber(remote.percentage) or nil
                    local remote_pos = remote and (remote.cfi or remote.page) or nil
                    if remote_pct and remote_pct > tonumber(j.percentage) + 0.5 then
                        results[i] = { success = false, conflict = true,
                            remote_percentage = remote_pct,
                            remote_position = remote_pos }
                    else
                        local push_result = httpPushProgress(j.server_url, j.book_id,
                            j.file_id, j.file_type, j.percentage, j.position_data,
                            credentials)
                        credentials = push_result.auth or credentials
                        results[i] = { success = push_result.success,
                            remote_percentage = push_result.success and j.percentage
                                or remote_pct,
                            remote_position = push_result.success and j.position_data
                                or remote_pos }
                    end
                end
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
            local result = results[i]
            local job = jobs[i]
            if type(result) == "table" and result.remote_percentage ~= nil then
                self.state:setServer({
                    book_id = job.book_id, file_id = job.file_id,
                    file_type = job.file_type, server_url = job.server_url,
                    username = current_username,
                }, result.remote_percentage, result.remote_position)
            end
            if type(result) == "table" and result.success then
                -- removeIfUnchanged drops the slot only if a page turn hasn't
                -- replaced it with fresher progress since we collected it.
                self.queue:removeIfUnchanged(items[i].key, items[i].entry)
            end
        end
        self:_notifyStatusChanged()
        self:_drainSessions(current_username, active_server, payload.auth or credentials)
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
        local remote = remoteProgressForType(book, effective_file_type)
        if not remote or type(remote.percentage) ~= "number" then
            logger.dbg("GrimmorySync: no remote", tostring(effective_file_type), "progress, pull done")
            if self.state then self.state:setServer(self:_bookMeta(), nil, nil) end
            self.pulled = true
            self:_notifyStatusChanged()
            UIManager:scheduleIn(0.1, function() pcall(self._drainAll, self) end)
            return
        end

        local local_pct = self:getPercentage()
        local local_pct_100 = math.floor(local_pct * 10000) / 100
        if self.state then
            self.state:setServer(self:_bookMeta(), remote.percentage,
                remote.cfi or remote.page)
            self.state:setDevice(self:_bookMeta(), local_pct_100,
                self:getPositionData())
        end
        self:_notifyStatusChanged()
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
            -- Reject stale page events captured before the pull completed.
            -- The explicit Jump Ahead choice means the remote position wins;
            -- a later periodic drain must not push that superseded local slot.
            if self_ref.queue then
                self_ref.queue:discardCurrentBook(self_ref.book_id,
                    self_ref.username, self_ref.server_url, self_ref.file_id,
                    self_ref.file_type)
            end
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
                -- KOReader's GotoPercent event uses percentage points (0..100),
                -- while getLastPercent() uses a fraction (0..1). Passing a
                -- fraction here moved 80% progress to 0.8% whenever an EPUB
                -- CFI was absent/invalid (or for another reflowable format).
                local target = remote.percentage
                if self_ref.has_pages then
                    local page_count = self_ref.ui.document:getPageCount()
                    local target_page = Math.round(target / 100 * page_count)
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
