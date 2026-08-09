--[[
    Download registry + destination paths.

    The registry file (grimmory_downloads.lua in the settings dir) is the
    only runtime contract between the two plugins: grimmory_sync reads it
    directly (lookupBookId in grimmory_sync.koplugin/main.lua) to map the
    currently open file path back to a Grimmory book_id. The key format
    (server_url .. "|" .. book_id) and the entry shape
    { path, server_id, server_url } must not change without updating that
    reader.

    Standalone module — no KOReader widget dependencies — so the registry
    contract and the stale-entry pruning are unit-testable off device.
]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local Downloads = {}
Downloads.__index = Downloads

function Downloads.registryKey(server_url, book_id)
    return server_url .. "|" .. tostring(book_id)
end

--- @param opts table:
--   download_dir  string: destination directory for downloaded books
--   registry      LuaSettings|nil: override for specs; defaults to the
--                 shared on-disk registry grimmory_sync also reads
function Downloads.new(opts)
    local self = setmetatable({}, Downloads)
    self.download_dir = opts.download_dir
    self.registry = opts.registry or LuaSettings:open(
        DataStorage:getSettingsDir() .. "/grimmory_downloads.lua"
    )
    return self
end

--- Destination path for a book download, sanitized for the device FS.
function Downloads:destPath(book)
    local raw_name = book.fileName or ("book_" .. tostring(book.id))
    local safe_name = util.getSafeFilename(raw_name, self.download_dir)
    local path = self.download_dir .. "/" .. safe_name
    return util.fixUtf8(path, "_")
end

--- Resolve the on-disk path for an already-downloaded book, or nil.
-- A registry entry whose file no longer exists (user deleted it from the
-- file manager) is pruned so the detail page offers Download again.
function Downloads:localPath(server_url, book)
    if not book.id then return nil end
    local key = Downloads.registryKey(server_url, book.id)
    local entry = self.registry:readSetting(key)
    if entry and entry.path then
        if lfs.attributes(entry.path, "mode") == "file" then
            return entry.path
        else
            self.registry:delSetting(key)
            self.registry:flush()
            return nil
        end
    end
    return nil
end

--- Record a completed download so localPath (and grimmory_sync) can find it.
function Downloads:register(server_url, book, path)
    local key = Downloads.registryKey(server_url, book.id)
    self.registry:saveSetting(key, {
        path = path,
        server_id = book.id,
        server_url = server_url,
    })
    self.registry:flush()
end

return Downloads
