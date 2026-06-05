--[[
  Directory-tree Reader stub implementing the ffi/archiver surface.

  cfi.lua calls: open(path), iterate(), extractToMemory(name), close().
  This stub reads from an unzipped EPUB directory tree so tests run without
  a real ZIP file or minizip FFI dependency.

  The iterate-then-extractToMemory pattern that cfi.lua relies on is
  preserved: iterate() can be drained safely; extractToMemory() works
  regardless of whether iterate() has been called.
]]
local lfs = require("lfs")

local Reader = {}
Reader.__index = Reader

function Reader:new()
    return setmetatable({ _root = nil, _entries = nil }, self)
end

function Reader:open(path)
    self._root    = path
    self._entries = nil  -- lazily populated
end

-- Recursively collect all file paths relative to root.
local function collect_entries(root, rel, out)
    for entry in lfs.dir(root .. (rel == "" and "" or ("/" .. rel))) do
        if entry ~= "." and entry ~= ".." then
            local rel_entry = rel == "" and entry or (rel .. "/" .. entry)
            local full = root .. "/" .. rel_entry
            local mode = lfs.attributes(full, "mode")
            if mode == "file" then
                table.insert(out, rel_entry)
            elseif mode == "directory" then
                collect_entries(root, rel_entry, out)
            end
        end
    end
end

local function ensure_entries(self)
    if self._entries then return end
    self._entries = {}
    if self._root then
        collect_entries(self._root, "", self._entries)
    end
end

-- iterate() returns a stateless iterator over archive entries.
-- cfi.lua drains it before calling extractToMemory; drain is side-effect free.
function Reader:iterate()
    ensure_entries(self)
    local i = 0
    local entries = self._entries
    return function()
        i = i + 1
        return entries[i]
    end
end

-- extractToMemory(name) returns raw bytes of the named entry, or nil + error.
function Reader:extractToMemory(name)
    if not self._root then
        return nil, "Reader not opened"
    end
    local path = self._root .. "/" .. name
    local f = io.open(path, "rb")
    if not f then
        return nil, "entry not found: " .. tostring(name)
    end
    local data = f:read("*a")
    f:close()
    return data
end

function Reader:close()
    self._root    = nil
    self._entries = nil
end

return Reader
