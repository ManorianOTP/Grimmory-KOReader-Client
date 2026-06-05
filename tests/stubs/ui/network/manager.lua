--[[
  Stub NetworkMgr for specs.

  isWifiOn() returns the module-level _wifi boolean (default true).
  _set_wifi(b) and _reset() let specs control connectivity.
]]
local NetworkMgr = {}

local _wifi = true

function NetworkMgr:isWifiOn()
    return _wifi
end

function NetworkMgr._set_wifi(b)
    _wifi = b
end

function NetworkMgr._reset()
    _wifi = true
end

return NetworkMgr
