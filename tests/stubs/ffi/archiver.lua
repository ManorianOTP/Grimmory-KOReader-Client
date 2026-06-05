--[[
  Stub of ffi/archiver that delegates to tests/support/epub_reader.lua.

  Mirrors the surface cfi.lua uses: Reader:new(), open(), iterate(),
  extractToMemory(), close().
]]
local epub_reader = require("epub_reader")

local Archiver = {}

Archiver.Reader = {}
Archiver.Reader.__index = Archiver.Reader

function Archiver.Reader:new()
    local obj = epub_reader:new()
    return obj
end

return Archiver
