--[[
  Tailscale lifecycle spec for booklore.koplugin/tailscale.lua.

  The install pipeline runs for real: each test builds a genuine .tgz with
  the system tar, serves it (plus the release JSON) from the local Python
  HTTP fixture, downloads it over real LuaSocket HTTP, and lets the module's
  default shell exec run the real tar/cp/chmod against a per-test tmp dir.
  Daemon, up/down, and autostart flows use a scripted fake exec because no
  tailscaled can run in the harness.
]]
local spec_helper = require("spec_helper")

local function write_file(path, content)
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
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
        write_file(pkg_dir .. "/" .. inner .. "/tailscale",
            "#!/bin/sh\necho tailscale-cli\n")
        if not opts.omit_daemon then
            write_file(pkg_dir .. "/" .. inner .. "/tailscaled",
                "#!/bin/sh\necho tailscaled\n")
        end
        local tgz_name = "tailscale_" .. version .. "_" .. arch .. ".tgz"
        local tgz = pkg_dir .. "/" .. tgz_name
        assert.are.equal(0, os.execute(
            "cd '" .. pkg_dir .. "' && tar czf '" .. tgz .. "' '" .. inner .. "'"))
        return tgz, tgz_name
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
            opts.releases_url = http_handle.url("/releases/latest")
            opts.pkgs_base = http_handle.url("/stable/")
        end
        for k, v in pairs(overrides or {}) do opts[k] = v end
        return Tailscale.new(opts)
    end

    describe("install pipeline (real shell + local HTTP)", function()
        it("downloads, extracts, installs, and marks both binaries executable", function()
            local tgz, tgz_name = build_tarball("1.80.0")
            http_handle = spec_helper.start_http_fixture({
                { path = "/releases/latest", body = '{"tag_name": "v1.80.0"}' },
                { path = "/stable/" .. tgz_name, body_file = tgz },
            })
            local ts = make_ts()
            assert.is_false(ts:isInstalled())

            local progress = {}
            local version, err = ts:install(function(msg) table.insert(progress, msg) end)

            assert.is_nil(err)
            assert.are.equal("1.80.0", version)
            assert.is_true(ts:isInstalled())
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
                { path = "/releases/latest", body = '{"tag_name": "v1.80.0"}' },
                { path = "/stable/" .. tgz_name, body_file = tgz },
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
                { path = "/releases/latest", body = '{"tag_name": "v1.80.0"}' },
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

        it("fails when the release feed returns an HTTP error", function()
            http_handle = spec_helper.start_http_fixture({
                { path = "/releases/latest", status = 500, body = "boom" },
            })
            local ts = make_ts()
            local version, err = ts:install()
            assert.is_nil(version)
            assert.matches("Failed to fetch latest Tailscale version", err)
        end)

        it("fails when the release feed has no version tag", function()
            http_handle = spec_helper.start_http_fixture({
                { path = "/releases/latest", body = '{"message": "rate limited"}' },
            })
            local ts = make_ts()
            local version, err = ts:install()
            assert.is_nil(version)
            assert.matches("Could not parse version", err)
        end)

        it("fails and cleans up when the tarball download 404s", function()
            http_handle = spec_helper.start_http_fixture({
                { path = "/releases/latest", body = '{"tag_name": "v1.80.0"}' },
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
                { path = "/releases/latest", body = '{"tag_name": "v1.80.0"}' },
                { path = "/stable/" .. tgz_name, body_file = tgz },
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
                { path = "/releases/latest", body = '{"tag_name": "v1.80.0"}' },
                { path = "/stable/" .. tgz_name, body_file = tgz },
            })
            local ts = make_ts()
            local version, err = ts:install()
            assert.is_nil(version)
            assert.matches("does not contain expected binaries", err)
            assert.are_not.equal(0, os.execute("test -d '" .. ts.tmp_root .. "'"))
        end)

        it("fails when the archive is missing the daemon binary", function()
            local tgz, tgz_name = build_tarball("1.80.0", { omit_daemon = true })
            http_handle = spec_helper.start_http_fixture({
                { path = "/releases/latest", body = '{"tag_name": "v1.80.0"}' },
                { path = "/stable/" .. tgz_name, body_file = tgz },
            })
            local ts = make_ts()
            local version, err = ts:install()
            assert.is_nil(version)
            assert.matches("tailscaled", err)
            assert.is_false(ts:isInstalled())
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
