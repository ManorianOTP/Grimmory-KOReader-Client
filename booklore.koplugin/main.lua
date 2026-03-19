local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")

local BookLore = WidgetContainer:extend{
    name = "booklore",
    is_doc_only = false,
}

function BookLore:init()
    self.ui.menu:registerToMainMenu(self)
end

function BookLore:addToMainMenu(menu_items)
    menu_items.booklore = {
        text = _("BookLore"),
        sorting_hint = "tools",
        callback = function()
            UIManager:show(InfoMessage:new{
                text = _("BookLore plugin loaded successfully!"),
            })
        end,
    }
end

return BookLore