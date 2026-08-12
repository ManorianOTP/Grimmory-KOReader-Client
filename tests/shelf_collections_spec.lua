--[[
  Shelf-to-collection reconciliation specs.

  These use an injected ReadCollection double so the safety boundary is
  exercised off-device: Grimmory may manage only its own scoped collections
  and the paths it added to them. It must not adopt, empty, or delete user
  collections.
]]
local spec_helper = require("spec_helper")

local SERVER = "http://srv:6060"
local OTHER_SERVER = "http://other:6060"
local USER = "alice"
local EPUB = "/books/seven.epub"
local PDF = "/books/seven.pdf"
local MANUAL = "/books/manual.epub"

describe("ShelfCollections", function()
    local ShelfCollections

    before_each(function()
        spec_helper.setup()
        ShelfCollections = require("shelf_collections")
    end)

    after_each(function()
        spec_helper.teardown()
    end)

    local function make_read_collection()
        local rc = {
            coll = {},
            coll_settings = {},
            reads = 0,
            writes = 0,
            additions = {},
            removals = {},
        }

        function rc:_read()
            self.reads = self.reads + 1
        end

        function rc:addCollection(name)
            local max_order = 0
            for _, settings in pairs(self.coll_settings) do
                max_order = math.max(max_order, settings.order or 0)
            end
            self.coll[name] = {}
            self.coll_settings[name] = { order = max_order + 1 }
        end

        function rc:renameCollection(old_name, new_name)
            self.coll[new_name] = self.coll[old_name]
            self.coll_settings[new_name] = self.coll_settings[old_name]
            self.coll[old_name] = nil
            self.coll_settings[old_name] = nil
        end

        function rc:addItem(path, name)
            self.coll[name][path] = { file = path }
            self.additions[#self.additions + 1] = { path = path, name = name }
        end

        function rc:removeItem(path, name, no_write)
            assert.is_true(no_write, "reconcile must batch collection writes")
            if self.coll[name] and self.coll[name][path] then
                self.coll[name][path] = nil
                self.removals[#self.removals + 1] = { path = path, name = name }
                return true
            end
        end

        function rc:write()
            self.writes = self.writes + 1
        end

        return rc
    end

    local function add_manual_collection(rc, name, paths, settings)
        rc.coll[name] = {}
        for _, path in ipairs(paths or {}) do
            rc.coll[name][path] = { file = path }
        end
        rc.coll_settings[name] = settings or { order = 1 }
    end

    local function copy(value)
        if type(value) ~= "table" then return value end
        local out = {}
        for key, child in pairs(value) do out[copy(key)] = copy(child) end
        return out
    end

    local function collection_state(rc)
        return copy({ coll = rc.coll, coll_settings = rc.coll_settings })
    end

    local function make_sync(rc, existing_paths)
        existing_paths = existing_paths or {
            [EPUB] = true,
            [PDF] = true,
            [MANUAL] = true,
        }
        return ShelfCollections.new{
            read_collection = rc,
            realpath = function(path)
                return existing_paths[path] and path or nil
            end,
        }
    end

    local function reconcile(sync, opts)
        opts = opts or {}
        return sync:reconcile(
            opts.server_url or SERVER,
            opts.username or USER,
            opts.shelves or { { id = 10, name = "To Read" } },
            opts.books or { { id = 7, shelves = { { id = 10 } } } },
            opts.files or { ["7"] = { EPUB } }
        )
    end

    local function find_owned(rc, server_url, username, shelf_id)
        for name, settings in pairs(rc.coll_settings) do
            local meta = settings.grimmory_shelf
            if meta and meta.server_url == server_url
                    and meta.username == username
                    and tostring(meta.shelf_id) == tostring(shelf_id) then
                return name, meta
            end
        end
    end

    it("creates a namespaced collection with scoped ownership metadata", function()
        local rc = make_read_collection()
        local result, err = reconcile(make_sync(rc))

        assert.is_nil(err)
        assert.same({ created = 1, added = 1, removed = 0, changed = true }, result)
        assert.are.equal(1, rc.writes)

        local name, meta = find_owned(rc, SERVER, USER, 10)
        assert.is_not_nil(name)
        assert.is_truthy(name:match("^Grimmory"))
        assert.is_not_nil(rc.coll[name][EPUB])
        assert.is_true(meta.managed_paths[EPUB])
        assert.is_false(meta.remote_missing)
    end)

    it("does not adopt or modify a colliding user collection", function()
        local rc = make_read_collection()
        local user_name = "Grimmory — To Read"
        add_manual_collection(rc, user_name, { MANUAL })

        local result, err = reconcile(make_sync(rc))

        assert.is_nil(err)
        assert.same({ created = 1, added = 1, removed = 0, changed = true }, result)
        assert.is_not_nil(rc.coll[user_name][MANUAL])
        assert.is_nil(rc.coll_settings[user_name].grimmory_shelf)

        local managed_name = find_owned(rc, SERVER, USER, 10)
        assert.is_not_nil(managed_name)
        assert.are_not.equal(user_name, managed_name)
        assert.is_not_nil(rc.coll[managed_name][EPUB])
    end)

    it("scopes the same shelf id and name to each account", function()
        local rc = make_read_collection()
        local sync = make_sync(rc)
        assert.is_table(reconcile(sync))

        local result, err = reconcile(sync, {
            server_url = OTHER_SERVER,
            username = "bob",
            files = { ["7"] = { PDF } },
        })

        assert.is_nil(err)
        assert.same({ created = 1, added = 1, removed = 0, changed = true }, result)
        local alice_name = find_owned(rc, SERVER, USER, 10)
        local bob_name = find_owned(rc, OTHER_SERVER, "bob", 10)
        assert.is_not_nil(alice_name)
        assert.is_not_nil(bob_name)
        assert.are_not.equal(alice_name, bob_name)
        assert.is_not_nil(rc.coll[alice_name][EPUB])
        assert.is_nil(rc.coll[alice_name][PDF])
        assert.is_not_nil(rc.coll[bob_name][PDF])
    end)

    it("removes only paths it managed and preserves manual and unrelated items", function()
        local rc = make_read_collection()
        local sync = make_sync(rc)
        assert.is_table(reconcile(sync))
        local name, meta = find_owned(rc, SERVER, USER, 10)

        -- A user adds MANUAL to the managed collection, and another unrelated
        -- collection also contains EPUB. Neither belongs to our managed set.
        rc.coll[name][MANUAL] = { file = MANUAL }
        add_manual_collection(rc, "Personal", { EPUB })

        local result, err = reconcile(sync, {
            books = { { id = 7, shelves = {} } },
        })

        assert.is_nil(err)
        assert.same({ created = 0, added = 0, removed = 1, changed = true }, result)
        assert.is_nil(rc.coll[name][EPUB])
        assert.is_nil(meta.managed_paths[EPUB])
        assert.is_not_nil(rc.coll[name][MANUAL])
        assert.is_not_nil(rc.coll.Personal[EPUB])
        assert.are.equal(1, #rc.removals)
        assert.are.equal(name, rc.removals[1].name)
    end)

    it("freezes a collection when its remote shelf disappears", function()
        local rc = make_read_collection()
        local sync = make_sync(rc)
        assert.is_table(reconcile(sync))
        local name, meta = find_owned(rc, SERVER, USER, 10)

        local result, err = reconcile(sync, {
            shelves = {}, books = {}, files = {},
        })

        assert.is_nil(err)
        assert.same({ created = 0, added = 0, removed = 0, changed = true }, result)
        assert.is_true(meta.remote_missing)
        assert.is_not_nil(rc.coll[name][EPUB])
        assert.is_true(meta.managed_paths[EPUB])
        assert.are.equal(2, rc.writes)

        -- Repeating the same missing-shelf snapshot is a no-op.
        local again = assert(reconcile(sync, {
            shelves = {}, books = {}, files = {},
        }))
        assert.is_false(again.changed)
        assert.are.equal(2, rc.writes)
    end)

    it("is idempotent for an unchanged server snapshot", function()
        local rc = make_read_collection()
        local sync = make_sync(rc)
        local first = assert(reconcile(sync))
        local second = assert(reconcile(sync))

        assert.is_true(first.changed)
        assert.is_false(second.changed)
        assert.are.equal(1, rc.writes)
        assert.are.equal(1, #rc.additions)
        assert.are.equal(0, #rc.removals)
    end)

    it("adds and tracks every locally downloaded format exactly once", function()
        local rc = make_read_collection()
        local result, err = reconcile(make_sync(rc), {
            files = { ["7"] = { EPUB, PDF, EPUB } },
        })

        assert.is_nil(err)
        assert.same({ created = 1, added = 2, removed = 0, changed = true }, result)
        assert.are.equal(2, #rc.additions)
        local name, meta = find_owned(rc, SERVER, USER, 10)
        assert.is_not_nil(rc.coll[name][EPUB])
        assert.is_not_nil(rc.coll[name][PDF])
        assert.is_true(meta.managed_paths[EPUB])
        assert.is_true(meta.managed_paths[PDF])
    end)

    it("rolls back the complete collection state when adding a path fails", function()
        local rc = make_read_collection()
        add_manual_collection(rc, "Personal", { MANUAL }, { order = 4 })
        local before = collection_state(rc)
        rc.addItem = function(self, path, name)
            self.coll[name][path] = { file = path }
            error("injected add failure")
        end

        local result, err = reconcile(make_sync(rc))

        assert.is_nil(result)
        assert.matches("injected add failure", err)
        assert.same(before, collection_state(rc))
        assert.equals(0, rc.writes)
    end)

    it("rolls back bookkeeping and membership when removing a path fails", function()
        local rc = make_read_collection()
        local sync = make_sync(rc)
        assert.is_table(reconcile(sync))
        local before = collection_state(rc)
        rc.removeItem = function(self, path, name)
            self.coll[name][path] = nil
            error("injected remove failure")
        end

        local result, err = reconcile(sync, {
            books = { { id = 7, shelves = {} } },
        })

        assert.is_nil(result)
        assert.matches("injected remove failure", err)
        assert.same(before, collection_state(rc))
        assert.equals(1, rc.writes)
    end)

    it("rolls back a partially applied collection rename", function()
        local rc = make_read_collection()
        local sync = make_sync(rc)
        assert.is_table(reconcile(sync))
        local before = collection_state(rc)
        rc.renameCollection = function(self, old_name, new_name)
            self.coll[new_name] = self.coll[old_name]
            self.coll[old_name] = nil
            error("injected rename failure")
        end

        local result, err = reconcile(sync, {
            shelves = { { id = 10, name = "Renamed" } },
        })

        assert.is_nil(result)
        assert.matches("injected rename failure", err)
        assert.same(before, collection_state(rc))
        assert.equals(1, rc.writes)
    end)

    it("treats explicit false adapter results as failures with no state drift", function()
        local rc = make_read_collection()
        local before = collection_state(rc)
        rc.addCollection = function() return false end

        local result, err = reconcile(make_sync(rc))

        assert.is_nil(result)
        assert.equals("addCollection returned false", err)
        assert.same(before, collection_state(rc))
        assert.equals(0, rc.writes)
    end)
end)
