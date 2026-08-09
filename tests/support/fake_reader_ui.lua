--[[
  Stand-in for KOReader ReaderUI.

  KOReader calls plugin handlers as direct methods on the plugin object
  (e.g. sync:onReaderReady()), not via ui:handleEvent dispatch.
  This fake provides the UI surface fields plugin code accesses but
  does not need to dispatch events.

  Surface exposed:
    ui.document.file
    ui.document.info.has_pages
    ui.document:getXPointer()
    ui.document:getPageCount()
    ui.paging:getLastPercent()
    ui.rolling:getLastPercent()
    ui.document:gotoXPointer(xp)
]]
local fake_reader_ui = {}

function fake_reader_ui.new(opts)
    opts = opts or {}

    local ui = {
        _xpointer = opts.xpointer or "/body/DocFragment[1]/body/p[1].0",
        _percent  = opts.percent  or 0.1,
        _pages    = opts.page_count or 100,
    }

    ui.document = {
        file = opts.file or "/books/test.epub",
        info = { has_pages = (opts.has_pages ~= nil) and opts.has_pages or false },
    }

    function ui.document:getXPointer()
        return ui._xpointer
    end

    function ui.document:getPageCount()
        return ui._pages
    end

    function ui.document:gotoXPointer(xp)
        ui._xpointer = xp
    end

    ui.paging = {
        getLastPercent = function(self) return ui._percent end,
        getLastProgress = function(self) return opts.page or math.max(1, math.floor(ui._percent * ui._pages)) end,
    }

    ui.rolling = {
        getLastPercent = function(self) return ui._percent end,
    }

    ui._events = {}
    function ui:handleEvent(event)
        table.insert(self._events, event)
        if event.name == "GotoPage" then
            self._page = event.args[1]
        elseif event.name == "GotoXPointer" then
            self._xpointer = event.args[1]
        end
    end

    return ui
end

return fake_reader_ui
