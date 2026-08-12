--[[
    Durable cross-feature sync state.

    Progress itself remains in queue.lua for backwards compatibility. This
    store records the last observed device/server positions plus annotation
    and reading-session work. Records are isolated by account, server, book,
    and selected file so switching accounts or formats cannot cross wires.
]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local State = {}
State.__index = State

local function fileIdentity(meta)
    if meta.file_id ~= nil then return "id:" .. tostring(meta.file_id) end
    if meta.file_type then return "type:" .. tostring(meta.file_type):upper() end
    return "path:" .. tostring(meta.path or "")
end

function State.keyFor(meta)
    return (meta.username or "") .. "\n" .. (meta.server_url or "") .. "\n"
        .. tostring(meta.book_id or "") .. "\n" .. fileIdentity(meta)
end

function State.new(opts)
    opts = opts or {}
    local path = opts.path or (DataStorage:getSettingsDir()
        .. "/grimmory_sync_state.lua")
    local store = opts.store or LuaSettings:open(path)
    if type(store.data) ~= "table" then store.data = {} end
    return setmetatable({ _store = store }, State)
end

local function copyIdentity(target, meta)
    target.book_id = meta.book_id or target.book_id
    target.file_id = meta.file_id ~= nil and meta.file_id or target.file_id
    target.file_type = meta.file_type or target.file_type
    target.server_url = meta.server_url or target.server_url
    target.username = meta.username or target.username
    target.path = meta.path or target.path
    target.title = meta.title or target.title
end

function State:touch(meta)
    local key = State.keyFor(meta)
    local entry = self._store.data[key]
    if type(entry) ~= "table" then
        entry = { annotation_shadow = {}, sessions = {} }
        self._store.data[key] = entry
    end
    copyIdentity(entry, meta)
    entry.annotation_shadow = entry.annotation_shadow or {}
    entry.sessions = entry.sessions or {}
    return key, entry
end

function State:get(meta)
    return self._store.data[State.keyFor(meta)]
end

function State:setDevice(meta, percentage, position, observed_at)
    local _, entry = self:touch(meta)
    entry.device_percentage = percentage
    entry.device_position = position
    entry.device_observed_at = observed_at or os.time()
    self._store:flush()
end

function State:setServer(meta, percentage, position, observed_at)
    local _, entry = self:touch(meta)
    entry.server_percentage = percentage
    entry.server_position = position
    entry.server_observed_at = observed_at or os.time()
    self._store:flush()
end

function State:markAnnotationsDirty(meta, dirty)
    local _, entry = self:touch(meta)
    entry.annotations_dirty = dirty == true
    self._store:flush()
end

function State:getAnnotationShadow(meta)
    local entry = self:get(meta)
    return entry and entry.annotation_shadow or {}
end

function State:setAnnotationShadow(meta, shadow, dirty)
    local _, entry = self:touch(meta)
    entry.annotation_shadow = shadow or {}
    entry.annotations_dirty = dirty == true
    entry.annotations_synced_at = os.time()
    self._store:flush()
end

function State:setAnnotationConflicts(meta, conflicts)
    local _, entry = self:touch(meta)
    entry.annotation_conflicts = conflicts or {}
    entry.annotations_dirty = next(entry.annotation_conflicts) ~= nil
    self._store:flush()
end

function State:setAnnotationResult(meta, shadow, conflicts, dirty, last_error)
    local _, entry = self:touch(meta)
    entry.annotation_shadow = shadow or entry.annotation_shadow or {}
    entry.annotation_conflicts = conflicts or {}
    entry.annotations_dirty = dirty == true
    entry.annotation_last_error = last_error
    entry.annotations_synced_at = os.time()
    self._store:flush()
end

local function nextSessionId(store)
    local seq = (tonumber(store.data.__session_seq) or 0) + 1
    store.data.__session_seq = seq
    return tostring(os.time()) .. ":" .. tostring(seq)
end

function State:beginSession(meta, sample)
    local _, entry = self:touch(meta)
    entry.active_session = {
        id = nextSessionId(self._store),
        started_at = sample.at or os.time(),
        last_event_at = sample.at or os.time(),
        start_percentage = sample.percentage,
        end_percentage = sample.percentage,
        start_position = sample.position,
        end_position = sample.position,
    }
    self._store:flush()
    return entry.active_session
end

function State:updateSession(meta, sample)
    local _, entry = self:touch(meta)
    local active = entry.active_session
    if not active then return self:beginSession(meta, sample) end
    active.last_event_at = sample.at or os.time()
    active.end_percentage = sample.percentage
    active.end_position = sample.position
    self._store:flush()
    return active
end

-- Finalize the active session. Short accidental opens are discarded, while a
-- long session on one page is retained because time spent reading is real.
function State:finalizeSession(meta, sample, minimum_seconds)
    local _, entry = self:touch(meta)
    local active = entry.active_session
    if not active then return nil end
    if sample then
        active.last_event_at = sample.at or active.last_event_at
        active.end_percentage = sample.percentage or active.end_percentage
        active.end_position = sample.position or active.end_position
    end
    entry.active_session = nil
    local duration = math.max(0,
        (tonumber(active.last_event_at) or 0) - (tonumber(active.started_at) or 0))
    if duration >= (minimum_seconds or 60) then
        active.duration_seconds = duration
        active.book_id = meta.book_id
        active.file_type = meta.file_type
        active.server_url = meta.server_url
        active.username = meta.username
        entry.sessions[#entry.sessions + 1] = active
    else
        active = nil
    end
    self._store:flush()
    return active
end

function State:pendingSessions(username, server_url)
    local out = {}
    for key, entry in pairs(self._store.data) do
        if type(entry) == "table"
                and (entry.username == nil or entry.username == username)
                and (server_url == nil or entry.server_url == server_url) then
            for index, session in ipairs(entry.sessions or {}) do
                out[#out + 1] = {
                    key = key, entry = entry, index = index, session = session,
                }
            end
        end
    end
    table.sort(out, function(a, b)
        return (tonumber(a.session.started_at) or 0)
            < (tonumber(b.session.started_at) or 0)
    end)
    return out
end

function State:markSessionAttempted(item)
    local entry = self._store.data[item.key]
    if entry ~= item.entry then return false end
    for _, session in ipairs(entry.sessions or {}) do
        if session == item.session then
            session.attempted = true
            session.attempted_at = os.time()
            self._store:flush()
            return true
        end
    end
    return false
end

function State:setSessionError(item, message, permanent)
    local entry = self._store.data[item.key]
    if entry ~= item.entry then return false end
    for _, session in ipairs(entry.sessions or {}) do
        if session == item.session then
            session.last_error = tostring(message or "session-sync-failed")
            session.permanent_error = permanent == true
            self._store:flush()
            return true
        end
    end
    return false
end

function State:removeSessionIfUnchanged(item)
    local entry = self._store.data[item.key]
    if entry ~= item.entry then return false end
    for index, session in ipairs(entry.sessions or {}) do
        if session == item.session then
            table.remove(entry.sessions, index)
            self._store:flush()
            return true
        end
    end
    return false
end

function State:entries()
    local out = {}
    for key, entry in pairs(self._store.data) do
        if type(entry) == "table" then
            out[#out + 1] = { key = key, entry = entry }
        end
    end
    return out
end

return State
