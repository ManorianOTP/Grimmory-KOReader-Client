--[[
  Download registry spec for grimmory.koplugin/downloads.lua.

  The registry file is the only runtime contract between the two plugins:
  grimmory_sync's lookupBookId reads it to map an open file path back to a
  Grimmory book_id. These specs pin the key format and entry shape, the
  per-server scoping, and the stale-entry pruning that keeps the detail
  page's Download button honest after a file is deleted on device.
]]
local spec_helper = require("spec_helper")

local SERVER = "http://srv:6060"

describe("Downloads", function()
    local Downloads, DataStorage

    before_each(function()
        spec_helper.setup()
        Downloads = require("downloads")
        DataStorage = require("datastorage")
    end)

    after_each(function()
        spec_helper.teardown()
    end)

    local function make_downloads()
        local dl_dir = DataStorage:getSettingsDir() .. "/dl"
        os.execute("mkdir -p '" .. dl_dir .. "'")
        return Downloads.new{ download_dir = dl_dir }
    end

    local function touch(path)
        local f = assert(io.open(path, "w"))
        f:write("epub-bytes")
        f:close()
    end

    describe("destPath", function()
        it("joins the sanitized server filename onto download_dir", function()
            local d = make_downloads()
            assert.are.equal(d.download_dir .. "/A Book.epub",
                d:destPath({ id = 7, fileName = "A Book.epub" }))
        end)

        it("strips path separators so a hostile filename cannot escape the dir", function()
            local d = make_downloads()
            local path = d:destPath({ id = 7, fileName = "../../etc/passwd" })
            assert.are.equal(d.download_dir .. "/.._.._etc_passwd", path)
        end)

        it("falls back to the book id when the server omits fileName", function()
            local d = make_downloads()
            assert.are.equal(d.download_dir .. "/book_7", d:destPath({ id = 7 }))
        end)
    end)

    describe("registry round-trip", function()
        it("register + localPath resolve through the on-disk registry", function()
            local d = make_downloads()
            local path = d.download_dir .. "/x.epub"
            touch(path)
            d:register(SERVER, { id = 7 }, path)
            -- A fresh instance reads the same on-disk file: survives restart.
            local d2 = Downloads.new{ download_dir = d.download_dir }
            assert.are.equal(path, d2:localPath(SERVER, { id = 7 }))
        end)

        it("writes the key format and entry shape grimmory_sync reads", function()
            local d = make_downloads()
            local path = d.download_dir .. "/x.epub"
            touch(path)
            d:register(SERVER, { id = 9 }, path)
            local entry = d.registry:readSetting(SERVER .. "|9")
            assert.are.same(
                { path = path, server_id = 9, server_url = SERVER },
                entry)
        end)

        it("scopes entries by server so two Grimmory instances cannot collide", function()
            local d = make_downloads()
            local path = d.download_dir .. "/x.epub"
            touch(path)
            d:register(SERVER, { id = 7 }, path)
            assert.is_nil(d:localPath("http://other:6060", { id = 7 }))
        end)

        it("returns nil for a book that was never downloaded", function()
            local d = make_downloads()
            assert.is_nil(d:localPath(SERVER, { id = 42 }))
            assert.is_nil(d:localPath(SERVER, {}))
        end)
    end)

    describe("stale-entry pruning", function()
        it("drops the registry entry when the file was deleted on device", function()
            local d = make_downloads()
            local path = d.download_dir .. "/x.epub"
            touch(path)
            d:register(SERVER, { id = 7 }, path)
            os.remove(path)
            assert.is_nil(d:localPath(SERVER, { id = 7 }))
            -- pruned from disk, not just nil-ed for this call
            assert.is_nil(d.registry:readSetting(SERVER .. "|7"))
        end)
    end)
end)
