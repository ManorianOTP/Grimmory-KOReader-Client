--[[
  Stub WidgetContainer base class.

  grimmory_sync/main.lua calls WidgetContainer:extend{...} at module load.
  This stub provides a minimal extend() so module load succeeds without
  the real KOReader widget hierarchy.
]]
local WidgetContainer = {}
WidgetContainer.__index = WidgetContainer

function WidgetContainer:extend(fields)
    local cls = setmetatable({}, { __index = self })
    for k, v in pairs(fields or {}) do
        cls[k] = v
    end
    cls.__index = cls
    function cls:new(o)
        return setmetatable(o or {}, self)
    end
    return cls
end

return WidgetContainer
