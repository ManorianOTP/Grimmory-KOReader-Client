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
        local books = { { id = 1, fileName = "a.epub" }, { id = 2, fileName = "b.epub" } }
        local shelves = { { id = 10, name = "Fav" } }
        local libraries = { { id = 5, name = "Lib" } }
        LibraryCache.save("alice", "http://srv", books, shelves, libraries)

        local snap = LibraryCache.load("alice", "http://srv")
        assert.not_nil(snap)
        assert.equals("alice", snap.username)
        assert.equals("http://srv", snap.server_url)
        assert.equals(2, #snap.books)
        assert.equals(1, snap.books[1].id)
        assert.equals(1, #snap.shelves)
        assert.equals("number", type(snap.fetched_at))
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

        local alice_snap = LibraryCache.load("alice", "http://srv")
        local bob_snap = LibraryCache.load("bob", "http://srv")
        assert.not_nil(alice_snap, "alice's snapshot must survive bob's save")
        assert.equals(1, alice_snap.books[1].id)
        assert.not_nil(bob_snap)
        assert.equals(2, bob_snap.books[1].id)
    end)

    it("distinguishes same username on different servers", function()
        LibraryCache.save("alice", "http://srv", { { id = 1 } }, {}, {})
        LibraryCache.save("alice", "http://other", { { id = 9 } }, {}, {})
        assert.equals(1, LibraryCache.load("alice", "http://srv").books[1].id)
        assert.equals(9, LibraryCache.load("alice", "http://other").books[1].id)
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
