--[[
  Self-updater spec for booklore.koplugin/updater.lua.

  The download/extract/swap pipeline runs for real: each test builds genuine
  plugin .tar.gz artifacts with the system tar, serves them (and the manifest)
  from the local Python HTTP fixture, downloads over real LuaSocket HTTP, and
  lets the module's default shell exec run the real tar/mv/rm against a per-test
  tmp plugins root. Swap ordering and reconcile/uninstall edge cases use a
  scripted fake exec where the final on-disk state can't reveal ordering.
]]
local spec_helper = require("spec_helper")

local function write_file(path, content)
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
end

-- Records every command; responder may override output/exit code.
local function recording_exec(responder)
    local calls = {}
    local exec = function(cmd)
        table.insert(calls, cmd)
        if responder then return responder(cmd) end
        return "", 0
    end
    return exec, calls
end

local function first_index(calls, pattern)
    for i = 1, #calls do
        if calls[i]:match(pattern) then return i end
    end
    return nil
end

describe("Updater", function()
    local Updater
    local http_handle

    before_each(function()
        spec_helper.setup()
        Updater = require("updater")
    end)

    after_each(function()
        spec_helper.teardown({ http_handle = http_handle })
        http_handle = nil
    end)

    describe("compareVersions", function()
        it("orders dotted-numeric versions", function()
            assert.are.equal(1, Updater.compareVersions("1.1.0", "1.0.9"))
            assert.are.equal(-1, Updater.compareVersions("1.2.0", "1.10.0"))
            assert.are.equal(0, Updater.compareVersions("1.2", "1.2.0"))
            assert.are.equal(1, Updater.compareVersions("2.0.0", "1.9.9"))
            assert.are.equal(0, Updater.compareVersions("1.0.0", "1.0.0"))
        end)
    end)

    describe("parseMetaVersion", function()
        it("extracts a double- or single-quoted version field", function()
            assert.are.equal("1.4.0", Updater.parseMetaVersion('return { version = "1.4.0" }'))
            assert.are.equal("2.0.1", Updater.parseMetaVersion("version = '2.0.1'"))
            assert.is_nil(Updater.parseMetaVersion("return { name = 'x' }"))
            assert.is_nil(Updater.parseMetaVersion(nil))
        end)
    end)

    describe("construction", function()
        it("derives staging_dir as a sibling of plugins_root by default", function()
            local up = Updater.new{ plugins_root = "/x/plugins" }
            assert.are.equal("/x/plugins/.booklore_update", up.staging_dir)
        end)
        it("honors an explicit staging_dir override", function()
            local up = Updater.new{ plugins_root = "/x/plugins", staging_dir = "/tmp/stage" }
            assert.are.equal("/tmp/stage", up.staging_dir)
        end)
    end)

    describe("parseManifest", function()
        it("accepts a well-formed manifest", function()
            local m, err = Updater.parseManifest(
                '{"version":"1.1.0","plugins":[{"dir":"booklore.koplugin","url":"http://x"}]}')
            assert.is_nil(err)
            assert.are.equal("1.1.0", m.version)
            assert.are.equal("booklore.koplugin", m.plugins[1].dir)
        end)
        it("rejects malformed JSON and missing fields", function()
            assert.is_nil((Updater.parseManifest("not json")))
            assert.is_nil((Updater.parseManifest('{"plugins":[]}')))
            assert.is_nil((Updater.parseManifest('{"version":"1.0.0"}')))
            assert.is_nil((Updater.parseManifest('{"version":"1.0.0","plugins":[{"dir":"x"}]}')))
        end)
    end)

    -- ── Fixtures for the real-shell pipeline ──
    local function build_plugin_tgz(version, dir)
        local pkg = spec_helper._tmp_dir .. "/pkg_" .. dir
        os.execute("mkdir -p '" .. pkg .. "/" .. dir .. "'")
        write_file(pkg .. "/" .. dir .. "/_meta.lua",
            'return { name = "x", version = "' .. version .. '" }\n')
        write_file(pkg .. "/" .. dir .. "/main.lua", "-- " .. dir .. " " .. version .. "\n")
        local tgz = pkg .. "/" .. dir .. ".tar.gz"
        assert.are.equal(0, os.execute(
            "cd '" .. pkg .. "' && tar czf '" .. tgz .. "' '" .. dir .. "'"))
        return tgz
    end

    local function install_plugins(root, version)
        local dirs = { "booklore.koplugin", "booklore_sync.koplugin" }
        for i = 1, #dirs do
            os.execute("mkdir -p '" .. root .. "/" .. dirs[i] .. "'")
            write_file(root .. "/" .. dirs[i] .. "/_meta.lua",
                'return { name = "x", version = "' .. version .. '" }\n')
            write_file(root .. "/" .. dirs[i] .. "/main.lua", "-- installed\n")
        end
    end

    local function make_updater(root, overrides)
        local opts = {
            request = require("socket.http").request,
            plugins_root = root,
            staging_dir = root .. "/.booklore_update",
            min_artifact_bytes = 16,
        }
        for k, v in pairs(overrides or {}) do opts[k] = v end
        return Updater.new(opts)
    end

    -- Serve both artifacts and return a manifest table pointing at them.
    local function serve_release(version, extra)
        local sync_tgz = build_plugin_tgz(version, "booklore_sync.koplugin")
        local bl_tgz = build_plugin_tgz(version, "booklore.koplugin")
        http_handle = spec_helper.start_http_fixture({
            { path = "/sync.tgz", body_file = sync_tgz },
            { path = "/bl.tgz", body_file = bl_tgz },
        })
        local sync = { dir = "booklore_sync.koplugin", url = http_handle.url("/sync.tgz") }
        local bl = { dir = "booklore.koplugin", url = http_handle.url("/bl.tgz") }
        for k, v in pairs(extra or {}) do
            if k == "sync" then for kk, vv in pairs(v) do sync[kk] = vv end end
            if k == "bl" then for kk, vv in pairs(v) do bl[kk] = vv end end
        end
        return { version = version, plugins = { sync, bl } }
    end

    describe("full pipeline (real shell + local HTTP)", function()
        it("downloads, verifies, extracts, and swaps both plugins", function()
            local root = spec_helper._tmp_dir .. "/plugins"
            install_plugins(root, "1.0.0")
            local manifest = serve_release("1.1.0")
            local up = make_updater(root)

            assert.are.equal("1.0.0", up:installedVersion())
            local ok, ver = up:performUpdate(manifest)
            assert.is_true(ok)
            assert.are.equal("1.1.0", ver)

            assert.are.equal("1.1.0", up:installedVersion())
            assert.are.equal("1.1.0", up:getInstalledVersion("booklore_sync.koplugin"))
            -- new content really landed (main.lua replaced)
            local main = assert(io.open(root .. "/booklore.koplugin/main.lua")):read("*a")
            assert.matches("1.1.0", main)
            -- staging + .new/.old all cleaned up
            assert.are_not.equal(0, os.execute("test -d '" .. root .. "/.booklore_update'"))
            assert.are_not.equal(0, os.execute("test -e '" .. root .. "/booklore.koplugin.new'"))
            assert.are_not.equal(0, os.execute("test -e '" .. root .. "/booklore.koplugin.old'"))
        end)

        it("verifies a matching checksum and rejects a mismatch", function()
            local root = spec_helper._tmp_dir .. "/plugins"
            install_plugins(root, "1.0.0")
            -- Inject a wrong sha256 for the booklore artifact.
            local manifest = serve_release("1.1.0", { bl = { sha256 = "deadbeef" } })
            local up = make_updater(root, {
                hash_file = function() return "cafef00d" end,  -- never matches
            })
            local ok, err = up:performUpdate(manifest)
            assert.is_nil(ok)
            assert.matches("checksum mismatch", err)
            -- nothing swapped; still on the old version, no .new left behind
            assert.are.equal("1.0.0", up:installedVersion())
            assert.are_not.equal(0, os.execute("test -e '" .. root .. "/booklore.koplugin.new'"))
        end)

        it("rejects an archive whose _meta version disagrees with the manifest", function()
            local root = spec_helper._tmp_dir .. "/plugins"
            install_plugins(root, "1.0.0")
            -- Manifest claims 1.1.0 but the artifacts are built as 9.9.9.
            local sync_tgz = build_plugin_tgz("9.9.9", "booklore_sync.koplugin")
            local bl_tgz = build_plugin_tgz("9.9.9", "booklore.koplugin")
            http_handle = spec_helper.start_http_fixture({
                { path = "/sync.tgz", body_file = sync_tgz },
                { path = "/bl.tgz", body_file = bl_tgz },
            })
            local manifest = { version = "1.1.0", plugins = {
                { dir = "booklore_sync.koplugin", url = http_handle.url("/sync.tgz") },
                { dir = "booklore.koplugin", url = http_handle.url("/bl.tgz") },
            } }
            local up = make_updater(root)
            local ok, err = up:performUpdate(manifest)
            assert.is_nil(ok)
            assert.matches("expected 1.1.0", err)
            assert.are.equal("1.0.0", up:installedVersion())
        end)

        it("fails and cleans up when an artifact 404s", function()
            local root = spec_helper._tmp_dir .. "/plugins"
            install_plugins(root, "1.0.0")
            http_handle = spec_helper.start_http_fixture({})  -- serves nothing
            local manifest = { version = "1.1.0", plugins = {
                { dir = "booklore_sync.koplugin", url = http_handle.url("/sync.tgz") },
                { dir = "booklore.koplugin", url = http_handle.url("/bl.tgz") },
            } }
            local up = make_updater(root)
            local ok, err = up:performUpdate(manifest)
            assert.is_nil(ok)
            assert.matches("download failed", err)
            assert.are.equal("1.0.0", up:installedVersion())
            assert.are_not.equal(0, os.execute("test -d '" .. root .. "/.booklore_update'"))
        end)
    end)

    describe("checkForUpdate", function()
        it("reports an available newer version", function()
            local root = spec_helper._tmp_dir .. "/plugins"
            install_plugins(root, "1.0.0")
            http_handle = spec_helper.start_http_fixture({
                { path = "/manifest.json",
                  body = '{"version":"1.2.0","plugins":[{"dir":"booklore.koplugin","url":"http://x"}]}' },
            })
            local up = make_updater(root, { manifest_url = http_handle.url("/manifest.json") })
            local res, err = up:checkForUpdate()
            assert.is_nil(err)
            assert.is_true(res.available)
            assert.are.equal("1.0.0", res.installed)
            assert.are.equal("1.2.0", res.latest)
        end)

        it("reports up-to-date when the manifest matches the installed version", function()
            local root = spec_helper._tmp_dir .. "/plugins"
            install_plugins(root, "1.2.0")
            http_handle = spec_helper.start_http_fixture({
                { path = "/manifest.json",
                  body = '{"version":"1.2.0","plugins":[{"dir":"booklore.koplugin","url":"http://x"}]}' },
            })
            local up = make_updater(root, { manifest_url = http_handle.url("/manifest.json") })
            local res = up:checkForUpdate()
            assert.is_false(res.available)
        end)

        it("returns an error when the update server is unreachable", function()
            local root = spec_helper._tmp_dir .. "/plugins"
            install_plugins(root, "1.0.0")
            http_handle = spec_helper.start_http_fixture({})
            local up = make_updater(root, { manifest_url = http_handle.url("/missing.json") })
            local res, err = up:checkForUpdate()
            assert.is_nil(res)
            assert.matches("couldn't reach", err)
        end)
    end)

    describe("commitStaged ordering", function()
        it("commits booklore_sync before booklore (self last)", function()
            local root = "/p"
            local exec, calls = recording_exec(function(cmd)
                return "", 0  -- every `test -d` succeeds -> both have .new + live
            end)
            local up = Updater.new{ plugins_root = root, exec = exec }
            assert.is_true(up:commitStaged())
            local sync_i = first_index(calls,
                "mv '/p/booklore_sync%.koplugin%.new' '/p/booklore_sync%.koplugin'")
            local bl_i = first_index(calls,
                "mv '/p/booklore%.koplugin%.new' '/p/booklore%.koplugin'")
            assert.is_truthy(sync_i)
            assert.is_truthy(bl_i)
            assert.is_true(sync_i < bl_i)
        end)
    end)

    describe("reconcile", function()
        it("installs a leftover .new (download done, swap interrupted)", function()
            local root = spec_helper._tmp_dir .. "/plugins"
            install_plugins(root, "1.0.0")
            -- Simulate a promoted-but-not-committed booklore.koplugin.new at 1.1.0
            os.execute("mkdir -p '" .. root .. "/booklore.koplugin.new'")
            write_file(root .. "/booklore.koplugin.new/_meta.lua",
                'return { version = "1.1.0" }\n')
            local up = make_updater(root)
            up:reconcile()
            assert.are.equal("1.1.0", up:getInstalledVersion("booklore.koplugin"))
            assert.are_not.equal(0, os.execute("test -e '" .. root .. "/booklore.koplugin.new'"))
        end)

        it("rolls back from .old when live is missing and there is no .new", function()
            local root = spec_helper._tmp_dir .. "/plugins"
            install_plugins(root, "1.0.0")
            os.execute("mv '" .. root .. "/booklore.koplugin' '" .. root .. "/booklore.koplugin.old'")
            local up = make_updater(root)
            up:reconcile()
            assert.are.equal("1.0.0", up:getInstalledVersion("booklore.koplugin"))
            assert.are_not.equal(0, os.execute("test -e '" .. root .. "/booklore.koplugin.old'"))
        end)

        it("cleans up a leftover .old when live already exists", function()
            local root = spec_helper._tmp_dir .. "/plugins"
            install_plugins(root, "1.0.0")
            os.execute("mkdir -p '" .. root .. "/booklore.koplugin.old'")
            local up = make_updater(root)
            up:reconcile()
            assert.are_not.equal(0, os.execute("test -e '" .. root .. "/booklore.koplugin.old'"))
            assert.are.equal("1.0.0", up:getInstalledVersion("booklore.koplugin"))
        end)
    end)

    describe("uninstall", function()
        it("removes both plugin directories", function()
            local root = spec_helper._tmp_dir .. "/plugins"
            install_plugins(root, "1.0.0")
            local up = make_updater(root)
            assert.is_true(up:uninstall())
            assert.are_not.equal(0, os.execute("test -d '" .. root .. "/booklore.koplugin'"))
            assert.are_not.equal(0, os.execute("test -d '" .. root .. "/booklore_sync.koplugin'"))
        end)

        it("keeps settings by default and purges them only when asked", function()
            local root = spec_helper._tmp_dir .. "/plugins"
            install_plugins(root, "1.0.0")
            local settings = spec_helper._tmp_dir .. "/booklore.lua"
            write_file(settings, "return {}\n")

            local up = make_updater(root)
            up:uninstall({ purge_settings = false, extra_paths = { settings } })
            assert.are.equal(0, os.execute("test -f '" .. settings .. "'"))  -- kept

            up:uninstall({ purge_settings = true, extra_paths = { settings } })
            assert.are_not.equal(0, os.execute("test -f '" .. settings .. "'"))  -- gone
        end)
    end)
end)
