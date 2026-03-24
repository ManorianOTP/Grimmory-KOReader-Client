local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local ImageWidget = require("ui/widget/imagewidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local Button = require("ui/widget/button")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local Size = require("ui/size")
local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local Device = require("device")
local Screen = Device.screen
local logger = require("logger")
local json = require("json")
local util = require("util")
local _ = require("gettext")

local BookLoreApi = require("api")

local BookLore = WidgetContainer:extend{
    name = "booklore",
    is_doc_only = false,
}

-- Where downloaded books live on Kindle's persistent user partition.
-- Flat directory — the registry handles the book→file mapping,
-- not the filesystem hierarchy. This matches how KOReader's own
-- OPDS plugin works (download_dir + flat filenames).
local DOWNLOAD_DIR = "/mnt/us/booklore/downloads"

--- Build a registry key scoped to both server and book.
-- Format: "server_url|book_id" — unique across multiple BookLore instances.
-- @param server_url string
-- @param book_id number
-- @return string
local function registryKey(server_url, book_id)
    return server_url .. "|" .. tostring(book_id)
end

function BookLore:init()
    self.settings = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/booklore.lua"
    )
    self.server_url = self.settings:readSetting("server_url", "http://192.168.1.144:6060")
    self.username = self.settings:readSetting("username", "")

    -- Reload persisted token if it's still fresh (< 20h old).
    -- BookLore JWTs expire at ~24h; 20h gives comfortable margin.
    local saved_token = self.settings:readSetting("token")
    local saved_token_time = self.settings:readSetting("token_time", 0)
    local TOKEN_MAX_AGE = 20 * 60 * 60  -- 20 hours in seconds
    if saved_token and (os.time() - saved_token_time) < TOKEN_MAX_AGE then
        self.token = saved_token
    else
        self.token = nil
    end

    -- Download registry: maps "server_url|book_id" → { path, server_id,
    -- server_url }. Tracks which books are downloaded and where they live.
    self.download_registry = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/booklore_downloads.lua"
    )

    self.ui.menu:registerToMainMenu(self)
end

function BookLore:addToMainMenu(menu_items)
    menu_items.booklore = {
        text = _("BookLore"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Login"),
                callback = function()
                    self:showLoginDialog()
                end,
            },
            {
                text = _("Browse Library"),
                callback = function()
                    self:browseLibrary()
                end,
            },
        },
    }
end

function BookLore:showLoginDialog()
    self.login_dialog = MultiInputDialog:new{
        title = _("BookLore Login"),
        fields = {
            {
                text = self.server_url,
                hint = _("Server URL"),
            },
            {
                text = self.username,
                hint = _("Username"),
            },
            {
                text = "",
                hint = _("Password"),
                text_type = "password",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.login_dialog)
                    end,
                },
                {
                    text = _("Login"),
                    is_enter_default = true,
                    callback = function()
                        local fields = self.login_dialog:getFields()
                        local server = fields[1]
                        local user = fields[2]
                        local pass = fields[3]
                        UIManager:close(self.login_dialog)
                        self:doLogin(server, user, pass)
                    end,
                },
            },
        },
    }
    UIManager:show(self.login_dialog)
    self.login_dialog:onShowKeyboard()
end

function BookLore:doLogin(server_url, username, password)
    if not NetworkMgr:isWifiOn() then
        NetworkMgr:turnOnWifi()
    end

    local token, err = BookLoreApi:login(server_url, username, password)

    if token then
        self.token = token
        self.server_url = server_url
        self.username = username

        self.settings:saveSetting("server_url", server_url)
        self.settings:saveSetting("username", username)
        self.settings:saveSetting("token", token)
        self.settings:saveSetting("token_time", os.time())
        self.settings:flush()

        UIManager:show(InfoMessage:new{
            text = _("Logged in successfully."),
        })
        logger.info("BookLore: authenticated as", username)
    else
        UIManager:show(InfoMessage:new{
            text = _("Login failed:\n") .. tostring(err),
        })
        logger.warn("BookLore: login failed:", err)
    end
end

