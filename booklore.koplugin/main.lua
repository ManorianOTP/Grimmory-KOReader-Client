local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
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

    -- Store reference so we can close it later
    self.book_menu = Menu:new{
        title = _("BookLore") .. " (" .. tostring(#books) .. " books)",
        item_table = item_table,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        onMenuChoice = function(menu_instance, item)
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
    local lines = {}

    -- Title
    table.insert(lines, meta.title or "Untitled")
    table.insert(lines, "")

    -- Authors
    if type(meta.authors) == "table" and #meta.authors > 0 then
        table.insert(lines, "By: " .. table.concat(meta.authors, ", "))
    end

    -- Series
    if meta.seriesName then
        local series_str = meta.seriesName
        if meta.seriesNumber then
            series_str = series_str .. " #" .. tostring(meta.seriesNumber)
        end
        if meta.seriesTotal then
            series_str = series_str .. " of " .. tostring(meta.seriesTotal)
        end
        table.insert(lines, "Series: " .. series_str)
    end

    -- Publisher & date
    if meta.publisher then
        local pub_str = meta.publisher
        if meta.publishedDate then
            pub_str = pub_str .. " (" .. meta.publishedDate .. ")"
        end
        table.insert(lines, "Publisher: " .. pub_str)
    end

    -- Page count
    if meta.pageCount then
        table.insert(lines, "Pages: " .. tostring(meta.pageCount))
    end

    table.insert(lines, "")

    -- Status & rating
    if book.readStatus then
        table.insert(lines, "Status: " .. book.readStatus)
    end
    if book.personalRating and book.personalRating > 0 then
        table.insert(lines, "Rating: " .. tostring(book.personalRating) .. "/10")
    end

    -- File info
    table.insert(lines, "")
    table.insert(lines, "Format: " .. (book.bookType or "Unknown"))
    if book.fileSizeKb then
        local size_mb = string.format("%.1f", book.fileSizeKb / 1024)
        table.insert(lines, "Size: " .. size_mb .. " MB")
    end

    UIManager:show(InfoMessage:new{
        text = table.concat(lines, "\n"),
    })
end

return BookLore