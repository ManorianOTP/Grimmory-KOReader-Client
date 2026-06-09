--[[
    Offline library snapshot persistence.

    A snapshot is the last successful library fetch (books + shelves +
    libraries) written to disk so the library can open read-only when the
    device is offline but was logged in before. Kept as a standalone module —
    no KOReader UI dependencies — so the read/write + account-match logic is
    unit-testable off device.

    Persistence is JSON, NOT LuaSettings: the payload is the raw server response
    (JSON-origin tables that can contain null sentinels and other values which
    do NOT survive LuaSettings' Lua-file serialization round-trip on device).
    json.encode/decode round-trips the server data faithfully — the same encoder
    the sync plugin already relies on.

    One file per (username, server_url) at DataStorage:getSettingsDir() ..
    "/booklore_library_cache_<slug>.json": on a shared device, one account's
    fetch must not destroy another account's offline library. Earlier versions
    wrote a single shared file; load() falls back to it (account-checked) so an
    upgraded device keeps its cache until the first fresh fetch, and save()
    removes it.

    The snapshot is also tagged inside with the account that produced it;
    load() returns it only when both username and server_url match, so one
    user's cached library is never rendered while another is logged in.

    Schema: { username, server_url, fetched_at, books, shelves, libraries }
]]
local DataStorage = require("datastorage")
local json = require("json")
local logger = require("logger")

local LibraryCache = {}

-- Filename slug for an account: sanitized username for readability plus a
-- djb2 hash of (username, server_url) so accounts that sanitize identically
-- (or differ only by server) still get distinct files.
local function accountSlug(username, server_url)
    local id = tostring(username or "") .. "\n" .. tostring(server_url or "")
    local h = 5381
    for i = 1, #id do
        h = (h * 33 + id:byte(i)) % 4294967296
    end
    local name = tostring(username or ""):gsub("[^%w]", ""):sub(1, 24)
    return name .. "_" .. string.format("%08x", h)
end

function LibraryCache.path(username, server_url)
    return DataStorage:getSettingsDir() .. "/booklore_library_cache_"
        .. accountSlug(username, server_url) .. ".json"
end

-- The single shared file pre-per-account versions wrote. Read as a fallback
-- by load(), deleted by save().
function LibraryCache.legacy_path()
    return DataStorage:getSettingsDir() .. "/booklore_library_cache.json"
end

-- Read and decode one snapshot file; nil on absence, corruption, or wrong
-- shape (a truncated write must degrade to "no cache", never crash the UI).
local function readSnapshot(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local raw = f:read("*a")
    f:close()
    if not raw or raw == "" then return nil end

    local ok, snap = pcall(json.decode, raw)
    if not ok or type(snap) ~= "table" or type(snap.books) ~= "table" then
        logger.warn("BookLore: library snapshot decode failed:", path)
        return nil
    end
    return snap
end

-- Returns true on success. A failure is non-fatal: the library still works
-- online, we just have no offline cache to fall back to.
function LibraryCache.save(username, server_url, books, shelves, libraries)
    local ok, encoded = pcall(json.encode, {
        username   = username,
        server_url = server_url,
        fetched_at = os.time(),
        books      = books,
        shelves    = shelves,
        libraries  = libraries,
    })
    if not ok or type(encoded) ~= "string" then
        logger.warn("BookLore: library snapshot encode failed:", tostring(encoded))
        return false
    end
    local f, open_err = io.open(LibraryCache.path(username, server_url), "w")
    if not f then
        logger.warn("BookLore: library snapshot write failed:", tostring(open_err))
        return false
    end
    f:write(encoded)
    f:close()
    -- One-time migration: the shared single file is superseded by per-account
    -- files; drop it so stale data doesn't linger on disk.
    os.remove(LibraryCache.legacy_path())
    return true
end

-- Returns the snapshot only when it belongs to the given account, else nil.
function LibraryCache.load(username, server_url)
    local snap = readSnapshot(LibraryCache.path(username, server_url))
        or readSnapshot(LibraryCache.legacy_path())
    if not snap then
        logger.dbg("BookLore: no library snapshot on disk")
        return nil
    end
    if snap.username ~= username or snap.server_url ~= server_url then
        logger.dbg("BookLore: library snapshot is for a different account, ignoring")
        return nil
    end
    return snap
end

return LibraryCache
