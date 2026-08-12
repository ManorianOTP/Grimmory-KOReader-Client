--[[
  Sync-status presentation model specs.

  The Wi-Fi badge and menu are rendered by grimmory.koplugin/main.lua, but
  their source of truth is deliberately a widget-free module.  These specs
  exercise the durable fallback path used before the paired sync plugin has
  initialized, including account isolation and the union of progress,
  annotation, and reading-session work into one row per book.
]]
local spec_helper = require("spec_helper")

describe("SyncStatus", function()
    local DataStorage, LuaSettings, SyncStatus

    before_each(function()
        spec_helper.setup()
        DataStorage = require("datastorage")
        LuaSettings = require("luasettings")
        SyncStatus = require("sync_status")
    end)

    after_each(function()
        spec_helper.teardown()
    end)

    local function write_settings(name, data)
        local store = LuaSettings:open(DataStorage:getSettingsDir() .. "/" .. name)
        store.data = data or {}
        store:flush()
    end

    local function set_active(username, server_url)
        write_settings("grimmory.lua", {
            active_account = {
                username = username,
                server_url = server_url,
            },
        })
    end

    describe("badgeText", function()
        it("is hidden when no books are pending", function()
            assert.is_nil(SyncStatus.badgeText(0))
            assert.is_nil(SyncStatus.badgeText(nil))
            assert.is_nil(SyncStatus.badgeText(-1))
        end)

        it("shows exact counts through nine and caps larger counts at 9+", function()
            assert.are.equal("1", SyncStatus.badgeText(1))
            assert.are.equal("9", SyncStatus.badgeText(9))
            assert.are.equal("9+", SyncStatus.badgeText(10))
            assert.are.equal("9+", SyncStatus.badgeText(100))
        end)

        it("uses the same fixed circular geometry for one and 9+", function()
            local one = assert(SyncStatus.badgeModel(1, 50))
            local capped = assert(SyncStatus.badgeModel(14, 50))
            assert.are.equal("1", one.text)
            assert.are.equal("9+", capped.text)
            assert.are.equal(26, one.diameter)
            assert.are.equal(one.diameter, capped.diameter)
            assert.are.equal(24, one.x)
            assert.are.equal(0, one.y)
            assert.is_nil(SyncStatus.badgeModel(0, 50))
        end)
    end)

    it("unions progress, annotations, and sessions into one pending book", function()
        local server = "http://grimmory.local:6060"
        set_active("alice", server)
        write_settings("grimmory_downloads.lua", {
            [server .. "|42"] = {
                server_id = 42,
                server_url = server,
                path = "/mnt/us/documents/The Book.epub",
                title = "The Book",
                book_type = "EPUB",
            },
        })
        write_settings("grimmory_sync_queue.lua", {
            progress = {
                username = "alice",
                server_url = server,
                book_id = 42,
                file_id = 420,
                file_type = "EPUB",
                percentage = 63.25,
                position_data = "epubcfi(/6/4!/4/2:9)",
            },
        })
        write_settings("grimmory_sync_state.lua", {
            state = {
                username = "alice",
                server_url = server,
                book_id = 42,
                file_id = 420,
                file_type = "EPUB",
                annotations_dirty = true,
                sessions = {
                    { id = "session-1", duration_seconds = 300 },
                },
                server_percentage = 58.5,
                server_position = "epubcfi(/6/4!/4/2:2)",
            },
        })

        local rows = SyncStatus.pendingBooks()
        assert.same({{
            key = "alice\n" .. server .. "\n42",
            book_id = 42,
            server_url = server,
            username = "alice",
            title = "The Book",
            path = "/mnt/us/documents/The Book.epub",
            file_type = "EPUB",
            active = true,
            features = { progress = true, annotations = true, sessions = true },
            device_percentage = 63.25,
            device_position = "epubcfi(/6/4!/4/2:9)",
            server_percentage = 58.5,
            server_position = "epubcfi(/6/4!/4/2:2)",
        }}, rows)
    end)

    it("shows the queued device position beside the last observed server position", function()
        local server = "https://books.example"
        set_active("alice", server)
        write_settings("grimmory_sync_queue.lua", {
            progress = {
                username = "alice",
                server_url = server,
                book_id = 7,
                percentage = 72.75,
                position_data = "device-cfi",
            },
        })
        write_settings("grimmory_sync_state.lua", {
            state = {
                username = "alice",
                server_url = server,
                book_id = 7,
                annotations_dirty = true,
                sessions = {},
                -- The durable state can lag the queue; the queued sample is
                -- the current device truth while these remain server truth.
                device_percentage = 70,
                device_position = "older-device-cfi",
                server_percentage = 61.5,
                server_position = "server-cfi",
            },
        })

        assert.same({{
            key = "alice\n" .. server .. "\n7",
            book_id = 7,
            server_url = server,
            username = "alice",
            title = "Book 7",
            active = true,
            features = { progress = true, annotations = true },
            device_percentage = 72.75,
            device_position = "device-cfi",
            server_percentage = 61.5,
            server_position = "server-cfi",
        }}, SyncStatus.pendingBooks())
    end)

    it("keeps accounts isolated and orders the active account first", function()
        local active_server = "http://active:6060"
        local other_server = "http://other:6060"
        set_active("alice", active_server)
        write_settings("grimmory_sync_queue.lua", {
            bob_same_book = {
                username = "bob",
                server_url = active_server,
                book_id = 9,
                title = "Aardvark (Bob)",
                percentage = 20,
            },
            alice_same_book = {
                username = "alice",
                server_url = active_server,
                book_id = 9,
                title = "Zebra (Alice)",
                percentage = 40,
            },
            alice_other_server = {
                username = "alice",
                server_url = other_server,
                book_id = 9,
                title = "Another server",
                percentage = 60,
            },
        })
        write_settings("grimmory_sync_state.lua", {})

        assert.are.same({
            {
                key = "alice\n" .. active_server .. "\n9", book_id = 9,
                server_url = active_server, username = "alice",
                title = "Zebra (Alice)", active = true,
                features = { progress = true }, device_percentage = 40,
            },
            {
                key = "bob\n" .. active_server .. "\n9", book_id = 9,
                server_url = active_server, username = "bob",
                title = "Aardvark (Bob)", active = false,
                features = { progress = true }, device_percentage = 20,
            },
            {
                key = "alice\n" .. other_server .. "\n9", book_id = 9,
                server_url = other_server, username = "alice",
                title = "Another server", active = false,
                features = { progress = true }, device_percentage = 60,
            },
        }, SyncStatus.pendingBooks())
    end)

    it("lists annotation- or session-only books without a progress entry", function()
        local server = "http://srv:6060"
        set_active("alice", server)
        write_settings("grimmory_sync_queue.lua", {})
        write_settings("grimmory_sync_state.lua", {
            annotations = {
                username = "alice",
                server_url = server,
                book_id = 1,
                title = "Annotations only",
                annotations_dirty = true,
                sessions = {},
                device_percentage = 11,
                server_percentage = 10,
            },
            sessions = {
                username = "alice",
                server_url = server,
                book_id = 2,
                title = "Sessions only",
                annotations_dirty = false,
                sessions = { { id = "pending" } },
                device_percentage = 22,
                server_percentage = 21,
            },
            clean = {
                username = "alice",
                server_url = server,
                book_id = 3,
                title = "Already clean",
                annotations_dirty = false,
                sessions = {},
            },
        })

        assert.are.same({
            {
                key = "alice\n" .. server .. "\n1", book_id = 1,
                server_url = server, username = "alice",
                title = "Annotations only", active = true,
                features = { annotations = true },
                device_percentage = 11, server_percentage = 10,
            },
            {
                key = "alice\n" .. server .. "\n2", book_id = 2,
                server_url = server, username = "alice",
                title = "Sessions only", active = true,
                features = { sessions = true },
                device_percentage = 22, server_percentage = 21,
            },
        }, SyncStatus.pendingBooks())
    end)

    it("selects newest queued format and its matching server state deterministically", function()
        local server = "http://multi-format:6060"
        set_active("alice", server)
        write_settings("grimmory_downloads.lua", {
            [server .. "|42"] = {
                server_id = 42, server_url = server,
                path = "/books/book.epub", title = "The Book",
                file_id = 501, book_type = "EPUB", is_primary = true,
            },
            [server .. "|42|file:601"] = {
                server_id = 42, server_url = server,
                path = "/books/book.pdf", title = "The Book",
                file_id = 601, book_type = "PDF", is_primary = false,
            },
        })
        write_settings("grimmory_sync_queue.lua", {
            stale_epub = {
                username = "alice", server_url = server, book_id = 42,
                file_id = 501, file_type = "EPUB", percentage = 10,
                position_data = "epubcfi(/6/2)", enqueued_at = 100,
            },
            stale_duplicate_pdf = {
                username = "alice", server_url = server, book_id = 42,
                file_id = 601, file_type = "PDF", percentage = 60,
                position_data = "12", enqueued_at = 150,
            },
            newest_pdf = {
                username = "alice", server_url = server, book_id = 42,
                file_id = 601, file_type = "PDF", percentage = 70,
                position_data = "17", enqueued_at = 200,
            },
        })
        write_settings("grimmory_sync_state.lua", {
            newer_but_wrong_format = {
                username = "alice", server_url = server, book_id = 42,
                file_id = 501, file_type = "EPUB",
                server_percentage = 90, server_position = "epubcfi(/6/20)",
                server_observed_at = 300,
            },
            matching_pdf = {
                username = "alice", server_url = server, book_id = 42,
                file_id = 601, file_type = "PDF",
                server_percentage = 65, server_position = "16",
                server_observed_at = 120,
            },
        })

        assert.same({{
            key = "alice\n" .. server .. "\n42",
            book_id = 42, server_url = server, username = "alice",
            title = "The Book", path = "/books/book.pdf", file_type = "PDF",
            active = true, features = { progress = true },
            device_percentage = 70, device_position = "17",
            server_percentage = 65, server_position = "16",
        }}, SyncStatus.pendingBooks())
    end)

    it("uses stable queue-key order when captures share one timestamp", function()
        local server = "http://tie:6060"
        set_active("alice", server)
        write_settings("grimmory_downloads.lua", {})
        write_settings("grimmory_sync_state.lua", {})
        write_settings("grimmory_sync_queue.lua", {
            a_earlier_key = {
                username = "alice", server_url = server, book_id = 7,
                file_type = "EPUB", percentage = 10,
                position_data = "first", enqueued_at = 500,
            },
            z_later_key = {
                username = "alice", server_url = server, book_id = 7,
                file_type = "PDF", percentage = 80,
                position_data = "last", enqueued_at = 500,
            },
        })

        assert.same({{
            key = "alice\n" .. server .. "\n7",
            book_id = 7, server_url = server, username = "alice",
            title = "Book 7", file_type = "PDF", active = true,
            features = { progress = true },
            device_percentage = 80, device_position = "last",
        }}, SyncStatus.pendingBooks())
    end)
end)
