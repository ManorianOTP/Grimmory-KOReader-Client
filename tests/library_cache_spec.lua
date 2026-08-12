--[[
  Offline library snapshot persistence spec for
  grimmory.koplugin/library_cache.lua.

  Verifies the snapshot round-trips on disk and that load() enforces the
  account match (username + server_url) so one account never sees another's
  cached library. The full UI render path (browseLibrary / showDashboard)
  needs the KOReader widget runtime and is covered by on-device verification;
  this spec exercises the only piece that can silently fail in production.
]]
local spec_helper = require("spec_helper")
local fake_settings = require("fake_settings_dir")

describe("LibraryCache snapshot persistence", function()
    local LibraryCache
    local dir_handle

    before_each(function()
        spec_helper.setup()
        dir_handle = fake_settings.create({ server_url = "http://srv", token = "t" })
        require("datastorage")._set_dir(dir_handle.dir)
        LibraryCache = require("library_cache")
    end)

    after_each(function()
        dir_handle.cleanup()
        spec_helper.teardown()
    end)

    it("round-trips a snapshot for the same account", function()
        local books = {
            {
                id = 2,
                fileName = "b.epub",
                readStatus = "READING",
                metadata = {
                    title = "Second",
                    authors = { "Beta", "Coauthor" },
                    categories = { "Fiction", "Case Study" },
                    seriesName = "Cycle",
                    seriesNumber = 2,
                    allMetadataLocked = false,
                },
                primaryFile = { id = 202, extension = "epub", isPrimary = true },
            },
            {
                id = 1,
                fileName = "a.pdf",
                readStatus = "UNREAD",
                metadata = {
                    title = "First",
                    authors = {},
                    categories = {},
                    pageCount = 0,
                },
                primaryFile = { id = 101, extension = "pdf", isPrimary = true },
            },
        }
        local shelves = {
            { id = 11, name = "Later", bookIds = { 2, 1 } },
            { id = 10, name = "Earlier", bookIds = {} },
        }
        local libraries = {
            { id = 6, name = "Secondary", bookCount = 1 },
            { id = 5, name = "Primary", bookCount = 2 },
        }
        local expected_books = {
            {
                id = 2, fileName = "b.epub", readStatus = "READING",
                metadata = {
                    title = "Second", authors = { "Beta", "Coauthor" },
                    categories = { "Fiction", "Case Study" },
                    seriesName = "Cycle", seriesNumber = 2,
                    allMetadataLocked = false,
                },
                primaryFile = { id = 202, extension = "epub", isPrimary = true },
            },
            {
                id = 1, fileName = "a.pdf", readStatus = "UNREAD",
                metadata = {
                    title = "First", authors = {}, categories = {}, pageCount = 0,
                },
                primaryFile = { id = 101, extension = "pdf", isPrimary = true },
            },
        }
        local expected_shelves = {
            { id = 11, name = "Later", bookIds = { 2, 1 } },
            { id = 10, name = "Earlier", bookIds = {} },
        }
        local expected_libraries = {
            { id = 6, name = "Secondary", bookCount = 1 },
            { id = 5, name = "Primary", bookCount = 2 },
        }
        LibraryCache.save("alice", "http://srv", books, shelves, libraries)

        -- Mutating every caller-owned collection after save proves the later
        -- result is reconstructed from serialized disk bytes, not shared
        -- in-memory tables.
        books[1].metadata.title = "MUTATED"
        books[2].primaryFile.id = -1
        books[#books + 1] = { id = 999 }
        shelves[1].bookIds[1] = 999
        libraries[1].name = "MUTATED"
        package.loaded.library_cache = nil
        LibraryCache = require("library_cache")
        local snap = LibraryCache.load("alice", "http://srv")
        assert.not_nil(snap)
        assert.equals("alice", snap.username)
        assert.equals("http://srv", snap.server_url)
        assert.same(expected_books, snap.books,
            "complete normalized book records and order must survive restart")
        assert.same(expected_shelves, snap.shelves,
            "complete shelf records and order must survive restart")
        assert.same(expected_libraries, snap.libraries,
            "complete library records and order must survive restart")
        assert.equals("number", type(snap.fetched_at))

        -- A consumer mutating its decoded snapshot cannot alter the file; a
        -- second fresh module/decoder must recover the original record graph.
        snap.books[1].metadata.authors[1] = "MUTATED AGAIN"
        snap.shelves = {}
        package.loaded.library_cache = nil
        local reloaded = require("library_cache").load("alice", "http://srv")
        assert.same(expected_books, reloaded.books)
        assert.same(expected_shelves, reloaded.shelves)
        assert.same(expected_libraries, reloaded.libraries)
    end)

    it("returns nil for a different account (username or server mismatch)", function()
        LibraryCache.save("alice", "http://srv", { { id = 1 } }, {}, {})
        assert.is_nil(LibraryCache.load("bob", "http://srv"),
            "must not return alice's library to bob")
        assert.is_nil(LibraryCache.load("alice", "http://other"),
            "must not return a snapshot fetched from a different server")
    end)

    it("returns nil when no snapshot has been written", function()
        assert.is_nil(LibraryCache.load("alice", "http://srv"))
    end)

    it("returns nil instead of crashing on a corrupt snapshot file", function()
        -- A battery pull mid-save leaves truncated JSON on disk; the next
        -- load must degrade to "no cache", never error into the UI path.
        LibraryCache.save("alice", "http://srv", { { id = 1 } }, {}, {})
        local f = assert(io.open(LibraryCache.path("alice", "http://srv"), "w"))
        f:write('{"username":"alice","server_url":"http://srv","books":[{"id"')
        f:close()
        assert.is_nil(LibraryCache.load("alice", "http://srv"))
    end)

    it("returns nil when the snapshot decodes to the wrong shape", function()
        local f = assert(io.open(LibraryCache.path("alice", "http://srv"), "w"))
        f:write('{"username":"alice","server_url":"http://srv","books":"oops"}')
        f:close()
        assert.is_nil(LibraryCache.load("alice", "http://srv"))
    end)

    it("save returns false when the payload cannot be JSON-encoded", function()
        local unencodable = { { id = 1, blob = function() end } }
        assert.is_false(LibraryCache.save("alice", "http://srv", unencodable, {}, {}))
        assert.is_nil(LibraryCache.load("alice", "http://srv"),
            "a failed save must not leave a snapshot behind")
    end)

    it("keeps each account's snapshot when another account saves", function()
        -- The multi-user guarantee: B's fetch must not destroy A's offline
        -- library (the old single-file design failed exactly this).
        LibraryCache.save("alice", "http://srv", { { id = 1 } }, {}, {})
        LibraryCache.save("bob", "http://srv", { { id = 2 } }, {}, {})

        package.loaded.library_cache = nil
        local reloaded_cache = require("library_cache")
        local alice_snap = reloaded_cache.load("alice", "http://srv")
        local bob_snap = reloaded_cache.load("bob", "http://srv")
        assert.not_nil(alice_snap, "alice's snapshot must survive bob's save")
        assert.same({ { id = 1 } }, alice_snap.books)
        assert.not_nil(bob_snap)
        assert.same({ { id = 2 } }, bob_snap.books)
    end)

    it("distinguishes same username on different servers", function()
        LibraryCache.save("alice", "http://srv", { { id = 1 } }, {}, {})
        LibraryCache.save("alice", "http://other", { { id = 9 } }, {}, {})
        package.loaded.library_cache = nil
        local reloaded = require("library_cache")
        assert.same({ { id = 1 } }, reloaded.load("alice", "http://srv").books)
        assert.same({ { id = 9 } }, reloaded.load("alice", "http://other").books)
    end)

    it("falls back to the pre-per-account shared file, for its owner only", function()
        -- Upgrade path: a device that cached under the old single-file scheme
        -- keeps its offline library until the first fresh fetch replaces it.
        local f = assert(io.open(LibraryCache.legacy_path(), "w"))
        f:write('{"username":"alice","server_url":"http://srv","fetched_at":1,'
            .. '"books":[{"id":3}],"shelves":[],"libraries":[]}')
        f:close()

        local snap = LibraryCache.load("alice", "http://srv")
        assert.not_nil(snap, "owner must still see the legacy snapshot")
        assert.equals(3, snap.books[1].id)
        assert.is_nil(LibraryCache.load("bob", "http://srv"),
            "the legacy file must stay account-checked")
    end)

    it("save removes the superseded shared legacy file", function()
        local f = assert(io.open(LibraryCache.legacy_path(), "w"))
        f:write('{"username":"alice","server_url":"http://srv","books":[]}')
        f:close()

        LibraryCache.save("alice", "http://srv", { { id = 1 } }, {}, {})
        assert.is_nil(io.open(LibraryCache.legacy_path(), "r"),
            "legacy shared file should be deleted on the first per-account save")
    end)
end)
