-- Stub MultiConfirmBox widget.
-- booklore_sync/main.lua requires this at file scope.
-- Stub constructor captures the options table and stores the instance so that
-- tests can retrieve the callbacks and invoke them directly.
local MultiConfirmBox = {}
MultiConfirmBox.__index = MultiConfirmBox

-- Holds the most recently constructed instance for test inspection.
MultiConfirmBox._last = nil

function MultiConfirmBox:new(opts)
    local instance = setmetatable(opts or {}, self)
    MultiConfirmBox._last = instance
    return instance
end

return MultiConfirmBox
