local WidgetContainer = require("ui/widget/container/widgetcontainer")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local Math = require("optmath")
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local logger = require("logger")
local _ = require("gettext")

local TOKEN_MAX_AGE = 20 * 60 * 60

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
    local token = settings:readSetting("token")
    local token_time = settings:readSetting("token_time", 0)

    if not self.server_url or self.server_url == ""
       or not token or (os.time() - token_time) >= TOKEN_MAX_AGE then
        self.enabled = false
        return
    end

    self.token = token
    self.enabled = true
    self.last_push_time = 0
    self.book_id = nil
    self.has_pages = nil
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
    self.cfi = nil

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
        self:pullProgress()
    end)
end

function BookLoreSync:onCloseDocument()
    if not self.enabled or not self.book_id then return end
    self:pushProgress()
    if self.cfi then
        self.cfi.clearCache()
        self.cfi = nil
    end
end

function BookLoreSync:onPageUpdate()
    if not self.enabled or not self.book_id then return end
    if not self.pulled then return end
    if os.time() - self.last_push_time < 30 then return end
    UIManager:scheduleIn(0.1, function()
        self:pushProgress()
    end)
end

function BookLoreSync:getPercentage()
    if self.has_pages then
        return Math.roundPercent(self.ui.paging:getLastPercent())
    else
        return Math.roundPercent(self.ui.rolling:getLastPercent())
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

        local body = json.encode({
            bookId = self.book_id,
            epubProgress = {
                cfi = cfi_str,
                percentage = pct_100,
            },
        })

        local sink = {}
        local dummy, code = http.request{
            url = self.server_url .. "/api/v1/books/progress",
            method = "POST",
            headers = {
                ["Authorization"] = "Bearer " .. self.token,
                ["Content-Type"] = "application/json",
                ["Content-Length"] = tostring(#body),
            },
            source = ltn12.source.string(body),
            sink = ltn12.sink.table(sink),
        }

        if code == 204 or code == 200 then
            self.last_push_time = os.time()
            logger.dbg("BookLoreSync: pushed progress", pct_100, "%", cfi_str and ("cfi=" .. cfi_str) or "no-cfi")
        else
            logger.warn("BookLoreSync: push failed, HTTP", code)
        end
    end)

    self.push_in_progress = false

    if not ok then
        logger.warn("BookLoreSync: pushProgress error:", tostring(err))
    end
end

function BookLoreSync:pullProgress()
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
        logger.warn("BookLoreSync: pull failed, HTTP", code)
        self.pulled = true
        return
    end

    local raw = table.concat(sink)
    local ok, book = pcall(json.decode, raw)
    if not ok or not book then
        logger.warn("BookLoreSync: pull JSON decode failed")
        self.pulled = true
        return
    end

    local remote = book.epubProgress
    if not remote or not remote.percentage then
        logger.dbg("BookLoreSync: no remote epubProgress, pull done")
        self.pulled = true
        return
    end

    local local_pct = self:getPercentage()
    local local_pct_100 = math.floor(local_pct * 10000) / 100
    logger.dbg("BookLoreSync: pull remote=", remote.percentage, "% local=", local_pct_100, "% cfi=", tostring(remote.cfi))

    if remote.percentage > local_pct_100 + 0.5 then
        local navigated = false
        if self.cfi and not self.has_pages and remote.cfi then
            local ok_xp, xp = pcall(function()
                return self.cfi.cfiToXPointer(remote.cfi)
            end)
            if ok_xp and xp then
                self.ui:handleEvent(Event:new("GotoXPointer", xp))
                logger.dbg("BookLoreSync: synced via CFI", remote.cfi, "->", xp)
                navigated = true
            else
                logger.warn("BookLoreSync: CFI-to-XPointer failed:", tostring(xp))
            end
        end

        if not navigated then
            local target = remote.percentage / 100
            if self.has_pages then
                local page_count = self.ui.document:getPageCount()
                local target_page = Math.round(target * page_count)
                self.ui:handleEvent(Event:new("GotoPage", target_page))
            else
                self.ui:handleEvent(Event:new("GotoPercent", target))
            end
            logger.dbg("BookLoreSync: synced to server position", remote.percentage, "%")
        end
    end

    self.pulled = true
end

return BookLoreSync
