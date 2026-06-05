--[[
  Adapter over dkjson exposing the encode/decode signatures plugins use.
  Returns nil on parse failure rather than raising.
]]
local dkjson = require("dkjson")

local json = {}

function json.encode(t)
    return dkjson.encode(t)
end

function json.decode(s)
    local ok, val = pcall(dkjson.decode, s)
    if not ok then return nil end
    return val
end

return json
