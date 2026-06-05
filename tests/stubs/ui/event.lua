--[[
  Canonical Event stub supporting both colon-call and dot-call patterns.

  Plugin code uses Event:new (colon syntax), which desugars to
  Event.new(Event, name, ...). The dispatch below detects the colon-call
  pattern (self_or_name is a table) and skips the self argument so that
  event name is always a string regardless of call form.
]]
local Event = {}
Event.__index = Event

local function make_event(name, ...)
    return setmetatable({ name = name, args = { ... } }, Event)
end

Event.new = function(self_or_name, ...)
    if type(self_or_name) == "table" then
        return make_event(...)
    else
        return make_event(self_or_name, ...)
    end
end

return Event