function BookLore:browseLibrary()
    if not self.token then
        UIManager:show(InfoMessage:new{
            text = _("Not logged in. Please login first."),
        })
        return
    end

    if not NetworkMgr:isWifiOn() then
        NetworkMgr:turnOnWifi()
    end

    local books, err = BookLoreApi:getBooks(self.server_url, self.token)

    if not books then
        -- If the server rejected our token, clear it and prompt re-login.
        if err and err:match("^HTTP 401") then
            self.token = nil
            self.settings:delSetting("token")
            self.settings:delSetting("token_time")
            self.settings:flush()
            UIManager:show(InfoMessage:new{
                text = _("Session expired. Please login again."),
            })
        else
            UIManager:show(InfoMessage:new{
                text = _("Failed to fetch books:\n") .. tostring(err),
            })
        end
        return
    end

    if type(books) ~= "table" or #books == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No books found."),
        })
        return
    end

    table.sort(books, function(a, b)
        local title_a = a.metadata and a.metadata.title or ""
        local title_b = b.metadata and b.metadata.title or ""
        return title_a:lower() < title_b:lower()
    end)

    self.cached_books = books
    self:showLibraryMenu()
end

function BookLore:showLibraryMenu()
    local books = self.cached_books
    if not books then return end

    local item_table = {}
    for _, book in ipairs(books) do
        local meta = book.metadata or {}
        local title = meta.title or book.fileName or "Untitled"
        local authors = ""
        if type(meta.authors) == "table" and #meta.authors > 0 then
            authors = table.concat(meta.authors, ", ")
        end

        local status = book.readStatus or ""
        local local_path = self:getLocalPath(book)
        if local_path then
            status = "● " .. status
        end

        table.insert(item_table, {
            text = title,
            mandatory = status,
            info = authors,
            book_data = book,
        })
    end

    self.book_menu = Menu:new{
        title = _("BookLore") .. " (" .. tostring(#books) .. " books)",
        item_table = item_table,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        onMenuChoice = function(menu_instance, item)
            UIManager:close(self.book_menu)
            self:showBookDetail(item.book_data)
        end,
        close_callback = function()
            UIManager:close(self.book_menu)
        end,
    }
    UIManager:show(self.book_menu)
end

--- Build the local filesystem path for a downloaded book.
--
-- Uses the server's original fileName, sanitized through KOReader's
-- util.getSafeFilename (the same function the built-in OPDS plugin uses).
-- All downloads go into a flat directory. The registry — not the
-- filesystem hierarchy — is what maps books back to the server.
--
-- BookLore server-side stores books on disk at:
--   libraryPath / fileSubPath / fileName
-- with MariaDB tracking the path components. But the server path is
-- irrelevant on the client: BookLore identifies books by `id` in its
-- REST API, and kosync matches by partial MD5 of file content. Neither
-- cares about local paths, so we keep it flat and simple.
--
-- @param book table: book data from the API
-- @return string: local file path
function BookLore:buildDestPath(book)
    local raw_name = book.fileName or ("book_" .. tostring(book.id))
    local safe_name = util.getSafeFilename(raw_name, DOWNLOAD_DIR)
    local path = DOWNLOAD_DIR .. "/" .. safe_name
    return util.fixUtf8(path, "_")
end

--- Look up whether a book has been downloaded.
-- Checks the registry, then verifies the file still exists on disk.
-- Clears stale entries if the file was deleted externally.
-- @param book table: book data from the API
-- @return string|nil: local file path if downloaded, nil otherwise
function BookLore:getLocalPath(book)
    if not book.id then return nil end
    local key = registryKey(self.server_url, book.id)
    local entry = self.download_registry:readSetting(key)
    if entry and entry.path then
        local f = io.open(entry.path, "rb")
        if f then
            f:close()
            return entry.path
        else
            logger.dbg("BookLore: stale registry entry for book", book.id)
            self.download_registry:delSetting(key)
            self.download_registry:flush()
            return nil
        end
    end
    return nil
end

--- Register a downloaded book.
-- Stores only what's needed to map a local file back to the server:
-- the path on disk, the server's book ID, and which server it came from.
-- @param book table: book data from the API
-- @param path string: local file path
function BookLore:registerDownload(book, path)
    local key = registryKey(self.server_url, book.id)
    self.download_registry:saveSetting(key, {
        path = path,
        server_id = book.id,
        server_url = self.server_url,
    })
    self.download_registry:flush()
end

--- Download a book from BookLore to local storage.
-- Closes and rebuilds the detail view, then forces e-ink to repaint.
-- @param book table: book data from the API
function BookLore:refreshDetailView(book)
    if self.detail_widget then
        UIManager:close(self.detail_widget)
    end
    self:showBookDetail(book)
    -- Force a full screen refresh so e-ink actually repaints.
    UIManager:setDirty(self.detail_widget, "ui")
end

--- Download a book from BookLore to local storage.
-- Updates the detail view button through three states:
--   "Download (X MB)" → "Downloading…" → "Read"
-- @param book table: book data from the API
function BookLore:downloadBook(book)
    if not self.token then
        UIManager:show(InfoMessage:new{ text = _("Not logged in.") })
        return
    end

    if not NetworkMgr:isWifiOn() then
        NetworkMgr:turnOnWifi()
    end

    local dest = self:buildDestPath(book)

    -- Set downloading state and rebuild the view so the button
    -- shows "Downloading…" before luasocket blocks.
    self._downloading_id = book.id
    self:refreshDetailView(book)

    UIManager:scheduleIn(0.1, function()
        local ok, err = BookLoreApi:downloadBook(
            self.server_url, book.id, self.token, dest, book.fileSizeKb
        )

        self._downloading_id = nil

        if ok then
            self:registerDownload(book, dest)
            self:refreshDetailView(book)
        else
            UIManager:show(InfoMessage:new{
                text = _("Download failed:\n") .. tostring(err),
            })
            self:refreshDetailView(book)
        end
    end)
end

--- Open a downloaded book in KOReader's reader.
-- @param file_path string: path to the local book file
function BookLore:openBook(file_path)
    if self.detail_widget then
        UIManager:close(self.detail_widget)
        self.detail_widget = nil
    end
    if self.book_menu then
        UIManager:close(self.book_menu)
        self.book_menu = nil
    end

    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(file_path)
end

function BookLore:showBookDetail(book)
    local meta = book.metadata or {}
    local title = meta.title or book.fileName or "Untitled"
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local padding = Size.padding.large

    -- Cover cache
    local cache_dir = DataStorage:getDataDir() .. "/cache/booklore"
    local lfs = require("libs/libkoreader-lfs")
    lfs.mkdir(cache_dir)

    local cover_widget = nil
    if book.id then
        local cover_path, cover_err = BookLoreApi:downloadCover(
            self.server_url, book.id, self.token, cache_dir
        )
        if cover_path then
            local success, img = pcall(ImageWidget.new, ImageWidget, {
                file = cover_path,
                width = math.floor(screen_w * 0.4),
                height = math.floor(screen_h * 0.3),
                scale_factor = 0,
            })
            if success and img then
                cover_widget = img
            else
                logger.warn("BookLore: failed to load cover image:", img)
            end
        else
            logger.dbg("BookLore: cover download failed:", cover_err)
        end
    end

    local content_w = screen_w - padding * 4
    local content = VerticalGroup:new{ align = "center" }

    -- Title
    local title_w = TextWidget:new{
        text = title,
        face = Font:getFace("tfont", 24),
        bold = true,
        max_width = content_w,
    }
    table.insert(content, CenterContainer:new{
        dimen = Geom:new{ w = content_w, h = title_w:getSize().h },
        title_w,
    })
    table.insert(content, VerticalSpan:new{ width = padding })

    -- Cover
    if cover_widget then
        table.insert(content, CenterContainer:new{
            dimen = Geom:new{ w = content_w, h = cover_widget:getSize().h },
            cover_widget,
        })
        table.insert(content, VerticalSpan:new{ width = padding })
    end

    -- Detail text
    local lines = {}

    if type(meta.authors) == "table" and #meta.authors > 0 then
        table.insert(lines, "By: " .. table.concat(meta.authors, ", "))
    end

    if meta.seriesName then
        local s = "Series: " .. meta.seriesName
        if meta.seriesNumber then
            s = s .. " #" .. tostring(meta.seriesNumber)
        end
        if meta.seriesTotal then
            s = s .. " of " .. tostring(meta.seriesTotal)
        end
        table.insert(lines, s)
    end

    if meta.publisher then
        local p = "Publisher: " .. meta.publisher
        if meta.publishedDate then
            p = p .. " (" .. meta.publishedDate .. ")"
        end
        table.insert(lines, p)
    end

    local page_lang = {}
    if meta.pageCount then
        table.insert(page_lang, tostring(meta.pageCount) .. " pages")
    end
    if meta.language then
        table.insert(page_lang, meta.language)
    end
    if #page_lang > 0 then
        table.insert(lines, table.concat(page_lang, " · "))
    end

    table.insert(lines, "")

    if book.readStatus then
        table.insert(lines, "Status: " .. book.readStatus)
    end
    if book.personalRating and book.personalRating > 0 then
        table.insert(lines, "My rating: " .. tostring(book.personalRating) .. "/10")
    end

    if meta.goodreadsRating then
        local gr = "Goodreads: " .. tostring(meta.goodreadsRating)
        if meta.goodreadsReviewCount then
            gr = gr .. " (" .. tostring(meta.goodreadsReviewCount) .. " reviews)"
        end
        table.insert(lines, gr)
    end
    if meta.amazonRating then
        local ar = "Amazon: " .. tostring(meta.amazonRating)
        if meta.amazonReviewCount then
            ar = ar .. " (" .. tostring(meta.amazonReviewCount) .. " reviews)"
        end
        table.insert(lines, ar)
    end

    if type(book.shelves) == "table" and #book.shelves > 0 then
        local shelf_names = {}
        for _, shelf in ipairs(book.shelves) do
            if type(shelf) == "table" then
                table.insert(shelf_names, shelf.name or shelf.shelfName or "?")
            else
                table.insert(shelf_names, tostring(shelf))
            end
        end
        table.insert(lines, "Shelves: " .. table.concat(shelf_names, ", "))
    end

    table.insert(lines, "")

    table.insert(lines, "Format: " .. (book.bookType or "Unknown"))
    if book.fileSizeKb then
        table.insert(lines, "Size: " .. string.format("%.1f", book.fileSizeKb / 1024) .. " MB")
    end
    if meta.isbn13 then
        table.insert(lines, "ISBN: " .. meta.isbn13)
    end
    if book.libraryName then
        table.insert(lines, "Library: " .. book.libraryName)
    end
    if book.lastReadTime then
        local date = tostring(book.lastReadTime):sub(1, 10)
        table.insert(lines, "Last read: " .. date)
    end

    local detail_text = table.concat(lines, "\n")
    local detail_widget = TextBoxWidget:new{
        text = detail_text,
        width = content_w,
        face = Font:getFace("cfont", 20),
    }
    table.insert(content, detail_widget)

    -- Buttons
    table.insert(content, VerticalSpan:new{ width = padding * 2 })

    local local_path = self:getLocalPath(book)
    local is_downloading = (self._downloading_id == book.id)

    local action_btn
    if local_path then
        -- Already downloaded
        action_btn = Button:new{
            text = _("Read"),
            radius = Size.radius.button,
            padding = Size.padding.button,
            callback = function()
                self:openBook(local_path)
            end,
        }
    elseif is_downloading then
        -- Download in progress — button is inert
        action_btn = Button:new{
            text = _("Downloading…"),
            radius = Size.radius.button,
            padding = Size.padding.button,
            enabled = false,
        }
    else
        -- Not downloaded yet
        local dl_label = _("Download")
        if book.fileSizeKb then
            dl_label = dl_label .. string.format(" (%.1f MB)", book.fileSizeKb / 1024)
        end
        action_btn = Button:new{
            text = dl_label,
            radius = Size.radius.button,
            padding = Size.padding.button,
            callback = function()
                self:downloadBook(book)
            end,
        }
    end

    local back_btn = Button:new{
        text = _("← Back"),
        radius = Size.radius.button,
        padding = Size.padding.button,
        callback = function()
            UIManager:close(self.detail_widget)
            if cover_widget and cover_widget.free then
                cover_widget:free()
            end
            self:showLibraryMenu()
        end,
    }

    local btn_row = HorizontalGroup:new{
        align = "center",
        back_btn,
        HorizontalSpan:new{ width = padding * 2 },
        action_btn,
    }
    table.insert(content, CenterContainer:new{
        dimen = Geom:new{ w = content_w, h = btn_row:getSize().h },
        btn_row,
    })

    local frame = FrameContainer:new{
        width = screen_w,
        height = screen_h,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = padding * 2,
        padding_top = padding,
        content,
    }

    self.detail_widget = InputContainer:new{
        dimen = Geom:new{ w = screen_w, h = screen_h },
    }
    table.insert(self.detail_widget, frame)

    UIManager:show(self.detail_widget)
end

return BookLore