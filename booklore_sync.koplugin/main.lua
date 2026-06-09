local WidgetContainer = require("ui/widget/container/widgetcontainer")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local MultiConfirmBox = require("ui/widget/multiconfirmbox")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local Math = require("optmath")
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local logger = require("logger")
local _ = require("gettext")
local Queue = require("queue")
local NetworkMgr = require("ui/network/manager")

local BookLoreSync = WidgetContainer:extend{
    name = "booklore_sync",
    is_doc_only = true,
}

function BookLoreSync:lookupBookId(file_path)
    local registry = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/booklore_downloads.lua"
    )
    local data = registry.data or {}
    for dummy, entry in pairs(data) do
        if type(entry) == "table" and entry.path == file_path then
            return entry.server_id, entry.server_url
        end
    end
    return nil, nil
end

function BookLoreSync:init()
    local settings = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/booklore.lua"
    )
    self.server_url = settings:readSetting("server_url")

    -- Progress capture is decoupled from token validity: page turns enqueue
    -- to the on-disk queue regardless of whether a live token exists, and only
    -- PUSHING requires one (pushProgressBody re-reads the token from settings on
    -- every drain). Gating capture on token age would silently discard progress
    -- made offline once the access token expired -- the exact case we must keep
    -- tracking until the user is online again. Only a missing server URL disables.
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

function BookLoreSync:onReaderReady()
    if not self.enabled then return end

    local file_path = self.ui.document.file
    local book_id, server_url = self:lookupBookId(file_path)
    if not book_id then
        logger.dbg("BookLoreSync: not a BookLore book, skipping sync")
        self.enabled = false
        return
    end

    self.book_id = book_id
    if server_url then self.server_url = server_url end
    self.has_pages = self.ui.document.info.has_pages
    self.push_in_progress = false
    self.pulled = false
    self.awaiting_decision = false
    self.cfi = nil
    self.queue = Queue.new{}

    if not self.has_pages then
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
                logger.warn("BookLoreSync: CFI init failed:", tostring(init_err))
            end
        else
            logger.warn("BookLoreSync: cfi module require failed:", tostring(cfi_mod))
        end
    end

    UIManager:scheduleIn(1, function()
        local ok, err = pcall(self.pullProgress, self)
        if not ok then
            logger.warn("BookLoreSync: pullProgress crashed:", tostring(err))
            -- Intentional asymmetry with HTTP failure: a Lua crash here means
            -- the network layer was never reached (e.g. a nil-index before the
            -- http.request call). Server state is therefore unchanged, so it is
            -- safe to open the push gate and allow the session to proceed.
            -- Contrast with a non-200 HTTP response: the server DID respond but
            -- with an unknown state, so the gate stays closed for the session to
            -- avoid blindly overwriting server progress.
            self.pulled = true
        end
    end)
    self._flush_fn = function() self:_periodicFlush() end
    UIManager:scheduleIn(30, self._flush_fn)
end

function BookLoreSync:onCloseDocument()
    if not self.enabled or not self.book_id then return end
    if self._flush_fn then UIManager:unschedule(self._flush_fn); self._flush_fn = nil end
    if self.pulled and not self.awaiting_decision and self.queue then
        local pct = self:getPercentage()
        local pct_100 = math.floor(pct * 10000) / 100
        local cfi_str = nil
        if self.cfi and not self.has_pages then
            local xp = self.ui.document:getXPointer()
            if xp then
                local ok_cfi, cfi_result = pcall(self.cfi.xpointerToCFI, xp)
                if ok_cfi and cfi_result then
                    cfi_str = cfi_result
                end
            end
        end
        pcall(function() self.queue:enqueue(self.book_id, self.server_url, pct_100, cfi_str, self.username) end)
        pcall(function() self:_drainAll() end)
    end
    if self.cfi then
        self.cfi.clearCache()
        self.cfi = nil
    end
end

