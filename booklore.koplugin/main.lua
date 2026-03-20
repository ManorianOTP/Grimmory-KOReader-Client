local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
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
local _ = require("gettext")

local BookLoreApi = require("api")

local BookLore = WidgetContainer:extend{
    name = "booklore",
    is_doc_only = false,
}

function BookLore:init()
    self.settings = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/booklore.lua"
    )
    self.server_url = self.settings:readSetting("server_url", "http://192.168.1.144:6060")
    self.username = self.settings:readSetting("username", "")
    self.token = nil  -- never persist the JWT to disk; re-auth each session

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
    -- Ensure WiFi is up before making requests
    if not NetworkMgr:isWifiOn() then
        NetworkMgr:turnOnWifi()
    end

    local token, err = BookLoreApi:login(server_url, username, password)

    if token then
        self.token = token
        self.server_url = server_url
        self.username = username

        -- Persist server and username (not password or token)
        self.settings:saveSetting("server_url", server_url)
        self.settings:saveSetting("username", username)
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
        UIManager:show(InfoMessage:new{
            text = _("Failed to fetch books:\n") .. tostring(err),
        })
        return
    end

    if type(books) ~= "table" or #books == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No books found."),
        })
        return
    end

    -- Sort by title
    table.sort(books, function(a, b)
        local title_a = a.metadata and a.metadata.title or ""
        local title_b = b.metadata and b.metadata.title or ""
        return title_a:lower() < title_b:lower()
    end)

    -- Cache for reuse when returning from detail view
    self.cached_books = books
    self:showLibraryMenu()
end

function BookLore:showLibraryMenu()
    local books = self.cached_books
    if not books then return end

    -- Build menu items
    local item_table = {}
    for _, book in ipairs(books) do
        local meta = book.metadata or {}
        local title = meta.title or book.fileName or "Untitled"
        local authors = ""
        if type(meta.authors) == "table" and #meta.authors > 0 then
            authors = table.concat(meta.authors, ", ")
        end

        -- Right-aligned text: read status
        local status = book.readStatus or ""

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

function BookLore:showBookDetail(book)
    local meta = book.metadata or {}
    local title = meta.title or book.fileName or "Untitled"
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local padding = Size.padding.large

    -- Ensure cover cache directory exists
    local cache_dir = DataStorage:getDataDir() .. "/cache/booklore"
    os.execute("mkdir -p " .. cache_dir)

    -- Download cover thumbnail
    local cover_widget = nil
    if book.id then
        local cover_path, err = BookLoreApi:downloadCover(
            self.server_url, book.id, self.token, cache_dir
        )
        if cover_path then
            local success, img = pcall(ImageWidget.new, ImageWidget, {
                file = cover_path,
                width = math.floor(screen_w * 0.4),
                height = math.floor(screen_h * 0.3),
                scale_factor = 0,  -- auto-scale to fit within bounds
            })
            if success and img then
                cover_widget = img
            else
                logger.warn("BookLore: failed to load cover image:", img)
            end
        else
            logger.dbg("BookLore: cover download failed:", err)
        end
    end

    -- Build the content column
    local content_w = screen_w - padding * 4
    local content = VerticalGroup:new{ align = "center" }

    -- Title (bold, centered)
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

    -- Cover image (centered)
    if cover_widget then
        table.insert(content, CenterContainer:new{
            dimen = Geom:new{ w = content_w, h = cover_widget:getSize().h },
            cover_widget,
        })
        table.insert(content, VerticalSpan:new{ width = padding })
    end

    -- Detail text
    local lines = {}

    -- Authors
    if type(meta.authors) == "table" and #meta.authors > 0 then
        table.insert(lines, "By: " .. table.concat(meta.authors, ", "))
    end

    -- Series
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

    -- Publisher & date
    if meta.publisher then
        local p = "Publisher: " .. meta.publisher
        if meta.publishedDate then
            p = p .. " (" .. meta.publishedDate .. ")"
        end
        table.insert(lines, p)
    end

    -- Pages & language
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

    -- Read status & rating
    if book.readStatus then
        table.insert(lines, "Status: " .. book.readStatus)
    end
    if book.personalRating and book.personalRating > 0 then
        table.insert(lines, "My rating: " .. tostring(book.personalRating) .. "/10")
    end

    -- Community ratings
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

    -- Shelves
    if type(book.shelves) == "table" and #book.shelves > 0 then
        local shelf_names = {}
        for _, shelf in ipairs(book.shelves) do
            -- Shelf might be a string or table with name field
            if type(shelf) == "table" then
                table.insert(shelf_names, shelf.name or shelf.shelfName or "?")
            else
                table.insert(shelf_names, tostring(shelf))
            end
        end
        table.insert(lines, "Shelves: " .. table.concat(shelf_names, ", "))
    end

    table.insert(lines, "")

    -- File info
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

    -- Last read
    if book.lastReadTime then
        -- Trim the timestamp to just the date
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

    -- Back button
    table.insert(content, VerticalSpan:new{ width = padding * 2 })
    local back_btn = Button:new{
        text = _("← Back to Library"),
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
    table.insert(content, CenterContainer:new{
        dimen = Geom:new{ w = content_w, h = back_btn:getSize().h },
        back_btn,
    })

    -- Wrap in a padded frame
    local frame = FrameContainer:new{
        width = screen_w,
        height = screen_h,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = padding * 2,
        padding_top = padding,
        content,
    }

    -- InputContainer to capture all taps (prevents fallthrough)
    self.detail_widget = InputContainer:new{
        dimen = Geom:new{ w = screen_w, h = screen_h },
    }
    table.insert(self.detail_widget, frame)

    UIManager:show(self.detail_widget)
end

return BookLore