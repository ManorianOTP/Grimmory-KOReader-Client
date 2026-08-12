-- Pure reading-session payload and retry-deduplication helpers.

local Sessions = {}

local VALID_TYPES = {
    EPUB = true, PDF = true, CBX = true, FB2 = true, MOBI = true, AZW3 = true,
}

local function iso8601(timestamp)
    local t = os.date("!*t", tonumber(timestamp))
    return string.format("%04d-%02d-%02dT%02d:%02d:%02dZ",
        t.year, t.month, t.day, t.hour, t.min, t.sec)
end

local function location(value)
    if value == nil then return nil end
    value = tostring(value)
    if #value > 500 then return nil end
    return value
end

function Sessions.buildPayload(session)
    local book_id = tonumber(session.book_id)
    local book_type = type(session.file_type) == "string"
        and session.file_type:upper() or nil
    local started_at = tonumber(session.started_at)
    local ended_at = tonumber(session.last_event_at)
    local start_progress = tonumber(session.start_percentage)
    local end_progress = tonumber(session.end_percentage)
    if not book_id or not VALID_TYPES[book_type] or not started_at or not ended_at
            or ended_at < started_at or not start_progress or not end_progress
            or start_progress < 0 or start_progress > 100
            or end_progress < 0 or end_progress > 100 then
        return nil, "invalid-session"
    end
    local start_location, end_location = location(session.start_position),
        location(session.end_position)
    if session.start_position ~= nil and not start_location then
        return nil, "start-location-too-long"
    end
    if session.end_position ~= nil and not end_location then
        return nil, "end-location-too-long"
    end
    return {
        bookId = book_id,
        bookType = book_type,
        startTime = iso8601(started_at),
        endTime = iso8601(ended_at),
        durationSeconds = math.max(0, ended_at - started_at),
        startProgress = start_progress,
        endProgress = end_progress,
        progressDelta = math.max(0, end_progress - start_progress),
        startLocation = start_location,
        endLocation = end_location,
    }
end

-- Grimmory persists reader progress at the web contract's six-significant-
-- digit precision.  Compare that explicit wire representation rather than a
-- broad epsilon, which could incorrectly acknowledge a nearby different
-- session and delete the durable retry.
local function serverPrecision(value)
    local number = tonumber(value)
    if not number or number ~= number
            or number == math.huge or number == -math.huge then return nil end
    return tonumber(string.format("%.6g", number))
end

local function sameProgress(a, b)
    local left, right = serverPrecision(a), serverPrecision(b)
    return left ~= nil and right ~= nil and left == right
end

local function sameInteger(a, b)
    local left, right = tonumber(a), tonumber(b)
    return left ~= nil and right ~= nil
        and left == math.floor(left) and right == math.floor(right)
        and left == right
end

function Sessions.matchesRemote(payload, remote)
    if type(remote) ~= "table" then return false end
    return tonumber(remote.bookId or remote.book_id) == tonumber(payload.bookId)
        and tostring(remote.bookType or remote.book_type) == tostring(payload.bookType)
        and tostring(remote.startTime or remote.start_time) == tostring(payload.startTime)
        and tostring(remote.endTime or remote.end_time) == tostring(payload.endTime)
        and sameInteger(remote.durationSeconds or remote.duration_seconds,
            payload.durationSeconds)
        and sameProgress(remote.startProgress or remote.start_progress, payload.startProgress)
        and sameProgress(remote.endProgress or remote.end_progress, payload.endProgress)
        and sameProgress(remote.progressDelta or remote.progress_delta,
            payload.progressDelta)
        and tostring(remote.startLocation or remote.start_location or "")
            == tostring(payload.startLocation or "")
        and tostring(remote.endLocation or remote.end_location or "")
            == tostring(payload.endLocation or "")
end

function Sessions.responseItems(decoded)
    if type(decoded) ~= "table" then return {} end
    if type(decoded.content) == "table" then return decoded.content end
    return decoded
end

Sessions.iso8601 = iso8601
Sessions.serverPrecision = serverPrecision
return Sessions
