--[[
  Stub for KOReader DataStorage.

  Tests call _set_dir(path) before loading plugin code to redirect
  getSettingsDir() to a tmp directory, isolating on-disk state per test.
]]
local DataStorage = {}

local _dir = os.getenv("TMPDIR") or "/tmp"

function DataStorage._set_dir(path)
    _dir = path
end

function DataStorage:getSettingsDir()
    return _dir
end

return DataStorage
