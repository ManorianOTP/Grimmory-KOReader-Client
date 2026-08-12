--[[
    Per-(account, server, book, file) offline progress queue.

    Page-turn handler writes here instead of calling HTTP. The periodic flusher
    and book-open drain in main.lua pop entries when network is back. Entries
    are latest-wins per (username, server_url, book_id, file identity): a rapid
    burst of page turns collapses to one queued entry, while different accounts,
    Grimmory servers, or downloaded formats occupy separate slots.

    Persistence: LuaSettings file at DataStorage:getSettingsDir() ..
    "/grimmory_sync_queue.lua" (DL-001). Survives reader crash / reboot.

    Key: username .. "\n" .. server_url .. "\n" .. book_id .. "\n" ..
    file identity ("\n" cannot occur in usernames or URLs). Schema per entry:
    { book_id, server_url, percentage, position_data, cfi, username,
      file_id, file_type, enqueued_at }.
    `cfi` remains as a compatibility alias for already-persisted Grimmory
    queue entries; new entries use the format-neutral `position_data`.
    username tags the account that produced the progress; a drain only pushes
    an entry while that account is logged in. Unowned entries (nil username)
    push under whatever account is current.

    Compatibility: bare book_id keys and the previous username+book_id keys
    remain readable and drainable in place. No rewrite migration is needed.
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

local function normalizedType(file_type)
    return type(file_type) == "string" and file_type:upper() or nil
end

local function fileIdentity(file_id, file_type)
    if file_id ~= nil then return "id:" .. tostring(file_id) end
    local kind = normalizedType(file_type)
    if kind then return "type:" .. kind end
    return "legacy"
end

local function entryKey(username, server_url, book_id, file_id, file_type)
    return (username or "") .. "\n" .. (server_url or "") .. "\n"
        .. tostring(book_id) .. "\n" .. fileIdentity(file_id, file_type)
end

-- The schema immediately preceding the file-aware queue keyed by account+book.
local function oldCompositeKey(username, book_id)
    return (username or "") .. "\n" .. tostring(book_id)
end

-- An entry is owned by `current_username` when it has no stored username
-- (unowned: pre-upgrade or enqueued while logged out, pushes under any
-- account) or its username matches.
local function ownedBy(entry, current_username)
    return entry.username == nil or entry.username == current_username
end

local function sameFile(entry, file_id, file_type)
    if entry.file_id ~= nil and file_id ~= nil then
        return tostring(entry.file_id) == tostring(file_id)
    end
    local entry_type, wanted_type = normalizedType(entry.file_type), normalizedType(file_type)
    if entry_type and wanted_type then return entry_type == wanted_type end
    -- Identity-free entries were written by the old EPUB-only sync engine.
    if entry.file_id == nil and entry_type == nil then
        return file_id == nil and wanted_type == nil or wanted_type == "EPUB"
    end
    return entry.file_id == nil and file_id == nil
        and entry_type == wanted_type
end

local function isLegacySlot(key, entry)
    return key == tostring(entry.book_id)
        or key == oldCompositeKey(entry.username, entry.book_id)
end

local function ordered(items)
    table.sort(items, function(a, b)
        local at = tonumber(a.entry.enqueued_at) or 0
        local bt = tonumber(b.entry.enqueued_at) or 0
        if at == bt then return tostring(a.key) < tostring(b.key) end
        return at < bt
    end)
    return items
end

function Queue:enqueue(book_id, server_url, percentage, position_data, username,
        file_id, file_type)
    -- Supersede a pre-composite-schema entry (bare key) for this book only if
    -- the enqueuing account owns it; another account's undrained legacy
    -- progress must survive.
    for _, legacy_key in ipairs({
        tostring(book_id), oldCompositeKey(username, book_id),
    }) do
        local legacy = self._store.data[legacy_key]
        if legacy and ownedBy(legacy, username)
                and sameFile(legacy, file_id, file_type) then
            self._store.data[legacy_key] = nil
        end
    end
    self._store.data[entryKey(username, server_url, book_id, file_id, file_type)] = {
        book_id      = book_id,
        server_url   = server_url,
        percentage   = percentage,
        position_data = position_data,
        -- Keep writing the alias for a downgrade-safe queue and so existing
        -- code inspecting queued EPUB progress continues to see its CFI.
        cfi          = position_data,
        username     = username,
        file_id      = file_id,
        file_type    = file_type,
        enqueued_at  = os.time(),
    }
    self._store:flush()
end

-- Ordered drainable {key, entry} list for the exact currently open file.
-- Compatibility slots without file identity are conservatively treated as
-- current-book progress and retain the pull-before-push gate.
function Queue:currentBookDrainable(book_id, current_username, server_url,
        file_id, file_type)
    local out = {}
    for key, entry in pairs(self._store.data) do
        local same_book = tostring(entry.book_id) == tostring(book_id)
        local current_file
        if isLegacySlot(key, entry) then
            -- Legacy slots lack enough identity to prove they belong to a
            -- different format, so conservatively retain the old book gate.
            current_file = same_book
        elseif server_url == nil and file_id == nil and file_type == nil then
            current_file = same_book
        else
            local same_server = not server_url or not entry.server_url
                or entry.server_url == server_url
            current_file = same_book and same_server
                and sameFile(entry, file_id, file_type)
        end
        if current_file and ownedBy(entry, current_username) then
            out[#out + 1] = { key = key, entry = entry }
        end
    end
    return ordered(out)
end

-- Drainable entries except the exact current server/book/file. A queued PDF
-- must not be pull-gated merely because an EPUB of the same book is now open.
function Queue:othersDrainable(current_book_id, current_username, server_url,
        file_id, file_type)
    local current = {}
    if current_book_id ~= nil then
        for _, item in ipairs(self:currentBookDrainable(current_book_id,
                current_username, server_url, file_id, file_type)) do
            current[item.key] = true
        end
    end
    local out = {}
    for key, entry in pairs(self._store.data) do
        if not current[key] and ownedBy(entry, current_username) then
            out[#out + 1] = { key = key, entry = entry }
        end
    end
    return ordered(out)
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

-- The server-ahead dialog is a decision about this exact open file. Choosing
-- Jump Ahead rejects any local progress captured before that decision; leaving
-- it queued would let the next periodic drain overwrite the position the user
-- just chose. Other books, accounts, servers and formats remain untouched.
function Queue:discardCurrentBook(book_id, current_username, server_url,
        file_id, file_type)
    local removed = 0
    for _, item in ipairs(self:currentBookDrainable(book_id, current_username,
            server_url, file_id, file_type)) do
        if self._store.data[item.key] == item.entry then
            self._store.data[item.key] = nil
            removed = removed + 1
        end
    end
    if removed > 0 then self._store:flush() end
    return removed
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
function Queue:peek(book_id, username, server_url, file_id, file_type)
    if server_url ~= nil or file_id ~= nil or file_type ~= nil then
        local exact = self._store.data[entryKey(username, server_url, book_id,
            file_id, file_type)]
        if exact then return exact end
    end
    local old = self._store.data[oldCompositeKey(username, book_id)]
        or self._store.data[oldCompositeKey(nil, book_id)]
        or self._store.data[tostring(book_id)]
    if old and ownedBy(old, username) then return old end
    local function scan(wanted_username)
        for _, entry in pairs(self._store.data) do
            local same_server = server_url == nil or entry.server_url == server_url
            local file_matches = (file_id == nil and file_type == nil)
                or sameFile(entry, file_id, file_type)
            if tostring(entry.book_id) == tostring(book_id)
                    and entry.username == wanted_username
                    and same_server and file_matches then
                return entry
            end
        end
    end
    return scan(username) or (username ~= nil and scan(nil) or nil)
end

function Queue:size()
    local count = 0
    for _ in pairs(self._store.data) do count = count + 1 end
    return count
end

return Queue
