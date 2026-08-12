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
            d:register(SERVER, { id = 9 }, path, {
                id = 901,
                fileName = "x.epub",
                bookType = "EPUB",
                isPrimary = true,
            })
            local entry = d.registry:readSetting(SERVER .. "|9")
            assert.are.same(
                {
                    path = path,
                    server_id = 9,
                    server_url = SERVER,
                    file_id = 901,
                    file_name = "x.epub",
                    book_type = "EPUB",
                    is_primary = true,
                },
                entry)
        end)

        it("stores alternative formats under exact file IDs", function()
            local d = make_downloads()
            local path = d.download_dir .. "/x.pdf"
            touch(path)
            local file = {
                id = 902,
                fileName = "x.pdf",
                bookType = "PDF",
                isPrimary = false,
            }
            d:register(SERVER, { id = 9 }, path, file)
            local entry = d.registry:readSetting(SERVER .. "|9|file:902")
            assert.are.same({
                path = path,
                server_id = 9,
                server_url = SERVER,
                file_id = 902,
                file_name = "x.pdf",
                book_type = "PDF",
                is_primary = false,
            }, entry)
            assert.are.equal(path, d:localPath(SERVER, { id = 9 }, file))
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
            local same_server_path = d.download_dir .. "/survivor.epub"
            local other_server_path = d.download_dir .. "/other.epub"
            touch(path)
            touch(same_server_path)
            touch(other_server_path)
            d:register(SERVER, { id = 7 }, path)
            d:register(SERVER, { id = 8 }, same_server_path)
            d:register("http://other:6060", { id = 7 }, other_server_path)
            os.remove(path)
            assert.is_nil(d:localPath(SERVER, { id = 7 }))
            -- pruned from disk, not just nil-ed for this call
            assert.is_nil(d.registry:readSetting(SERVER .. "|7"))
            assert.same({
                path = same_server_path, server_id = 8, server_url = SERVER,
                is_primary = true,
            }, d.registry:readSetting(SERVER .. "|8"))
            assert.same({
                path = other_server_path, server_id = 7,
                server_url = "http://other:6060", is_primary = true,
            }, d.registry:readSetting("http://other:6060|7"))
        end)
    end)

    describe("localFilesByBook", function()
        it("groups every downloaded format by book on the selected server", function()
            local d = make_downloads()
            local epub = d.download_dir .. "/x.epub"
            local pdf = d.download_dir .. "/x.pdf"
            local other = d.download_dir .. "/other.epub"
            touch(epub); touch(pdf); touch(other)
            d:register(SERVER, { id = 9, title = "X" }, epub, {
                id = 901, fileName = "x.epub", bookType = "EPUB", isPrimary = true,
            })
            d:register(SERVER, { id = 9, title = "X" }, pdf, {
                id = 902, fileName = "x.pdf", bookType = "PDF", isPrimary = false,
            })
            d:register("http://other:6060", { id = 9 }, other)

            local grouped = d:localFilesByBook(SERVER)
            table.sort(grouped["9"])
            assert.are.same({ ["9"] = { epub, pdf } }, grouped)
        end)

        it("ignores missing files and duplicate registry paths", function()
            local d = make_downloads()
            local path = d.download_dir .. "/x.epub"
            touch(path)
            d.registry:saveSetting("one", {
                server_id = 7, server_url = SERVER, path = path,
            })
            d.registry:saveSetting("duplicate", {
                server_id = 7, server_url = SERVER, path = path,
            })
            d.registry:saveSetting("missing", {
                server_id = 7, server_url = SERVER,
                path = d.download_dir .. "/missing.epub",
            })
            d.registry:flush()

            assert.are.same({ ["7"] = { path } }, d:localFilesByBook(SERVER))
        end)
    end)
end)