function BookLoreSync:onPageUpdate()
    if not self.enabled or not self.book_id then return end
    if self.awaiting_decision then return end
    if not self.queue then return end
    local pct = self:getPercentage()
    local pct_100 = math.floor(pct * 10000) / 100
    local cfi_str = nil
    if self.cfi and not self.has_pages then
        local xp = self.ui.document:getXPointer()
        if xp then
            local ok_cfi, cfi_result, cfi_err = pcall(self.cfi.xpointerToCFI, xp)
            if ok_cfi and cfi_result then
                cfi_str = cfi_result
            else
                local msg = ok_cfi and tostring(cfi_err) or tostring(cfi_result)
                logger.warn("BookLoreSync: CFI generation failed:", msg)
            end
        end
    end
    local ok_q, err_q = pcall(function()
        self.queue:enqueue(self.book_id, self.server_url, pct_100, cfi_str, self.username)
    end)
    if not ok_q then
        logger.warn("BookLoreSync: queue enqueue failed:", tostring(err_q))
    end
end

function BookLoreSync:getPercentage()
    if self.has_pages then
        return Math.roundPercent(self.ui.paging:getLastPercent())
    else
        return Math.roundPercent(self.ui.rolling:getLastPercent())
    end
end

function BookLoreSync:_periodicFlush()
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

function BookLoreSync:_drainAll()
    if not self.queue then return end
    if self.queue:size() == 0 then return end
    if not NetworkMgr:isWifiOn() then return end
    -- Read the logged-in user fresh at drain time (a re-login may have switched
    -- accounts): queued progress only pushes under the account that made it.
    local settings = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/booklore.lua"
    )
    local current_username = settings:readSetting("username")
    if self.pulled and self.book_id then
        self.queue:drainCurrentBook(self.book_id, current_username, function(entry)
            return self:pushProgressBody(
                entry.book_id or self.book_id,
                entry.server_url or self.server_url,
                entry.percentage,
                entry.cfi
            )
        end)
    end
    self.queue:drainOthers(self.book_id, current_username, function(entry)
        return self:pushProgressBody(
            entry.book_id,
            entry.server_url,
            entry.percentage,
            entry.cfi
        )
    end)
end

