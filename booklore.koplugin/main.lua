local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local logger = require("logger")
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
                text = _("Test: Book Count"),
                callback = function()
                    self:testBookCount()
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

function BookLore:testBookCount()
    if not self.token then
        UIManager:show(InfoMessage:new{
            text = _("Not logged in. Please login first."),
        })
        return
    end

    local books, err = BookLoreApi:getBooks(self.server_url, self.token)

    if books then
        local count = 0
        if type(books) == "table" then
            count = #books
        end

        UIManager:show(InfoMessage:new{
            text = _("Total books in library: ") .. tostring(count),
        })
    else
        UIManager:show(InfoMessage:new{
            text = _("Failed to fetch books:\n") .. tostring(err),
        })
    end
end

return BookLore