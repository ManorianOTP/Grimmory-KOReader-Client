local spec_helper = require("spec_helper")
local Sessions = require("sessions")
local State = require("state")

local function session(overrides)
    local value = {
        book_id = 99,
        file_type = "PDF",
        started_at = 1704067200,
        last_event_at = 1704067265,
        start_percentage = 10.25,
        end_percentage = 12.5,
        start_position = "4",
        end_position = "7",
    }
    for key, item in pairs(overrides or {}) do value[key] = item end
    return value
end

describe("reading-session wire helpers", function()
    it("builds a type-correct UTC payload instead of hardcoding EPUB", function()
        assert.same({
            bookId = 99,
            bookType = "PDF",
            startTime = "2024-01-01T00:00:00Z",
            endTime = "2024-01-01T00:01:05Z",
            durationSeconds = 65,
            startProgress = 10.25,
            endProgress = 12.5,
            progressDelta = 2.25,
            startLocation = "4",
            endLocation = "7",
        }, assert(Sessions.buildPayload(session())))
    end)

    it("matches an acknowledged retry across camelCase and snake_case responses", function()
        -- Independent wire observation: do not build the retry oracle with
        -- the production function under test.
        local payload = {
            bookId = 99,
            bookType = "PDF",
            startTime = "2024-01-01T00:00:00Z",
            endTime = "2024-01-01T00:01:05Z",
            durationSeconds = 65,
            startProgress = 10.1234567,
            endProgress = 12.5,
            progressDelta = 2.3765433,
            startLocation = "4",
            endLocation = "7",
        }
        assert.is_true(Sessions.matchesRemote(payload, {
            book_id = 99,
            book_type = "PDF",
            start_time = payload.startTime,
            end_time = payload.endTime,
            duration_seconds = 65,
            start_progress = 10.1235,
            end_progress = 12.5,
            progress_delta = 2.37654,
            start_location = "4",
            end_location = "7",
        }))
        local acknowledged = {
            bookId = 99,
            bookType = "PDF",
            startTime = payload.startTime,
            endTime = payload.endTime,
            durationSeconds = 65,
            startProgress = 10.1235,
            endProgress = 12.5,
            progressDelta = 2.37654,
            startLocation = "4",
            endLocation = "7",
        }
        for field, mutation in pairs({
            durationSeconds = 66,
            endProgress = 13.5,
            progressDelta = 2.37659,
            startLocation = "wrong-start",
            endLocation = "wrong-end",
        }) do
            local changed = {}
            for key, value in pairs(acknowledged) do changed[key] = value end
            changed[field] = mutation
            assert.is_false(Sessions.matchesRemote(payload, changed),
                field .. " must be part of the retry identity")
        end
    end)

    it("unwraps paginated server results", function()
        local rows = { { id = 1 }, { id = 2 } }
        assert.equals(rows, Sessions.responseItems({ content = rows, totalPages = 1 }))
        assert.equals(rows, Sessions.responseItems(rows))
        assert.same({}, Sessions.responseItems("invalid"))
    end)

    it("rejects invalid types, times, percentages, and oversized locations", function()
        local invalid_cases = {
            session{ file_type = "AUDIOBOOK" },
            session{ last_event_at = 1704067199 },
            session{ start_percentage = -1 },
            session{ end_percentage = 101 },
            session{ start_position = string.rep("x", 501) },
            session{ end_position = string.rep("x", 501) },
        }
        for _, value in ipairs(invalid_cases) do
            assert.is_nil(Sessions.buildPayload(value))
        end
    end)
end)

describe("durable session state", function()
    local path
    local meta

    before_each(function()
        spec_helper.setup()
        path = spec_helper._tmp_dir .. "/grimmory_sync_state.lua"
        meta = {
            username = "alice",
            server_url = "https://grimmory.example",
            book_id = 99,
            file_id = 501,
            file_type = "EPUB",
            path = "/books/example.epub",
        }
    end)

    after_each(function()
        spec_helper.teardown()
    end)

    it("discards sub-threshold opens and durably queues the minimum duration", function()
        local state = State.new{ path = path }
        state:beginSession(meta, { at = 100, percentage = 10, position = "cfi-a" })
        assert.is_nil(state:finalizeSession(meta,
            { at = 129, percentage = 11, position = "cfi-b" }, 30))

        local reloaded = State.new{ path = path }
        assert.equals(0, #reloaded:pendingSessions("alice", meta.server_url))
        assert.is_nil(reloaded:get(meta).active_session)

        reloaded:beginSession(meta, { at = 200, percentage = 20, position = "cfi-c" })
        local finalized = assert(reloaded:finalizeSession(meta,
            { at = 230, percentage = 25, position = "cfi-d" }, 30))
        assert.equals(30, finalized.duration_seconds)

        local reloaded_again = State.new{ path = path }
        local pending = reloaded_again:pendingSessions("alice", meta.server_url)
        assert.equals(1, #pending)
        assert.equals(200, pending[1].session.started_at)
        assert.equals(230, pending[1].session.last_event_at)
    end)

    it("persists attempted state before acknowledgement removal", function()
        local state = State.new{ path = path }
        state:beginSession(meta, { at = 100, percentage = 10, position = "cfi-a" })
        state:finalizeSession(meta,
            { at = 140, percentage = 15, position = "cfi-b" }, 30)
        local item = assert(state:pendingSessions("alice", meta.server_url)[1])

        assert.is_true(state:markSessionAttempted(item))
        local after_attempt = State.new{ path = path }
        local durable_item = assert(
            after_attempt:pendingSessions("alice", meta.server_url)[1])
        assert.is_true(durable_item.session.attempted)
        assert.is_number(durable_item.session.attempted_at)

        assert.is_true(after_attempt:removeSessionIfUnchanged(durable_item))
        local after_ack = State.new{ path = path }
        assert.equals(0, #after_ack:pendingSessions("alice", meta.server_url))
    end)

    it("isolates pending work by account, server, and selected file", function()
        local state = State.new{ path = path }
        local bob = {}
        for key, value in pairs(meta) do bob[key] = value end
        bob.username = "bob"
        bob.file_id = 502
        bob.path = "/books/bob.epub"
        local other_server = {}
        for key, value in pairs(meta) do other_server[key] = value end
        other_server.server_url = "https://other.example"

        for index, identity in ipairs({ meta, bob, other_server }) do
            state:beginSession(identity,
                { at = index * 100, percentage = 10, position = "start" })
            state:finalizeSession(identity,
                { at = index * 100 + 30, percentage = 20, position = "end" }, 30)
        end

        local alice = state:pendingSessions("alice", meta.server_url)
        local bob_pending = state:pendingSessions("bob", meta.server_url)
        local other = state:pendingSessions("alice", other_server.server_url)
        assert.equals(1, #alice)
        assert.equals(501, alice[1].entry.file_id)
        assert.equals(1, #bob_pending)
        assert.equals(502, bob_pending[1].entry.file_id)
        assert.equals(1, #other)
        assert.equals(other_server.server_url, other[1].entry.server_url)
    end)
end)
