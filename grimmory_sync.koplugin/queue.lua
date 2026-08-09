--[[
    Per-(account, book) offline progress queue.

    Page-turn handler writes here instead of calling HTTP. The periodic flusher
    and book-open drain in main.lua pop entries when network is back. Entries
    are latest-wins per (username, book_id) — a rapid burst of page turns
    collapses to one queued entry, the latest — while different accounts'
    progress for the same book occupies separate slots, so on a shared device
    one reader's undrained offline progress is never overwritten by another's.

    Persistence: LuaSettings file at DataStorage:getSettingsDir() ..
    "/grimmory_sync_queue.lua" (DL-001). Survives reader crash / reboot.

    Key: username .. "\n" .. book_id ("\n" cannot occur in a Grimmory
    username; nil username keys under ""). Schema per entry:
    { book_id, server_url, percentage, cfi, username, enqueued_at }.
    username tags the account that produced the progress; a drain only pushes
    an entry while that account is logged in. Unowned entries (nil username)
    push under whatever account is current.

    Legacy migration: pre-composite-schema entries on disk are keyed by bare
    book_id. Lookups fall back to the bare key, and an enqueue replaces the
    bare entry only when the enqueuing account owns it, so another account's
    undrained legacy progress survives the upgrade.

    Non-goal: the key has no server component. Entries store their server_url
    and always push to it (a drain under the wrong server's token gets a 401
    and stays queued), but one username switching servers with undrained
    progress for the same book_id collapses to the latest entry.
]]
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local Queue = {}
Queue.__index = Queue

function Queue.new(opts)
    opts = opts or {}
    local path = opts.path or (DataStorage:getSettingsDir() .. "/grimmory_sync_queue.lua")
    local store = LuaSettings:open(path)
    if not store.data then store.data = {} end
    return setmetatable({ _store = store }, Queue)
end

-- One slot per (account, book). "\n" is unambiguous because Grimmory rejects
-- newlines in usernames; a nil username keys under "".
local function entryKey(username, book_id)
    return (username or "") .. "\n" .. tostring(book_id)
end

-- An entry is owned by `current_username` when it has no stored username
-- (unowned: pre-upgrade or enqueued while logged out, pushes under any
-- account) or its username matches.
local function ownedBy(entry, current_username)
    return entry.username == nil or entry.username == current_username
end

function Queue:enqueue(book_id, server_url, percentage, cfi, username)
    -- Supersede a pre-composite-schema entry (bare key) for this book only if
    -- the enqueuing account owns it; another account's undrained legacy
    -- progress must survive.
    local legacy_key = tostring(book_id)
    local legacy = self._store.data[legacy_key]
    if legacy and ownedBy(legacy, username) then
        self._store.data[legacy_key] = nil
    end
    self._store.data[entryKey(username, book_id)] = {
        book_id      = book_id,
        server_url   = server_url,
        percentage   = percentage,
        cfi          = cfi,
        username     = username,
        enqueued_at  = os.time(),
    }
    self._store:flush()
end

-- Ordered drainable {key, entry} list for the current book. Its progress can
-- live in up to three slots: the legacy bare key, the unowned key (enqueued
-- with no username), and this account's key. Returned oldest-first so a stale
-- slot never pushes after a fresher one (bare predates unowned predates owned:
-- usernames are only ever gained over time, never unset).
function Queue:currentBookDrainable(book_id, current_username)
    local keys = { tostring(book_id), entryKey(nil, book_id) }
    if current_username ~= nil then
        keys[#keys + 1] = entryKey(current_username, book_id)
    end
    local out = {}
    for _, key in ipairs(keys) do
        local entry = self._store.data[key]
        if entry and ownedBy(entry, current_username) then
            out[#out + 1] = { key = key, entry = entry }
        end
    end
    return out
end

-- Drainable {key, entry} list for every book EXCEPT current_book_id.
function Queue:othersDrainable(current_book_id, current_username)
    local skip_book = current_book_id and tostring(current_book_id) or nil
    local out = {}
    for key, entry in pairs(self._store.data) do
        local is_current_book = skip_book and tostring(entry.book_id) == skip_book
        if not is_current_book and ownedBy(entry, current_username) then
            out[#out + 1] = { key = key, entry = entry }
        end
    end
    return out
end

-- Remove a slot iff it still holds `entry` (identity). The async drain
-- collects entries, forks to push them, then removes on the callback -- by
-- then a page turn may have replaced a slot with fresher progress
-- (latest-wins). The identity guard ensures only the exact entry that was
-- pushed is removed, so newer progress is never dropped; it drains next cycle.
function Queue:removeIfUnchanged(key, entry)
    if self._store.data[key] == entry then
        self._store.data[key] = nil
        self._store:flush()
        return true
    end
    return false
end

-- Synchronous drains, kept for any in-process caller (the async path in
-- main.lua uses the collectors above directly). Reimplemented on the
-- collectors so behavior is identical to the pre-async version.
function Queue:drainCurrentBook(book_id, current_username, push_fn)
    for _, item in ipairs(self:currentBookDrainable(book_id, current_username)) do
        local ok, result = pcall(push_fn, item.entry)
        if ok and result then
            self:removeIfUnchanged(item.key, item.entry)
        end
    end
end

function Queue:drainOthers(current_book_id, current_username, push_fn)
    local to_remove = {}
    for _, item in ipairs(self:othersDrainable(current_book_id, current_username)) do
        -- The current book is skipped by entry content, not key shape, so the
        -- push-after-pull gate also covers its legacy/unowned slots -- those
        -- belong to drainCurrentBook, which main.lua gates on the pull.
        local ok, result = pcall(push_fn, item.entry)
        if ok and result then
            to_remove[#to_remove + 1] = item
        end
    end
    for _, item in ipairs(to_remove) do
        if self._store.data[item.key] == item.entry then
            self._store.data[item.key] = nil
        end
    end
    if #to_remove > 0 then
        self._store:flush()
    end
end

-- Look up the queued entry for (username, book_id), falling back to the
-- unowned slots (nil-username key, then legacy bare key).
function Queue:peek(book_id, username)
    return self._store.data[entryKey(username, book_id)]
        or self._store.data[entryKey(nil, book_id)]
        or self._store.data[tostring(book_id)]
end

function Queue:size()
    local count = 0
    for _ in pairs(self._store.data) do count = count + 1 end
    return count
end

return Queue
