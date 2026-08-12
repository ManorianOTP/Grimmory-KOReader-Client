--[[
  Tailscale lifecycle spec for grimmory.koplugin/tailscale.lua.

  The install pipeline runs for real: each test builds a genuine .tgz with
  the system tar, serves it (plus the release JSON) from the local Python
  HTTP fixture, downloads it over real LuaSocket HTTP, and lets the module's
  default shell exec run the real tar/cp/chmod against a per-test tmp dir.
  Daemon, up/down, and autostart flows use a scripted fake exec because no
  tailscaled can run in the harness.
]]
local spec_helper = require("spec_helper")

local CLI_BYTES = "#!/bin/sh\necho tailscale-cli\n"
local DAEMON_BYTES = "#!/bin/sh\necho tailscaled\n"

local function write_file(path, content)
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
end

local function read_file(path)
    local f = assert(io.open(path, "rb"))
    local content = f:read("*a")
    f:close()
    return content
end

local function sha256_file(path)
    local p = assert(io.popen("sha256sum '" .. path .. "'"))
    local out = p:read("*a")
    p:close()
    return assert(out:match("^([0-9a-f]+)"))
end

-- Scripted exec: first matching pattern wins; every command is recorded.
-- A rule is { pattern = ..., out = ..., code = ... } or
-- { pattern = ..., respond = function(cmd) return out, code end }.
local function make_fake_exec(rules)
    local calls = {}
    local exec = function(cmd)
        table.insert(calls, cmd)
        for i = 1, #rules do
            local rule = rules[i]
            if cmd:match(rule.pattern) then
                if rule.respond then return rule.respond(cmd) end
                return rule.out or "", rule.code or 0
            end
        end
        return "", 0
    end
    return exec, calls
end

local function calls_matching(calls, pattern)
    local n = 0
    for i = 1, #calls do
        if calls[i]:match(pattern) then n = n + 1 end
    end
    return n
end

