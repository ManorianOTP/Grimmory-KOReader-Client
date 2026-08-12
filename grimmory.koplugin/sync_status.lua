-- Read-only fallback for the Wi-Fi badge/menu. The paired sync plugin exposes
-- the richer live model; this reader keeps status visible before that plugin
-- has initialized by joining its durable queue/state files directly.

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local SyncStatus = {}

local function key(entry)
    return (entry.username or "") .. "\n" .. (entry.server_url or "")
        .. "\n" .. tostring(entry.book_id or "")
end

local function fileIdentity(entry)
    if entry.file_id ~= nil then return "id:" .. tostring(entry.file_id) end
    local file_type = entry.file_type or entry.book_type
    if file_type then return "type:" .. tostring(file_type):upper() end
    if entry.path then return "path:" .. tostring(entry.path) end
    return "legacy"
end

local function stateActivity(entry)
    local latest = math.max(
        tonumber(entry.device_observed_at) or 0,
        tonumber(entry.server_observed_at) or 0,
        tonumber(entry.annotations_synced_at) or 0)
    local active = entry.active_session
    if type(active) == "table" then
        latest = math.max(latest, tonumber(active.last_event_at) or 0,
            tonumber(active.started_at) or 0)
    end
    for _, session in ipairs(entry.sessions or {}) do
        latest = math.max(latest, tonumber(session.last_event_at) or 0,
            tonumber(session.started_at) or 0)
    end
    return latest
end

local function prefer(current, item_key, entry, score)
    if not current or score > current.score
            or score == current.score
                and tostring(item_key) > tostring(current.key) then
        return { key = item_key, entry = entry, score = score }
    end
    return current
end

