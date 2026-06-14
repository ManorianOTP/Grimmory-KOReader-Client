-- Stub InfoMessage widget.
-- Some plugins require this at file scope. The constructor captures the options
-- table and stores the instance so tests can inspect the most recent message.
local InfoMessage = {}
InfoMessage.__index = InfoMessage

InfoMessage._last = nil

function InfoMessage:new(opts)
    local instance = setmetatable(opts or {}, self)
    InfoMessage._last = instance
    return instance
end

return InfoMessage