describe("Tailscale", function()
    local Tailscale, UIManager
    local http_handle

    before_each(function()
        spec_helper.setup()
        Tailscale = require("tailscale")
        UIManager = require("ui/uimanager")
    end)

    after_each(function()
        spec_helper.teardown({ http_handle = http_handle })
        http_handle = nil
    end)

    -- Arch the module will detect on this machine (real `uname -m`), so the
    -- generated tarball name matches what install() asks the fixture for.
    local function detected_arch()
        return Tailscale.new({}):detectArch()
    end

    -- Build a real gzipped tarball matching the upstream layout
    -- tailscale_{version}_{arch}/{tailscale,tailscaled}.
    local function build_tarball(version, opts)
        opts = opts or {}
        local arch = detected_arch()
        local inner = opts.inner_dir or ("tailscale_" .. version .. "_" .. arch)
        local pkg_dir = spec_helper._tmp_dir .. "/pkg"
        os.execute("mkdir -p '" .. pkg_dir .. "/" .. inner .. "'")
        write_file(pkg_dir .. "/" .. inner .. "/tailscale", CLI_BYTES)
        if not opts.omit_daemon then
            write_file(pkg_dir .. "/" .. inner .. "/tailscaled", DAEMON_BYTES)
        end
        local tgz_name = "tailscale_" .. version .. "_" .. arch .. ".tgz"
        local tgz = pkg_dir .. "/" .. tgz_name
        assert.are.equal(0, os.execute(
            "cd '" .. pkg_dir .. "' && tar czf '" .. tgz .. "' '" .. inner .. "'"))
        return tgz, tgz_name
    end

    -- The pkgs.tailscale.com/stable/?mode=json manifest the installer now reads:
    -- version + the exact per-arch tarball filename, in lockstep.
    local function ts_manifest(version, tgz_name)
        return '{"Version":"' .. version .. '","Tarballs":{"'
            .. detected_arch() .. '":"' .. tgz_name .. '"}}'
    end


    local function checksum_route(tgz, tgz_name)
        return {
            path = "/stable/" .. tgz_name .. ".sha256",
            body = sha256_file(tgz) .. "  " .. tgz_name .. "\n",
        }
    end

    local function make_ts(overrides)
        local tmp = spec_helper._tmp_dir
        local opts = {
            request = require("socket.http").request,
            bin_dir = tmp .. "/bin",
            tmp_root = tmp .. "/install_tmp",
            socket_path = tmp .. "/tailscaled.sock",
            min_tarball_bytes = 16,
        }
        if http_handle then
            opts.pkgs_manifest_url = http_handle.url("/stable/manifest.json")
            opts.pkgs_base = http_handle.url("/stable/")
        end
        for k, v in pairs(overrides or {}) do opts[k] = v end
        return Tailscale.new(opts)
    end

    -- A strict install double: every production shell command must match one
    -- exact operation, filesystem effects are implemented directly in Lua,
    -- and unsafe extraction is refused even if the installer were to request
    -- it. This keeps the negative security tests independent of host tar.
    local function strict_install_harness(opts)
        opts = opts or {}
        local lfs = require("lfs")
        local root = spec_helper._tmp_dir .. "/strict"
        local tmp_root = root .. "/install_tmp"
        local bin_dir = root .. "/bin"
        local version, arch = "1.80.0", "arm"
        local extract_name = "tailscale_" .. version .. "_" .. arch
        local tgz_name = extract_name .. ".tgz"
        local tmp_tgz = tmp_root .. "/" .. tgz_name
        local extract_dir = tmp_root .. "/" .. extract_name
        local cli_src, daemon_src = extract_dir .. "/tailscale", extract_dir .. "/tailscaled"
        local cli_stage, daemon_stage = tmp_root .. "/tailscale.verified",
            tmp_root .. "/tailscaled.verified"
        local cli_live, daemon_live = bin_dir .. "/tailscale", bin_dir .. "/tailscaled"
        local cli_backup, daemon_backup = tmp_root .. "/tailscale.previous",
            tmp_root .. "/tailscaled.previous"
        local tgz_bytes = opts.tgz_bytes or "strict fake tgz bytes"
        local safe_listing = table.concat({
            "drwxr-xr-x root/root 0 2026-01-01 00:00 " .. extract_name .. "/",
            "-rwxr-xr-x root/root 29 2026-01-01 00:00 " .. extract_name .. "/tailscale",
            "-rwxr-xr-x root/root 25 2026-01-01 00:00 " .. extract_name .. "/tailscaled",
        }, "\n")
        local listing = opts.listing or safe_listing
        local state = { calls = {}, unexpected = {}, extract_attempted = false,
            fake_rejections = 0 }

        local function q(path) return "'" .. path .. "'" end
        local function ensure_dir(path)
            local current = path:sub(1, 1) == "/" and "/" or ""
            for part in path:gmatch("[^/]+") do
                current = current == "/" and (current .. part)
                    or (current == "" and part or current .. "/" .. part)
                lfs.mkdir(current)
            end
        end
        local function remove_tree(path)
            local attr = lfs.symlinkattributes(path)
            if not attr then return end
            if attr.mode == "directory" then
                for name in lfs.dir(path) do
                    if name ~= "." and name ~= ".." then
                        remove_tree(path .. "/" .. name)
                    end
                end
                os.remove(path)
            else
                os.remove(path)
            end
        end
        local function copy_file(src, dst, corrupt)
            local bytes = read_file(src)
            write_file(dst, bytes .. (corrupt and "!" or ""))
        end
        if opts.prior_cli_bytes ~= nil or opts.prior_daemon_bytes ~= nil then
            ensure_dir(bin_dir)
            if opts.prior_cli_bytes ~= nil then write_file(cli_live, opts.prior_cli_bytes) end
            if opts.prior_daemon_bytes ~= nil then
                write_file(daemon_live, opts.prior_daemon_bytes)
            end
        end
        local safe_to_extract = listing == safe_listing

        local exact = {
            cleanup = "rm -rf " .. q(tmp_root),
            mkdir_tmp = "mkdir -p " .. q(tmp_root),
            size = "wc -c < " .. q(tmp_tgz),
            list = "tar tvzf " .. q(tmp_tgz),
            extract = "cd " .. q(tmp_root) .. " && tar xzf " .. q(tmp_tgz),
            cp_cli = "cp " .. q(cli_src) .. " " .. q(cli_stage),
            cp_daemon = "cp " .. q(daemon_src) .. " " .. q(daemon_stage),
            chmod_cli = "chmod +x " .. q(cli_stage),
            chmod_daemon = "chmod +x " .. q(daemon_stage),
            mkdir_bin = "mkdir -p " .. q(bin_dir),
            mv_cli = "mv " .. q(cli_stage) .. " " .. q(cli_live),
            mv_daemon = "mv " .. q(daemon_stage) .. " " .. q(daemon_live),
            test_cli = "test -e " .. q(cli_live),
            test_daemon = "test -e " .. q(daemon_live),
            backup_cli = "mv " .. q(cli_live) .. " " .. q(cli_backup),
            backup_daemon = "mv " .. q(daemon_live) .. " " .. q(daemon_backup),
            remove_cli = "rm -f " .. q(cli_live),
            remove_daemon = "rm -f " .. q(daemon_live),
            restore_cli = "mv " .. q(cli_backup) .. " " .. q(cli_live),
            restore_daemon = "mv " .. q(daemon_backup) .. " " .. q(daemon_live),
        }

        local allowed_hash_paths = {
            [tmp_tgz] = true, [cli_src] = true, [daemon_src] = true,
            [cli_stage] = true, [daemon_stage] = true,
            [cli_live] = true, [daemon_live] = true,
        }
        local exec = function(cmd)
            table.insert(state.calls, cmd)
            if cmd == "uname -m" then return "armv7l", 0 end
            if cmd == exact.cleanup then remove_tree(tmp_root); return "", 0 end
            if cmd == exact.mkdir_tmp then ensure_dir(tmp_root); return "", 0 end
            if cmd == exact.size then return tostring(#read_file(tmp_tgz)), 0 end
            local hash_path = cmd:match("^sha256sum '([^']+)'$")
            if hash_path then
                if not allowed_hash_paths[hash_path] or not lfs.attributes(hash_path) then
                    state.fake_rejections = state.fake_rejections + 1
                    return "strict fake rejected hash path", 96
                end
                return sha256_file(hash_path) .. "  " .. hash_path, 0
            end
            if cmd == exact.list then return listing, 0 end
            if cmd == exact.extract then
                state.extract_attempted = true
                if not safe_to_extract then
                    state.fake_rejections = state.fake_rejections + 1
                    return "strict fake rejected unsafe extraction", 95
                end
                ensure_dir(extract_dir)
                write_file(cli_src, opts.cli_bytes or CLI_BYTES)
                write_file(daemon_src, opts.daemon_bytes or DAEMON_BYTES)
                return "", 0
            end
            if cmd == exact.cp_cli then
                copy_file(cli_src, cli_stage, opts.corrupt_cli_copy)
                return "", 0
            end
            if cmd == exact.cp_daemon then copy_file(daemon_src, daemon_stage); return "", 0 end
            if cmd == exact.chmod_cli or cmd == exact.chmod_daemon then return "", 0 end
            if cmd == exact.mkdir_bin then ensure_dir(bin_dir); return "", 0 end
            if cmd == exact.test_cli then
                return "", lfs.symlinkattributes(cli_live) and 0 or 1
            end
            if cmd == exact.test_daemon then
                return "", lfs.symlinkattributes(daemon_live) and 0 or 1
            end
            if cmd == exact.backup_cli then
                return "", os.rename(cli_live, cli_backup) and 0 or 1
            end
            if cmd == exact.backup_daemon then
                return "", os.rename(daemon_live, daemon_backup) and 0 or 1
            end
            if cmd == exact.remove_cli then os.remove(cli_live); return "", 0 end
            if cmd == exact.remove_daemon then os.remove(daemon_live); return "", 0 end
            if cmd == exact.restore_cli then
                return "", os.rename(cli_backup, cli_live) and 0 or 1
            end
            if cmd == exact.restore_daemon then
                return "", os.rename(daemon_backup, daemon_live) and 0 or 1
            end
            if cmd == exact.mv_cli then
                local ok = os.rename(cli_stage, cli_live)
                if ok and opts.corrupt_final_cli then
                    write_file(cli_live, read_file(cli_live) .. "!")
                end
                return "", ok and 0 or 1
            end
            if cmd == exact.mv_daemon then
                if opts.fail_daemon_publish then return "injected second move failure", 88 end
                return "", os.rename(daemon_stage, daemon_live) and 0 or 1
            end
            table.insert(state.unexpected, cmd)
            state.fake_rejections = state.fake_rejections + 1
            return "strict fake rejected unexpected command", 97
        end

        local base = "https://strict.invalid/stable/"
        local manifest_url = base .. "manifest.json"
        local checksum = opts.checksum or sha256_file((function()
            ensure_dir(root)
            local oracle = root .. "/tgz-oracle"
            write_file(oracle, tgz_bytes)
            return oracle
        end)())
        local request = function(req)
            local body, code
            if req.url == manifest_url then
                body, code = ts_manifest(version, opts.tgz_name or tgz_name), 200
            elseif req.url == base .. tgz_name then
                body, code = tgz_bytes, 200
            elseif req.url == base .. tgz_name .. ".sha256" then
                body, code = checksum .. "  " .. tgz_name .. "\n", 200
            else
                body, code = "not found", 404
            end
            if req.sink then req.sink(body); req.sink(nil) end
            return code == 200 and 1 or nil, code
        end
        local ts = Tailscale.new{
            exec = exec,
            request = request,
            pkgs_manifest_url = manifest_url,
            pkgs_base = base,
            bin_dir = bin_dir,
            tmp_root = tmp_root,
            min_tarball_bytes = 1,
        }
        return ts, state, {
            cli = cli_live, daemon = daemon_live, tmp_root = tmp_root,
            listing = safe_listing,
        }
    end

    describe("install security oracle (strict shell/filesystem fake)", function()
        it("installs the exact authenticated binary bytes and nothing unexpected", function()
            local ts, state, paths = strict_install_harness()
            local version, err = ts:install()
            assert.is_nil(err)
            assert.are.equal("1.80.0", version)
            assert.are.equal(CLI_BYTES, read_file(paths.cli))
            assert.are.equal(DAEMON_BYTES, read_file(paths.daemon))
            assert.are.same({}, state.unexpected)
            assert.are.equal(0, state.fake_rejections)
        end)

        for _, attack in ipairs({
            { label = "traversal", line = "-rwxr-xr-x root/root 1 2026-01-01 00:00 tailscale_1.80.0_arm/../../escape" },
            { label = "symlink escape", line = "lrwxrwxrwx root/root 0 2026-01-01 00:00 tailscale_1.80.0_arm/tailscale -> ../../outside" },
            { label = "hardlink escape", line = "hrwxr-xr-x root/root 0 2026-01-01 00:00 tailscale_1.80.0_arm/tailscaled link to ../../outside" },
            { label = "unexpected member", line = "-rwxr-xr-x root/root 1 2026-01-01 00:00 tailscale_1.80.0_arm/postinstall.sh" },
        }) do
            it("rejects " .. attack.label .. " before extraction", function()
                local ts, state, paths = strict_install_harness({ listing = attack.line })
                local version, err = ts:install()
                assert.is_nil(version)
                assert.matches("Unsafe Tailscale archive", err)
                assert.is_false(state.extract_attempted)
                assert.is_nil(io.open(paths.cli, "rb"))
                assert.are.same({}, state.unexpected)
            end)
        end

        it("rejects wrong archive bytes against the published hash", function()
            local ts, state = strict_install_harness({ checksum = string.rep("0", 64) })
            local version, err = ts:install()
            assert.is_nil(version)
            assert.matches("checksum mismatch", err)
            assert.is_false(state.extract_attempted)
            assert.are.same({}, state.unexpected)
        end)

        it("rejects a corrupted staged binary before publishing either file", function()
            local ts, state, paths = strict_install_harness({ corrupt_cli_copy = true })
            local version, err = ts:install()
            assert.is_nil(version)
            assert.matches("copy verification failed", err)
            assert.is_true(state.extract_attempted)
            assert.is_nil(io.open(paths.cli, "rb"))
            assert.is_nil(io.open(paths.daemon, "rb"))
            assert.are.same({}, state.unexpected)
        end)

        it("removes both live files when a fresh install's second publish move fails", function()
            local ts, state, paths = strict_install_harness({ fail_daemon_publish = true })
            local version, err = ts:install()
            assert.is_nil(version)
            assert.matches("injected second move failure", err)
            assert.is_nil(io.open(paths.cli, "rb"))
            assert.is_nil(io.open(paths.daemon, "rb"))
            assert.are.same({}, state.unexpected)
        end)

        it("restores the exact prior pair when the second publish move fails", function()
            local old_cli = "old-cli-exact-bytes\0\1"
            local old_daemon = "old-daemon-exact-bytes\2\3"
            local ts, state, paths = strict_install_harness({
                prior_cli_bytes = old_cli,
                prior_daemon_bytes = old_daemon,
                fail_daemon_publish = true,
            })
            local lfs = require("lfs")
            local cli_mode = lfs.attributes(paths.cli, "permissions")
            local daemon_mode = lfs.attributes(paths.daemon, "permissions")
            local version, err = ts:install()
            assert.is_nil(version)
            assert.matches("injected second move failure", err)
            assert.are.equal(old_cli, read_file(paths.cli))
            assert.are.equal(old_daemon, read_file(paths.daemon))
            assert.are.equal(cli_mode, lfs.attributes(paths.cli, "permissions"))
            assert.are.equal(daemon_mode, lfs.attributes(paths.daemon, "permissions"))
            assert.are.same({}, state.unexpected)
        end)

        it("restores the exact prior pair after final-byte corruption", function()
            local old_cli = "previous-cli"
            local old_daemon = "previous-daemon"
            local ts, state, paths = strict_install_harness({
                prior_cli_bytes = old_cli,
                prior_daemon_bytes = old_daemon,
                corrupt_final_cli = true,
            })
            local version, err = ts:install()
            assert.is_nil(version)
            assert.matches("Installed Tailscale binary verification failed", err)
            assert.are.equal(old_cli, read_file(paths.cli))
            assert.are.equal(old_daemon, read_file(paths.daemon))
            assert.are.same({}, state.unexpected)
        end)

        it("rejects a manifest filename that does not exactly match version and arch", function()
            local ts, state = strict_install_harness({ tgz_name = "../../evil.tgz" })
            local version, err = ts:install()
            assert.is_nil(version)
            assert.matches("unsafe package name", err)
            assert.is_false(state.extract_attempted)
            assert.are.same({}, state.unexpected)
        end)
    end)

    describe("install pipeline (real shell + local HTTP)", function()
        it("downloads, extracts, installs, and marks both binaries executable", function()
            local tgz, tgz_name = build_tarball("1.80.0")
            http_handle = spec_helper.start_http_fixture({
                { path = "/stable/manifest.json", body = ts_manifest("1.80.0", tgz_name) },
                { path = "/stable/" .. tgz_name, body_file = tgz },
                checksum_route(tgz, tgz_name),
            })
            local ts = make_ts()
            assert.is_false(ts:isInstalled())

            local progress = {}
            local version, err = ts:install(function(msg) table.insert(progress, msg) end)

            assert.is_nil(err)
            assert.are.equal("1.80.0", version)
            assert.is_true(ts:isInstalled())
            assert.are.equal(CLI_BYTES, read_file(ts.cmd))
            assert.are.equal(DAEMON_BYTES, read_file(ts.daemon_cmd))
            -- chmod +x really ran: the installed shell scripts execute
            assert.are.equal(0, os.execute("'" .. ts.cmd .. "' > /dev/null 2>&1"))
            assert.are.equal(0, os.execute("'" .. ts.daemon_cmd .. "' > /dev/null 2>&1"))
            -- temp install dir is cleaned up on success
            assert.are_not.equal(0, os.execute("test -d '" .. ts.tmp_root .. "'"))
            -- progress callback saw both phases
            assert.are.equal(2, #progress)
        end)

        it("retries once when the tarball download has a transient failure", function()
            local tgz, tgz_name = build_tarball("1.80.0")
            http_handle = spec_helper.start_http_fixture({
                { path = "/stable/manifest.json", body = ts_manifest("1.80.0", tgz_name) },
                { path = "/stable/" .. tgz_name, body_file = tgz },
                checksum_route(tgz, tgz_name),
            })
            local real = require("socket.http").request
            local tgz_attempts = 0
            local flaky = function(req)
                if req.url:match("%.tgz$") then
                    tgz_attempts = tgz_attempts + 1
                    if tgz_attempts == 1 then return nil, 500 end  -- dropped connection
                end
                return real(req)
            end
            local ts = make_ts({ request = flaky })
            local version, err = ts:install()
            assert.is_nil(err)
            assert.are.equal("1.80.0", version)
            assert.are.equal(2, tgz_attempts)  -- failed once, then succeeded
            assert.is_true(ts:isInstalled())
        end)

        it("gives up and cleans up after the retry budget is exhausted", function()
            local _tgz, tgz_name = build_tarball("1.80.0")
            http_handle = spec_helper.start_http_fixture({
                { path = "/stable/manifest.json", body = ts_manifest("1.80.0", tgz_name) },
                { path = "/stable/" .. tgz_name, body_file = _tgz },
            })
            local real = require("socket.http").request
            local flaky = function(req)
                if req.url:match("%.tgz$") then return nil, 500 end
                return real(req)
            end
            local ts = make_ts({ request = flaky })
            local version, err = ts:install()
            assert.is_nil(version)
            assert.matches("Download failed", err)
            assert.are_not.equal(0, os.execute("test -d '" .. ts.tmp_root .. "'"))
        end)

        it("fails when the package list returns an HTTP error", function()
            http_handle = spec_helper.start_http_fixture({
                { path = "/stable/manifest.json", status = 500, body = "boom" },
            })
            local ts = make_ts()
            local version, err = ts:install()
            assert.is_nil(version)
            assert.matches("Failed to fetch the Tailscale package list", err)
        end)

        it("fails when the package list has no build for this arch", function()
            http_handle = spec_helper.start_http_fixture({
                { path = "/stable/manifest.json", body = '{"Version":"1.80.0","Tarballs":{}}' },
            })
            local ts = make_ts()
            local version, err = ts:install()
            assert.is_nil(version)
            assert.matches("No Tailscale static build for arch", err)
        end)

        it("fails and cleans up when the tarball download 404s", function()
            local _t, tgz_name = build_tarball("1.80.0")  -- built for its name; not served
            http_handle = spec_helper.start_http_fixture({
                { path = "/stable/manifest.json", body = ts_manifest("1.80.0", tgz_name) },
            })
            local ts = make_ts()
            local version, err = ts:install()
            assert.is_nil(version)
            assert.matches("Download failed", err)
            assert.are_not.equal(0, os.execute("test -d '" .. ts.tmp_root .. "'"))
        end)

        it("rejects a download below the size floor and cleans up", function()
            local tgz, tgz_name = build_tarball("1.80.0")
            http_handle = spec_helper.start_http_fixture({
                { path = "/stable/manifest.json", body = ts_manifest("1.80.0", tgz_name) },
                { path = "/stable/" .. tgz_name, body_file = tgz },
                checksum_route(tgz, tgz_name),
            })
            local ts = make_ts({ min_tarball_bytes = 10 * 1048576 })
            local version, err = ts:install()
            assert.is_nil(version)
            assert.matches("too small", err)
            assert.are_not.equal(0, os.execute("test -d '" .. ts.tmp_root .. "'"))
        end)

        it("fails when the archive lacks the expected directory layout", function()
            local tgz, tgz_name = build_tarball("1.80.0", { inner_dir = "unexpected_dir" })
            http_handle = spec_helper.start_http_fixture({
                { path = "/stable/manifest.json", body = ts_manifest("1.80.0", tgz_name) },
                { path = "/stable/" .. tgz_name, body_file = tgz },
                checksum_route(tgz, tgz_name),
            })
            local ts = make_ts()
            local version, err = ts:install()
            assert.is_nil(version)
            assert.matches("Unsafe Tailscale archive", err)
            assert.are_not.equal(0, os.execute("test -d '" .. ts.tmp_root .. "'"))
        end)

        it("fails when the archive is missing the daemon binary", function()
            local tgz, tgz_name = build_tarball("1.80.0", { omit_daemon = true })
            http_handle = spec_helper.start_http_fixture({
                { path = "/stable/manifest.json", body = ts_manifest("1.80.0", tgz_name) },
                { path = "/stable/" .. tgz_name, body_file = tgz },
                checksum_route(tgz, tgz_name),
            })
            local ts = make_ts()
            local version, err = ts:install()
            assert.is_nil(version)
            assert.matches("both expected binaries", err)
            assert.is_false(ts:isInstalled())
        end)
    end)

    describe("fetchLatestRelease", function()
        it("returns the version and arch tarball from the pkgs manifest", function()
            local tgz_name = "tailscale_1.98.4_" .. detected_arch() .. ".tgz"
            http_handle = spec_helper.start_http_fixture({
                { path = "/stable/manifest.json", body = ts_manifest("1.98.4", tgz_name) },
            })
            local version, tarball = make_ts():fetchLatestRelease()
            assert.are.equal("1.98.4", version)
            assert.are.equal(tgz_name, tarball)
        end)

        it("errors when the manifest has no build for this arch", function()
            http_handle = spec_helper.start_http_fixture({
                { path = "/stable/manifest.json", body = '{"Version":"1.98.4","Tarballs":{}}' },
            })
            local version, tarball, err = make_ts():fetchLatestRelease()
            assert.is_nil(version)
            assert.is_nil(tarball)
            assert.matches("No Tailscale static build for arch", err)
        end)
    end)

    describe("installedVersion", function()
        it("parses the version from `tailscale version`", function()
            local ts = make_ts({ exec = make_fake_exec({
                { pattern = " version", out = "1.80.0\n  go version: go1.x", code = 0 },
            }) })
            os.execute("mkdir -p '" .. ts.bin_dir .. "'")
            write_file(ts.cmd, "x")
            write_file(ts.daemon_cmd, "x")
            assert.are.equal("1.80.0", ts:installedVersion())
        end)

        it("returns nil when Tailscale is not installed", function()
            local ts = make_ts({ exec = make_fake_exec({}) })
            assert.is_nil(ts:installedVersion())
        end)
    end)

    describe("statusSummary", function()
        it("summarizes the JSON status (state, self, peer counts)", function()
            local json_out = [[{
                "BackendState": "Running",
                "Self": { "HostName": "my-kindle", "DNSName": "my-kindle.tail.ts.net.",
                          "TailscaleIPs": ["100.64.0.5"], "Online": true },
                "Peer": {
                    "k1": { "HostName": "laptop", "Online": true },
                    "k2": { "HostName": "phone",  "Online": false }
                }
            }]]
            local ts = make_ts({ exec = make_fake_exec({
                { pattern = "status %-%-json", out = json_out, code = 0 },
            }) })
            local s = ts:statusSummary()
            assert.are.equal("Running", s.state)
            assert.are.equal("my-kindle", s.hostname)
            assert.are.equal("100.64.0.5", s.ip)
            assert.are.equal(1, s.peers_online)
            assert.are.equal(2, s.peers_total)
        end)

        it("returns an error when the status command fails", function()
            local ts = make_ts({ exec = make_fake_exec({
                { pattern = "status %-%-json", out = "boom", code = 1 },
            }) })
            local s, err = ts:statusSummary()
            assert.is_nil(s)
            assert.matches("boom", err)
        end)
    end)

    describe("installed/daemon detection", function()
        it("isInstalled requires both binaries on disk", function()
            local ts = make_ts({ exec = make_fake_exec({}) })
            os.execute("mkdir -p '" .. ts.bin_dir .. "'")
            assert.is_false(ts:isInstalled())
            write_file(ts.cmd, "x")
            assert.is_false(ts:isInstalled())
            write_file(ts.daemon_cmd, "x")
            assert.is_true(ts:isInstalled())
        end)

        it("reports running when pidof finds the process", function()
            local exec = make_fake_exec({
                { pattern = "^pidof", out = "1234", code = 0 },
            })
            local ts = make_ts({ exec = exec })
            assert.is_true(ts:isDaemonRunning())
        end)

        it("falls back to the socket file when pidof and pgrep fail", function()
            local exec = make_fake_exec({
                { pattern = "^pidof", out = "", code = 1 },
                { pattern = "^pgrep", out = "", code = 1 },
            })
            local ts = make_ts({ exec = exec })
            assert.is_false(ts:isDaemonRunning())
            write_file(ts.socket_path, "")
            assert.is_true(ts:isDaemonRunning())
        end)
    end)

    describe("startDaemon", function()
        -- Stateful exec: process checks fail until the launch command runs.
        local function daemon_world(opts)
            opts = opts or {}
            local running = false
            local exec, calls = make_fake_exec({
                { pattern = "^pidof", respond = function()
                    if running then return "99", 0 end
                    return "", 1
                end },
                { pattern = "^pgrep", respond = function()
                    if running then return "99", 0 end
                    return "", 1
                end },
                { pattern = "^tail %-5", out = opts.log_tail or "", code = 0 },
                { pattern = "tailscaled %-%-state", respond = function()
                    if not opts.launch_dies then running = true end
                    return "", opts.launch_code or 0
                end },
            })
            return exec, calls
        end

        it("short-circuits when the daemon is already running", function()
            local exec, calls = make_fake_exec({
                { pattern = "^pidof", out = "99", code = 0 },
            })
            local ts = make_ts({ exec = exec })
            local got_ok
            ts:startDaemon(function(ok) got_ok = ok end)
            assert.is_true(got_ok)
            assert.are.equal(0, calls_matching(calls, "tailscaled %-%-state"))
        end)

        it("launches then confirms after the 3s settle delay", function()
            local exec, calls = daemon_world()
            local ts = make_ts({ exec = exec })
            local got_ok
            ts:startDaemon(function(ok) got_ok = ok end)
            assert.is_nil(got_ok)  -- verdict waits for the settle check
            assert.are.equal(1, calls_matching(calls, "tailscaled %-%-state"))
            UIManager.tickBy(3)
            assert.is_true(got_ok)
        end)

        it("reports the log tail when the daemon dies immediately", function()
            local exec = daemon_world({ launch_dies = true, log_tail = "TUN device error" })
            local ts = make_ts({ exec = exec })
            local got_ok, got_err
            ts:startDaemon(function(ok, err) got_ok, got_err = ok, err end)
            UIManager.tickBy(3)
            assert.is_false(got_ok)
            assert.matches("TUN device error", got_err)
        end)

        it("fails fast when the launch command itself errors", function()
            local exec = daemon_world({ launch_dies = true, launch_code = 127 })
            local ts = make_ts({ exec = exec })
            local got_ok, got_err
            ts:startDaemon(function(ok, err) got_ok, got_err = ok, err end)
            assert.is_false(got_ok)
            assert.matches("exit 127", got_err)
        end)
    end)

    describe("up / down / status", function()
        it("up succeeds on exit 0", function()
            local exec = make_fake_exec({
                { pattern = " up %-%-timeout", out = "", code = 0 },
            })
            local ts = make_ts({ exec = exec })
            assert.is_true(ts:up())
        end)

        it("up surfaces the auth URL when authentication is needed", function()
            local out = "To authenticate, visit:\n\nhttps://login.tailscale.com/a/abc123\n"
            local exec = make_fake_exec({
                { pattern = " up %-%-timeout", out = out, code = 1 },
            })
            local ts = make_ts({ exec = exec })
            local ok, auth_url = ts:up()
            assert.is_false(ok)
            assert.are.equal("https://login.tailscale.com/a/abc123", auth_url)
        end)

        it("up returns the raw output when there is no auth URL", function()
            local exec = make_fake_exec({
                { pattern = " up %-%-timeout", out = "timeout waiting for daemon", code = 1 },
            })
            local ts = make_ts({ exec = exec })
            local ok, auth_url, output = ts:up()
            assert.is_false(ok)
            assert.is_nil(auth_url)
            assert.matches("timeout waiting", output)
        end)

        it("isConnected is false when status reports Logged out", function()
            local exec = make_fake_exec({
                { pattern = " status", out = "Logged out.", code = 0 },
            })
            local ts = make_ts({ exec = exec })
            assert.is_false(ts:isConnected())
        end)

        it("down reports the command outcome", function()
            local exec = make_fake_exec({
                { pattern = " down", out = "", code = 0 },
            })
            local ts = make_ts({ exec = exec })
            assert.is_true(ts:down())
        end)
    end)

    describe("autostart", function()
        local function install_binaries(ts)
            os.execute("mkdir -p '" .. ts.bin_dir .. "'")
            write_file(ts.cmd, "x")
            write_file(ts.daemon_cmd, "x")
        end

        -- Daemon not running until launched; `up` succeeds.
        local function autostart_world()
            local running = false
            return make_fake_exec({
                { pattern = "^pidof", respond = function()
                    if running then return "99", 0 end
                    return "", 1
                end },
                { pattern = "^pgrep", respond = function()
                    if running then return "99", 0 end
                    return "", 1
                end },
                { pattern = "tailscaled %-%-state", respond = function()
                    running = true
                    return "", 0
                end },
                { pattern = " up %-%-timeout", out = "", code = 0 },
            })
        end

        it("is a no-op when Tailscale is not installed", function()
            local exec, calls = make_fake_exec({})
            local ts = make_ts({ exec = exec })
            ts:autostart()
            UIManager.tickBy(3)
            assert.are.equal(0, #calls)
        end)

        it("starts the daemon then connects when WiFi is on", function()
            local exec, calls = autostart_world()
            local ts = make_ts({ exec = exec, wifi_is_on = function() return true end })
            install_binaries(ts)
            ts:autostart()
            assert.are.equal(0, calls_matching(calls, " up %-%-timeout"))
            UIManager.tickBy(3)
            assert.are.equal(1, calls_matching(calls, "tailscaled %-%-state"))
            assert.are.equal(1, calls_matching(calls, " up %-%-timeout"))
        end)

        it("starts the daemon but skips `up` when WiFi is off", function()
            local exec, calls = autostart_world()
            local ts = make_ts({ exec = exec, wifi_is_on = function() return false end })
            install_binaries(ts)
            ts:autostart()
            UIManager.tickBy(3)
            assert.are.equal(1, calls_matching(calls, "tailscaled %-%-state"))
            assert.are.equal(0, calls_matching(calls, " up %-%-timeout"))
        end)

        it("goes straight to `up` when the daemon is already running", function()
            local exec, calls = make_fake_exec({
                { pattern = "^pidof", out = "99", code = 0 },
                { pattern = " up %-%-timeout", out = "", code = 0 },
            })
            local ts = make_ts({ exec = exec, wifi_is_on = function() return true end })
            install_binaries(ts)
            ts:autostart()
            assert.are.equal(0, calls_matching(calls, "tailscaled %-%-state"))
            assert.are.equal(1, calls_matching(calls, " up %-%-timeout"))
        end)

        it("never shows UI, even when `up` needs authentication", function()
            local exec = make_fake_exec({
                { pattern = "^pidof", out = "99", code = 0 },
                { pattern = " up %-%-timeout",
                  out = "https://login.tailscale.com/a/abc123", code = 1 },
            })
            local ts = make_ts({ exec = exec, wifi_is_on = function() return true end })
            install_binaries(ts)
            ts:autostart()
            UIManager.tickBy(3)
            assert.are.equal(0, #UIManager.shown())
        end)

        it("routes the blocking `up` through an injected run_blocking", function()
            -- On device main.lua injects the async gateway here so `up` forks
            -- instead of freezing the UI. A deferring runner proves `up` does
            -- not run until the runner chooses to execute the task.
            local exec, calls = make_fake_exec({
                { pattern = "^pidof", out = "99", code = 0 },
                { pattern = " up %-%-timeout", out = "", code = 0 },
            })
            local deferred
            local ts = make_ts({
                exec = exec,
                wifi_is_on = function() return true end,
                run_blocking = function(task, on_done)
                    deferred = function() on_done(task()) end
                end,
            })
            install_binaries(ts)
            ts:autostart()
            assert.are.equal(0, calls_matching(calls, " up %-%-timeout"),
                "up must not run until the injected runner executes the task")
            deferred()
            assert.are.equal(1, calls_matching(calls, " up %-%-timeout"),
                "up runs once the runner executes the deferred task")
        end)
    end)
end)