function SyncStatus.pendingBooks()
    local settings_dir = DataStorage:getSettingsDir()
    local progress = LuaSettings:open(settings_dir .. "/grimmory_sync_queue.lua")
    local state = LuaSettings:open(settings_dir .. "/grimmory_sync_state.lua")
    local downloads = LuaSettings:open(settings_dir .. "/grimmory_downloads.lua")
    local settings = LuaSettings:open(settings_dir .. "/grimmory.lua")
    local active = settings:readSetting("active_account") or {}
    local display, rows = {}, {}
    for registry_key, entry in pairs(downloads.data or {}) do
        if type(entry) == "table" and entry.server_id ~= nil then
            local display_key = (entry.server_url or "") .. "\n"
                .. tostring(entry.server_id)
            display[display_key] = display[display_key] or {}
            display[display_key][#display[display_key] + 1] = {
                key = registry_key, entry = entry,
            }
        end
    end
    local function displayFor(entry)
        local candidates = display[(entry.server_url or "") .. "\n"
            .. tostring(entry.book_id)] or {}
        table.sort(candidates, function(a, b)
            return tostring(a.key) < tostring(b.key)
        end)
        local identity = fileIdentity(entry)
        local primary
        for _, candidate in ipairs(candidates) do
            if fileIdentity(candidate.entry) == identity then return candidate.entry end
            if not primary and candidate.entry.is_primary == true then
                primary = candidate.entry
            end
        end
        return primary or (candidates[1] and candidates[1].entry) or {}
    end
    local function ensure(entry)
        local k = key(entry)
        local row = rows[k]
        if not row then
            local d = displayFor(entry)
            row = {
                key = k, book_id = entry.book_id, server_url = entry.server_url,
                username = entry.username, title = entry.title or d.title,
                path = entry.path or d.path, file_type = entry.file_type or d.book_type,
                features = {},
            }
            row.title = row.title or (row.path and row.path:match("([^/\\]+)$"))
                or ("Book " .. tostring(row.book_id))
            rows[k] = row
        end
        row.active = (not active.server_url or not row.server_url
                or active.server_url == row.server_url)
            and (not active.username or not row.username
                or active.username == row.username)
        return row
    end
    local selected_progress = {}
    for progress_key, entry in pairs(progress.data or {}) do
        if type(entry) == "table" and entry.book_id ~= nil then
            local row_key = key(entry)
            selected_progress[row_key] = prefer(selected_progress[row_key],
                progress_key, entry, tonumber(entry.enqueued_at) or 0)
        end
    end

    local state_items, dirty_groups, selected_state = {}, {}, {}
    for state_key, entry in pairs(state.data or {}) do
        if type(entry) == "table" and entry.book_id ~= nil then
            state_items[#state_items + 1] = { key = state_key, entry = entry }
            local conflicts = type(entry.annotation_conflicts) == "table"
                and next(entry.annotation_conflicts) ~= nil
            local sessions = #(entry.sessions or {}) > 0
            local dirty = entry.annotations_dirty or conflicts or sessions
            local row_key = key(entry)
            if dirty then dirty_groups[row_key] = true end
            local chosen_progress = selected_progress[row_key]
            local matches = not chosen_progress
                or fileIdentity(entry) == fileIdentity(chosen_progress.entry)
            if matches and (chosen_progress or dirty) then
                selected_state[row_key] = prefer(selected_state[row_key],
                    state_key, entry, stateActivity(entry))
            end
        end
    end

    for row_key, selected in pairs(selected_progress) do
        local entry = selected.entry
        local row = ensure(entry)
        local d = displayFor(entry)
        row.title = entry.title or d.title or row.title
        row.path = entry.path or d.path or row.path
        row.file_type = entry.file_type or d.book_type or row.file_type
        row.features.progress = true
        row.device_percentage = entry.percentage
        row.device_position = entry.position_data or entry.cfi
        local selected_entry = selected_state[row_key]
            and selected_state[row_key].entry
        if selected_entry then
            row.server_percentage = selected_entry.server_percentage
            row.server_position = selected_entry.server_position
        end
    end
    for row_key in pairs(dirty_groups) do
        if not rows[row_key] and selected_state[row_key] then
            local entry = selected_state[row_key].entry
            local row = ensure(entry)
            row.device_percentage = entry.device_percentage
            row.device_position = entry.device_position
            row.server_percentage = entry.server_percentage
            row.server_position = entry.server_position
        end
    end
    for _, item in ipairs(state_items) do
        local entry = item.entry
        local conflicts = type(entry.annotation_conflicts) == "table"
            and next(entry.annotation_conflicts) ~= nil
        local sessions = #(entry.sessions or {}) > 0
        local row = rows[key(entry)]
        if row and (entry.annotations_dirty or conflicts or sessions) then
            row.features.annotations = row.features.annotations
                or entry.annotations_dirty or conflicts or nil
            row.features.sessions = row.features.sessions or sessions or nil
        end
    end
    for row_key, selected in pairs(selected_state) do
        local row = rows[row_key]
        if row then row.annotation_conflicts = selected.entry.annotation_conflicts end
    end
    local out = {}
    for _, row in pairs(rows) do out[#out + 1] = row end
    table.sort(out, function(a, b)
        if a.active ~= b.active then return a.active == true end
        local at, bt = tostring(a.title):lower(), tostring(b.title):lower()
        if at ~= bt then return at < bt end
        return tostring(a.key) < tostring(b.key)
    end)
    return out
end

function SyncStatus.badgeText(count)
    count = tonumber(count) or 0
    if count <= 0 then return nil end
    return count > 9 and "9+" or tostring(math.floor(count))
end

-- Fixed geometry keeps one- and two-character labels inside the same circular
-- dot instead of allowing the text width to consume the Wi-Fi glyph.
function SyncStatus.badgeModel(count, icon_size)
    local badge_text = SyncStatus.badgeText(count)
    if not badge_text then return nil end
    icon_size = math.max(1, tonumber(icon_size) or 1)
    local diameter = math.max(1, math.floor(icon_size * 0.52 + 0.5))
    return {
        text = badge_text,
        diameter = diameter,
        x = icon_size - diameter,
        y = 0,
    }
end

return SyncStatus