function BookLoreSync:pushProgressBody(book_id, server_url, percentage, cfi)
    if not book_id or not server_url then return false end
    local settings = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/booklore.lua"
    )
    local token = settings:readSetting("token")
    if not token or token == "" then
        logger.warn("BookLoreSync: pushProgressBody: no token")
        return false
    end

    local body = json.encode({
        bookId = book_id,
        epubProgress = {
            cfi = cfi,
            percentage = percentage,
        },
    })

    local sink = {}
    local use_https = server_url:match("^https://") ~= nil
    local request_fn = http.request
    if use_https then
        local ok_ssl, ssl_https = pcall(require, "ssl.https")
        if ok_ssl then request_fn = ssl_https.request end
    end
    local ok_req, code = pcall(function()
        local dummy, c = request_fn{
            url = server_url .. "/api/v1/books/progress",
            method = "POST",
            headers = {
                ["Authorization"] = "Bearer " .. token,
                ["Content-Type"] = "application/json",
                ["Content-Length"] = tostring(#body),
            },
            source = ltn12.source.string(body),
            sink = ltn12.sink.table(sink),
            create = function()
                -- 3s socket timeout (DL-004) bounds connect+read so even when
                -- the flusher fires while the user is mid-swipe, the freeze
                -- is capped. NetworkMgr:isWifiOn() preflight already skips
                -- this entirely when offline.
                local s = require("socket").tcp()
                s:settimeout(3)
                return s
            end,
        }
        return c
    end)
    if not ok_req then
        logger.warn("BookLoreSync: pushProgressBody network error:", tostring(code))
        return false
    end
    if code == 204 or code == 200 then
        logger.dbg("BookLoreSync: pushed progress", percentage, "%", cfi and ("cfi=" .. cfi) or "no-cfi")
        return true
    else
        logger.warn("BookLoreSync: push failed, HTTP", code)
        return false
    end
end

function BookLoreSync:pushProgress()
    if self.push_in_progress then return end
    self.push_in_progress = true

    local ok, err = pcall(function()
        local pct = self:getPercentage()
        local pct_100 = math.floor(pct * 10000) / 100

        local cfi_str = nil
        if self.cfi and not self.has_pages then
            local xp = self.ui.document:getXPointer()
            if xp then
                logger.dbg("BookLoreSync: XPointer:", xp)
                local ok_cfi, cfi_result, cfi_err = pcall(self.cfi.xpointerToCFI, xp)
                if ok_cfi and cfi_result then
                    cfi_str = cfi_result
                else
                    local msg = ok_cfi and tostring(cfi_err) or tostring(cfi_result)
                    logger.warn("BookLoreSync: CFI generation failed:", msg)
                end
            end
        end

        self:pushProgressBody(self.book_id, self.server_url, pct_100, cfi_str)
    end)

    self.push_in_progress = false

    if not ok then
        logger.warn("BookLoreSync: pushProgress error:", tostring(err))
    end
end

function BookLoreSync:pullProgress()
    if self.awaiting_decision then return end
    -- No token => skip the pull entirely. This is a clean early return, NOT a
    -- thrown error, so the pcall wrapper in onReaderReady leaves self.pulled
    -- false and the push gate stays CLOSED (nothing was pulled). It also avoids
    -- the `"Bearer " .. nil` concatenation crash that would otherwise trip the
    -- crash-handler into spuriously opening the gate. Do NOT convert this to
    -- error() -- the onReaderReady pcall would then set self.pulled=true.
    if not self.token or self.token == "" then
        logger.warn("BookLoreSync: no token, skipping pull; push gate stays closed")
        return
    end
    local sink = {}
    local dummy, code = http.request{
        url = self.server_url .. "/api/v1/books/" .. tostring(self.book_id),
        method = "GET",
        headers = {
            ["Authorization"] = "Bearer " .. self.token,
        },
        sink = ltn12.sink.table(sink),
    }

    if code ~= 200 then
        logger.warn("BookLoreSync: pull failed, HTTP", code, "-- push gate remains closed")
        return
    end

    local raw = table.concat(sink)
    local ok, book = pcall(json.decode, raw)
    if not ok or not book then
        logger.warn("BookLoreSync: pull JSON decode failed -- push gate remains closed")
        return
    end

    local remote = book.epubProgress
    if not remote or type(remote.percentage) ~= "number" then
        logger.dbg("BookLoreSync: no remote epubProgress, pull done")
        self.pulled = true
        UIManager:scheduleIn(0.1, function() pcall(self._drainAll, self) end)
        return
    end

    local local_pct = self:getPercentage()
    local local_pct_100 = math.floor(local_pct * 10000) / 100
    logger.dbg("BookLoreSync: pull remote=", remote.percentage, "% local=", local_pct_100, "% cfi=", tostring(remote.cfi))

    if remote.percentage > local_pct_100 + 0.5 then
        local delta = math.floor((remote.percentage - local_pct_100) * 10) / 10
        logger.warn("BookLoreSync: server is ahead by", delta, "%, showing conflict prompt")
        self.awaiting_decision = true
        self:showConflictPrompt(remote, local_pct_100, delta)
        return
    end

    self.pulled = true
    UIManager:scheduleIn(0.1, function() pcall(self._drainAll, self) end)
end

function BookLoreSync:showConflictPrompt(remote, local_pct_100, delta)
    local self_ref = self
    UIManager:show(MultiConfirmBox:new{
        text = string.format(
            _("Server is %.1f%% ahead (server: %.1f%%, local: %.1f%%).\n\nJump ahead to the server position, or push your local position to the server?"),
            delta, remote.percentage, local_pct_100),
        choice1_text = _("Jump Ahead"),
        choice1_callback = function()
            local navigated = false
            if self_ref.cfi and not self_ref.has_pages and type(remote.cfi) == "string" then
                local ok_xp, xp = pcall(function()
                    return self_ref.cfi.cfiToXPointer(remote.cfi)
                end)
                if ok_xp and xp then
                    self_ref.ui:handleEvent(Event:new("GotoXPointer", xp))
                    logger.dbg("BookLoreSync: jumped ahead via CFI", remote.cfi, "->", xp)
                    navigated = true
                else
                    logger.warn("BookLoreSync: CFI-to-XPointer failed:", tostring(xp))
                end
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
                logger.dbg("BookLoreSync: jumped to server position", remote.percentage, "%")
            end
            self_ref.awaiting_decision = false
            self_ref.pulled = true
        end,
        choice2_text = _("Sync Here"),
        choice2_callback = function()
            self_ref.last_push_time = 0
            self_ref:pushProgress()
            self_ref.awaiting_decision = false
            self_ref.pulled = true
        end,
    })
end

return BookLoreSync
