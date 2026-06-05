--[[
    Per-book offline progress queue.

    Page-turn handler writes here instead of calling HTTP. The periodic flusher
    and book-open drain in main.lua pop entries when network is back. Entries
    are latest-wins per book_id (overwrite on enqueue) so we never push stale
    intermediate progress.

    Persistence: LuaSettings file at DataStorage:getSettingsDir() ..
    "/booklore_sync_queue.lua" (DL-001). Survives reader crash / reboot.

    Schema per entry: { server_url, percentage, cfi, enqueued_at }
    (book_id is the table key, tostring()-coerced so JSON-encoding round-trips
    cleanly via the dkjson stub).
]]
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local Queue = {}
Queue.__index = Queue

function Queue.new(opts)
    opts = opts or {}
    local path = opts.path or (DataStorage:getSettingsDir() .. "/booklore_sync_queue.lua")
    local store = LuaSettings:open(path)
    if not store.data then store.data = {} end
    return setmetatable({ _store = store }, Queue)
end

function Queue:enqueue(book_id, server_url, percentage, cfi)
    local key = tostring(book_id)
    self._store.data[key] = {
        book_id      = book_id,
        server_url   = server_url,
        percentage   = percentage,
        cfi          = cfi,
        enqueued_at  = os.time(),
    }
    self._store:flush()
end

function Queue:drainCurrentBook(book_id, push_fn)
    local key = tostring(book_id)
    local entry = self._store.data[key]
    if not entry then return end
    local ok, result = pcall(push_fn, entry)
    if ok and result then
        self._store.data[key] = nil
        self._store:flush()
    end
end

function Queue:drainOthers(current_book_id, push_fn)
    local skip_key = current_book_id and tostring(current_book_id) or nil
    local to_remove = {}
    for key, entry in pairs(self._store.data) do
        if key ~= skip_key then
            local ok, result = pcall(push_fn, entry)
            if ok and result then
                to_remove[#to_remove + 1] = key
            end
        end
    end
    for _, key in ipairs(to_remove) do
        self._store.data[key] = nil
    end
    if #to_remove > 0 then
        self._store:flush()
    end
end

function Queue:peek(book_id)
    return self._store.data[tostring(book_id)]
end

function Queue:size()
    local count = 0
    for _ in pairs(self._store.data) do count = count + 1 end
    return count
end

return Queue
