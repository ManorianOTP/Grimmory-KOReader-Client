--[[
  Canonical LuaSettings stub.

  The .data field is a public raw table on each instance so plugin code
  that reads registry.data directly (booklore_sync/main.lua:25) sees the
  decoded JSON rather than nil.
]]
local json = require("dkjson")
local LuaSettings = {}
LuaSettings.__index = LuaSettings

function LuaSettings:open(path)
    local obj = setmetatable({ _path = path, data = {} }, self)
    local f = io.open(path, "r")
    if f then
        local raw = f:read("*a")
        f:close()
        if raw and #raw > 0 then
            local ok, decoded = pcall(json.decode, raw)
            if ok and type(decoded) == "table" then
                obj.data = decoded
            end
        end
    end
    return obj
end

function LuaSettings:readSetting(key, default)
    local v = self.data[key]
    if v == nil then return default end
    return v
end

function LuaSettings:saveSetting(key, value)
    self.data[key] = value
end

function LuaSettings:delSetting(key)
    self.data[key] = nil
end

function LuaSettings:flush()
    local dir = self._path:match("^(.+)/[^/]+$")
    if dir then
        local current = ""
        for seg in dir:gmatch("[^/]+") do
            current = current .. "/" .. seg
            local attr = require("lfs").attributes(current)
            if not attr then require("lfs").mkdir(current) end
        end
    end
    local f = io.open(self._path, "w")
    if f then
        f:write(json.encode(self.data, { indent = true }))
        f:close()
    end
end

return LuaSettings
