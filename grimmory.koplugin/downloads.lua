--[[
    Download registry + destination paths.

    The registry file (grimmory_downloads.lua in the settings dir) is the
    only runtime contract between the two plugins: grimmory_sync reads it
    directly (lookupBookId in grimmory_sync.koplugin/main.lua) to map the
    currently open file path back to a Grimmory book_id. Primary downloads
    retain the key (server_url .. "|" .. book_id); alternative formats append
    their exact file ID. Every entry retains path/server_id/server_url for the
    sync reader and adds native file identity for multi-format safety.

    Standalone module — no KOReader widget dependencies — so the registry
    contract and the stale-entry pruning are unit-testable off device.
]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local Downloads = {}
Downloads.__index = Downloads

function Downloads.registryKey(server_url, book_id, file_id, is_primary)
    local key = server_url .. "|" .. tostring(book_id)
    -- Preserve the long-standing primary-file key read by existing installs.
    -- Alternative files need their exact Grimmory ID to coexist safely.
    if file_id ~= nil and not is_primary then
        key = key .. "|file:" .. tostring(file_id)
    end
    return key
end

--- @param opts table:
--   download_dir  string: destination directory for downloaded books
--   registry      LuaSettings|nil: override for specs; defaults to the
--                 shared on-disk registry grimmory_sync also reads
--   rename        function|nil: injectable replacement rename for specs
function Downloads.new(opts)
    local self = setmetatable({}, Downloads)
    self.download_dir = opts.download_dir
    self.registry = opts.registry or LuaSettings:open(
        DataStorage:getSettingsDir() .. "/grimmory_downloads.lua"
    )
    self.rename = opts.rename or os.rename
    return self
end

--- Destination path for a book download, sanitized for the device FS.
function Downloads:destPath(book, book_file)
    book_file = book_file or book.primaryFile or book
    local raw_name = book_file.fileName or ("book_" .. tostring(book.id))
    local safe_name = util.getSafeFilename(raw_name, self.download_dir)
    local path = self.download_dir .. "/" .. safe_name
    return util.fixUtf8(path, "_")
end

--- Resolve the on-disk path for an already-downloaded book, or nil.
-- A registry entry whose file no longer exists (user deleted it from the
-- file manager) is pruned so the detail page offers Download again.
function Downloads:localPath(server_url, book, book_file)
    if not book.id then return nil end
    book_file = book_file or book.primaryFile
    local key = Downloads.registryKey(server_url, book.id,
        book_file and book_file.id, book_file == nil or book_file.isPrimary == true)
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
function Downloads:register(server_url, book, path, book_file)
    book_file = book_file or book.primaryFile
    local is_primary = book_file == nil or book_file.isPrimary == true
    local key = Downloads.registryKey(server_url, book.id,
        book_file and book_file.id, is_primary)
    self.registry:saveSetting(key, {
        path = path,
        server_id = book.id,
        server_url = server_url,
        title = book.title,
        author = book.author or book.authors,
        file_id = book_file and book_file.id or nil,
        file_name = book_file and book_file.fileName or book.fileName,
        book_type = book_file and book_file.bookType or book.bookType,
        is_primary = is_primary,
    })
    self.registry:flush()
end

--- Publish a fully validated temporary download. POSIX rename replaces an
-- existing destination in one operation, so the old valid file is never
-- deleted first. A failed rename leaves both the old destination and registry
-- untouched; the caller may then remove the temporary file.
function Downloads:publish(server_url, book, temp_path, dest_path, book_file,
        register_completed)
    local ok, err = self.rename(temp_path, dest_path)
    if not ok then
        return nil, "could not replace downloaded file: " .. tostring(err)
    end
    if register_completed then
        register_completed()
    else
        self:register(server_url, book, dest_path, book_file)
    end
    return true
end

-- Existing local files grouped by Grimmory book id for one server. Multiple
-- downloaded formats are retained; missing registry paths are ignored.
function Downloads:localFilesByBook(server_url)
    local out, seen = {}, {}
    for _, entry in pairs(self.registry.data or {}) do
        if type(entry) == "table" and entry.server_id ~= nil
                and entry.server_url == server_url and entry.path
                and lfs.attributes(entry.path, "mode") == "file"
                and not seen[entry.path] then
            local id = tostring(entry.server_id)
            out[id] = out[id] or {}
            out[id][#out[id] + 1] = entry.path
            seen[entry.path] = true
        end
    end
    return out
end

return Downloads
