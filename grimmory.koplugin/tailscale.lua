--[[
    Tailscale lifecycle on a jailbroken Kindle: install from static ARM
    binaries, daemon start/stop detection, up/down/status, and the silent
    autostart used when the user enables "start with KOReader".

    Standalone module — no KOReader widget dependencies — so the whole
    download-and-install pipeline is unit-testable off device. UI flows
    (InfoMessage progress, QR auth, confirm boxes) live in main.lua; this
    module returns plain values and non-localized error strings for main
    to wrap in user-facing dialogs.

    Side effects are injectable via the opts table to new():
      exec(cmd)      shell runner -> trimmed output, exit code
      request(req)   LTN12-style HTTP request -> result, status code.
                     Defaults to LuaSec HTTPS: BusyBox wget on Kindle cannot
                     complete TLS handshakes with GitHub/pkgs.tailscale.com.
      wifi_is_on()   connectivity probe (autostart skips `up` when off)
      bin_dir, tmp_root, pkgs_base, pkgs_manifest_url, socket_path,
      min_tarball_bytes
    Defaults target the real device; tests point the paths and URLs at a
    temp directory and the local HTTP fixture, so the pipeline runs the
    real shell (tar, cp, chmod) end to end.
]]

local UIManager = require("ui/uimanager")
local logger = require("logger")

local Tailscale = {}
Tailscale.__index = Tailscale

local DEFAULTS = {
    bin_dir = "/mnt/us/extensions/tailscale/bin",
    tmp_root = "/mnt/us/tailscale_install",
    pkgs_base = "https://pkgs.tailscale.com/stable/",
    socket_path = "/var/run/tailscale/tailscaled.sock",
    -- ARM tarball is ~25+ MB; < 1 MB means an HTML error page or truncation.
    min_tarball_bytes = 1048576,
}

--- Run a shell command and capture its stdout + exit code.
-- @param cmd string: shell command
-- @return string: stdout output (trimmed)
-- @return number: exit code
local function defaultExec(cmd)
    local handle = io.popen(cmd .. " 2>&1; echo __EXIT_$?")
    if not handle then return "", -1 end
    local raw = handle:read("*a")
    handle:close()
    local code = tonumber(raw:match("__EXIT_(%d+)%s*$")) or -1
    local output = raw:gsub("__EXIT_%d+%s*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
    return output, code
end

local function shq(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

function Tailscale.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Tailscale)
    for k, default in pairs(DEFAULTS) do
        if opts[k] ~= nil then self[k] = opts[k] else self[k] = default end
    end
    self.exec = opts.exec or defaultExec
    self.hash_file = opts.hash_file or function(path)
        local out, code = self.exec("sha256sum " .. shq(path))
        if code ~= 0 then return nil end
        local digest = (out or ""):match("^([0-9a-fA-F]+)")
        if not digest or #digest ~= 64 then return nil end
        return digest:lower()
    end
    self.request = opts.request
    -- Overridable so specs can point at a fixture path without a query string;
    -- defaults to pkgs_base .. "?mode=json" inside fetchLatestRelease.
    self.pkgs_manifest_url = opts.pkgs_manifest_url
    self.wifi_is_on = opts.wifi_is_on or function() return true end
    -- run_blocking(task, on_done): runs a blocking thunk and delivers its
    -- result to on_done. Defaults to synchronous (standalone use and specs);
    -- main.lua injects the async subprocess gateway so the silent autostart's
    -- `tailscale up` (up to 30s) never blocks the UI thread.
    self.run_blocking = opts.run_blocking or function(task, on_done)
        return on_done(task())
    end
    self.cmd = self.bin_dir .. "/tailscale"
    self.daemon_cmd = self.bin_dir .. "/tailscaled"
    self.state_path = self.bin_dir .. "/tailscaled.state"
    return self
end

function Tailscale:_request(req)
    if self.request then return self.request(req) end
    local https = require("ssl.https")
    return https.request(req)
end

--- Run a shell command and return false + message on non-zero exit.
function Tailscale:_checkedExec(cmd)
    local out, code = self.exec(cmd)
    if code ~= 0 then
        return false, cmd .. " failed (exit " .. tostring(code) .. "): " .. (out or "")
    end
    return true, nil
end

--- Check whether both tailscale binaries exist on disk.
function Tailscale:isInstalled()
    local f1 = io.open(self.cmd, "r")
    if not f1 then return false end
    f1:close()
    local f2 = io.open(self.daemon_cmd, "r")
    if not f2 then return false end
    f2:close()
    return true
end

--- Check whether tailscaled is currently running.
-- BusyBox pgrep may not support -x; try multiple detection methods.
function Tailscale:isDaemonRunning()
    -- Method 1: pidof (usually reliable on BusyBox)
    local _out, code = self.exec("pidof tailscaled")
    if code == 0 then return true end
    -- Method 2: check the socket file
    local f = io.open(self.socket_path)
    if f then f:close() return true end
    -- Method 3: pgrep without -x
    _out, code = self.exec("pgrep tailscaled")
    return code == 0
end

--- Start the tailscaled daemon (TUN mode, the default).
-- Async: result delivered via on_done(ok, err) after a 3-second UIManager
-- delay, giving the daemon time to settle (or crash) before the check.
-- @param on_done function(boolean, string|nil)
function Tailscale:startDaemon(on_done)
    if self:isDaemonRunning() then return on_done(true, nil) end

    -- Ensure socket dir exists and clean up stale socket
    local socket_dir = self.socket_path:match("(.*)/[^/]+$")
    if socket_dir then self.exec("mkdir -p " .. socket_dir) end
    self.exec("rm -f " .. self.socket_path)

    local log_path = self.bin_dir .. "/tailscaled_start_log.txt"
    local launch = self.daemon_cmd
        .. " --state=" .. self.state_path
        .. " > " .. log_path .. " 2>&1 &"
    local _out, code = self.exec(launch)
    if code ~= 0 then
        return on_done(false, "Failed to start tailscaled (exit " .. tostring(code) .. ")")
    end

    UIManager:scheduleIn(3, function()
        if not self:isDaemonRunning() then
            local log_tail = self.exec("tail -5 " .. log_path)
            return on_done(false, "tailscaled exited immediately.\n\n" .. (log_tail or ""))
        end
        on_done(true, nil)
    end)
end

--- Determine the CPU architecture (confirmed armv7l on PW6).
function Tailscale:detectArch()
    local arch_raw = self.exec("uname -m")
    if arch_raw:match("aarch64") or arch_raw:match("arm64") then
        return "arm64"
    end
    return "arm"
end

--- Fetch the latest stable static build for THIS device's arch from
-- pkgs.tailscale.com's own manifest (`?mode=json`). Returns the version AND the
-- exact tarball filename together, so they're always in lockstep -- the
-- previous approach asked GitHub releases/latest for the version and then
-- guessed the filename, but the GitHub tag routinely runs ahead of the
-- published static build, producing a download 404.
-- @return string version, string tarball filename, or nil, nil, error message
function Tailscale:fetchLatestRelease()
    local ltn12 = require("ltn12")
    local json = require("json")
    local resp_body = {}
    local manifest_url = self.pkgs_manifest_url or (self.pkgs_base .. "?mode=json")
    local result, resp_code = self:_request{
        url = manifest_url,
        sink = ltn12.sink.table(resp_body),
        headers = {
            ["User-Agent"] = "KOReader-Grimmory/1.0",
        },
    }
    if not result or resp_code ~= 200 then
        return nil, nil, "Failed to fetch the Tailscale package list (HTTP "
            .. tostring(resp_code) .. ")"
    end

    local ok, manifest = pcall(json.decode, table.concat(resp_body))
    if not ok or type(manifest) ~= "table" then
        return nil, nil, "Could not parse the Tailscale package list."
    end
    local arch = self:detectArch()
    local version = manifest.Version
    local tarball = type(manifest.Tarballs) == "table" and manifest.Tarballs[arch] or nil
    if type(version) ~= "string" or type(tarball) ~= "string" then
        return nil, nil, "No Tailscale static build for arch '" .. tostring(arch) .. "'."
    end
    -- Network-controlled metadata must never become a path or shell fragment.
    if not version:match("^%d+%.%d+%.%d+$")
            or tarball ~= "tailscale_" .. version .. "_" .. arch .. ".tgz" then
        return nil, nil, "The Tailscale package list contained an unsafe package name."
    end
    return version, tarball
end

-- Validate tar metadata before extraction. Static packages contain only the
-- executables and optional systemd metadata; links and surprise payloads fail
-- closed so they cannot redirect or influence subsequent binary reads.
function Tailscale:_validateArchiveListing(listing, expected_root)
    local allowed = {
        [expected_root] = "d",
        [expected_root .. "/tailscale"] = "-",
        [expected_root .. "/tailscaled"] = "-",
        [expected_root .. "/systemd"] = "d",
        [expected_root .. "/systemd/tailscaled.service"] = "-",
        [expected_root .. "/systemd/tailscaled.defaults"] = "-",
    }
    local found_cli, found_daemon = false, false
    for line in tostring(listing):gmatch("[^\r\n]+") do
        if line:match("%S") then
            local member_type = line:sub(1, 1)
            if member_type ~= "d" and member_type ~= "-" then
                return nil, "unsafe archive member type"
            end
            local name = line:match("(%S+)%s*$")
            if not name then return nil, "unreadable archive member" end
            name = name:gsub("^%./", ""):gsub("/+$", "")
            if name == "" or name:sub(1, 1) == "/" or name:find("\\", 1, true) then
                return nil, "unsafe archive path"
            end
            for component in name:gmatch("[^/]+") do
                if component == "." or component == ".." then
                    return nil, "unsafe archive path"
                end
            end
            if allowed[name] ~= member_type then
                return nil, "unexpected archive member: " .. name
            end
            if name == expected_root .. "/tailscale" then found_cli = true end
            if name == expected_root .. "/tailscaled" then found_daemon = true end
        end
    end
    if not found_cli or not found_daemon then
        return nil, "archive does not contain both expected binaries"
    end
    return true
end

--- Installed Tailscale version (parsed from `tailscale version`), or nil if
-- not installed or unreadable.
function Tailscale:installedVersion()
    if not self:isInstalled() then return nil end
    local out, code = self.exec(self.cmd .. " version")
    if code ~= 0 then return nil end
    return out:match("(%d+%.%d+%.%d+)")
end

--- Install Tailscale from static ARM binaries.
-- Synchronous pipeline: fetch version -> download tarball -> size check ->
-- extract -> copy binaries -> chmod -> verify. Every failure path removes
-- tmp_root and returns nil + a plain error message.
-- @param notify function(msg)|nil: optional progress callback
-- @return string version on success, or nil, error message
function Tailscale:install(notify)
    notify = notify or function() end
    local ltn12 = require("ltn12")

    local version, tarball, rel_err = self:fetchLatestRelease()
    if not version then return nil, rel_err end

    logger.info("Grimmory: installing Tailscale", version, "(", tarball, ")")
    notify("Downloading Tailscale " .. version .. "…")

    -- Download URL + temp path come straight from the manifest's filename.
    local url = self.pkgs_base .. tarball
    local tmp_tgz = self.tmp_root .. "/" .. tarball
    local extract_name = tarball:gsub("%.tgz$", "")

    local function fail(msg)
        self.exec("rm -rf " .. shq(self.tmp_root))
        return nil, msg
    end

    self.exec("rm -rf " .. shq(self.tmp_root))
    local mkdir_ok, mkdir_err = self:_checkedExec("mkdir -p " .. shq(self.tmp_root))
    if not mkdir_ok then return fail(mkdir_err) end

    logger.info("Grimmory: downloading", url)

    -- Retry once on a transient failure: a dropped connection partway through
    -- the ~30 MB download used to leave a partial tarball and fail permanently.
    local dl_result, dl_code
    for attempt = 1, (self.download_attempts or 2) do
        local f, open_err = io.open(tmp_tgz, "wb")
        if not f then
            return fail("Cannot create temp file: " .. tostring(open_err))
        end
        dl_result, dl_code = self:_request{
            url = url,
            sink = ltn12.sink.file(f),  -- closes f automatically
            headers = {
                ["User-Agent"] = "KOReader-Grimmory/1.0",
            },
        }
        if dl_result and dl_code == 200 then break end
        logger.warn("Grimmory: Tailscale download attempt", attempt,
            "failed (HTTP", tostring(dl_code), ")")
        self.exec("rm -f " .. shq(tmp_tgz))  -- clear the partial before retrying
    end
    if not dl_result or dl_code ~= 200 then
        return fail("Download failed (HTTP " .. tostring(dl_code) .. "):\n" .. url)
    end

    -- Verify file size: a tiny payload is a server error page, not a tarball.
    local size_out = self.exec("wc -c < " .. shq(tmp_tgz))
    local file_size = tonumber(size_out) or 0
    if file_size < self.min_tarball_bytes then
        return fail("Downloaded file too small (" .. tostring(math.floor(file_size / 1024))
            .. " KB) - likely a server error.")
    end

    logger.info("Grimmory: downloaded", string.format("%.1f MB", file_size / 1048576))
    notify("Installing Tailscale " .. version .. "…")

    -- Verify the checksum Tailscale publishes beside every static tarball.
    local checksum_body = {}
    local checksum_result, checksum_code = self:_request{
        url = url .. ".sha256",
        sink = ltn12.sink.table(checksum_body),
        headers = { ["User-Agent"] = "KOReader-Grimmory/1.0" },
    }
    if not checksum_result or checksum_code ~= 200 then
        return fail("Could not fetch the Tailscale checksum (HTTP "
            .. tostring(checksum_code) .. ").")
    end
    local expected_hash = table.concat(checksum_body):match("^%s*([0-9a-fA-F]+)")
    if not expected_hash or #expected_hash ~= 64 then
        return fail("The Tailscale checksum response was invalid.")
    end
    local archive_hash = self.hash_file(tmp_tgz)
    if not archive_hash then
        return fail("Could not verify the Tailscale archive checksum.")
    end
    if archive_hash:lower() ~= expected_hash:lower() then
        return fail("Tailscale archive checksum mismatch.")
    end

    -- Reject links, traversal and unexpected members before extraction.
    local listing, list_code = self.exec("tar tvzf " .. shq(tmp_tgz))
    if list_code ~= 0 then
        return fail("Failed to inspect tarball:\n" .. (listing or ""))
    end
    local listing_ok, listing_err = self:_validateArchiveListing(listing, extract_name)
    if not listing_ok then return fail("Unsafe Tailscale archive: " .. listing_err) end

    local tar_out, tar_code = self.exec("cd " .. shq(self.tmp_root)
        .. " && tar xzf " .. shq(tmp_tgz))
    if tar_code ~= 0 then
        return fail("Failed to extract tarball:\n" .. (tar_out or ""))
    end

    local extract_dir = self.tmp_root .. "/" .. extract_name
    local cli_src = extract_dir .. "/tailscale"
    local daemon_src = extract_dir .. "/tailscaled"
    local cli_stage = self.tmp_root .. "/tailscale.verified"
    local daemon_stage = self.tmp_root .. "/tailscaled.verified"
    local cli_hash = self.hash_file(cli_src)
    local daemon_hash = self.hash_file(daemon_src)
    if not cli_hash or not daemon_hash then
        return fail("Extracted archive does not contain readable expected binaries.")
    end

    -- Prove both private copies before publishing either live binary.
    local copy_steps = {
        "cp " .. shq(cli_src) .. " " .. shq(cli_stage),
        "cp " .. shq(daemon_src) .. " " .. shq(daemon_stage),
    }
    for i = 1, #copy_steps do
        local ok, step_err = self:_checkedExec(copy_steps[i])
        if not ok then return fail(step_err) end
    end
    if self.hash_file(cli_stage) ~= cli_hash or self.hash_file(daemon_stage) ~= daemon_hash then
        return fail("Tailscale binary copy verification failed.")
    end

    local prepare_steps = {
        "chmod +x " .. shq(cli_stage),
        "chmod +x " .. shq(daemon_stage),
        "mkdir -p " .. shq(self.bin_dir),
    }
    for i = 1, #prepare_steps do
        local ok, step_err = self:_checkedExec(prepare_steps[i])
        if not ok then return fail(step_err) end
    end

    -- Publish the pair transactionally. Moving prior files into tmp_root
    -- preserves their exact bytes and mode, and lets every later failure put
    -- the complete old pair back (or remove both files on a fresh install).
    local cli_backup = self.tmp_root .. "/tailscale.previous"
    local daemon_backup = self.tmp_root .. "/tailscaled.previous"
    local function exists(path)
        local _out, code = self.exec("test -e " .. shq(path))
        return code == 0
    end
    local cli_existed, daemon_existed = exists(self.cmd), exists(self.daemon_cmd)
    local prior_cli_hash = cli_existed and self.hash_file(self.cmd) or nil
    local prior_daemon_hash = daemon_existed and self.hash_file(self.daemon_cmd) or nil
    if (cli_existed and not prior_cli_hash) or (daemon_existed and not prior_daemon_hash) then
        return fail("Could not verify the existing Tailscale installation before update.")
    end
    local cli_backed, daemon_backed = false, false

    local function rollback(primary_err)
        local rollback_errors = {}
        local function run(cmd)
            local ok, err = self:_checkedExec(cmd)
            if not ok then table.insert(rollback_errors, err) end
        end
        local function restore(live, backup, existed, backed, prior_hash)
            if backed then
                run("rm -f " .. shq(live))
                run("mv " .. shq(backup) .. " " .. shq(live))
            elseif not existed then
                run("rm -f " .. shq(live))
            end
            if existed and prior_hash and self.hash_file(live) ~= prior_hash then
                table.insert(rollback_errors, "restored binary checksum mismatch: " .. live)
            elseif not existed and exists(live) then
                table.insert(rollback_errors, "new binary remained after rollback: " .. live)
            end
        end
        restore(self.cmd, cli_backup, cli_existed, cli_backed, prior_cli_hash)
        restore(self.daemon_cmd, daemon_backup, daemon_existed, daemon_backed,
            prior_daemon_hash)
        if #rollback_errors > 0 then
            primary_err = primary_err .. "\nRollback incomplete:\n"
                .. table.concat(rollback_errors, "\n")
        end
        return fail(primary_err)
    end

    if cli_existed then
        local ok, err = self:_checkedExec("mv " .. shq(self.cmd) .. " " .. shq(cli_backup))
        if not ok then return rollback(err) end
        cli_backed = true
    end
    if daemon_existed then
        local ok, err = self:_checkedExec(
            "mv " .. shq(self.daemon_cmd) .. " " .. shq(daemon_backup))
        if not ok then return rollback(err) end
        daemon_backed = true
    end

    local publish_steps = {
        "mv " .. shq(cli_stage) .. " " .. shq(self.cmd),
        "mv " .. shq(daemon_stage) .. " " .. shq(self.daemon_cmd),
    }
    for i = 1, #publish_steps do
        local ok, step_err = self:_checkedExec(publish_steps[i])
        if not ok then return rollback(step_err) end
    end
    if not self:isInstalled()
            or self.hash_file(self.cmd) ~= cli_hash
            or self.hash_file(self.daemon_cmd) ~= daemon_hash then
        return rollback("Installed Tailscale binary verification failed.")
    end

    -- Clean up (best-effort; install already succeeded)
    self.exec("rm -rf " .. shq(self.tmp_root))
    logger.info("Grimmory: Tailscale", version, "installed successfully")
    return version
end

--- Run `tailscale status`.
-- @return string output, number exit code
function Tailscale:status()
    return self.exec(self.cmd .. " status")
end

--- True when `tailscale status` reports an active (logged-in, running) node.
function Tailscale:isConnected()
    local status_out, status_code = self:status()
    return status_code == 0
        and not status_out:match("Logged out")
        and not status_out:match("stopped"),
        status_out
end

--- A concise, user-facing status summary parsed from `tailscale status --json`,
-- so the UI can show "connected, this device, IP, N peers online" instead of
-- the raw `tailscale status` dump (every peer + a trailing health-check block).
-- @return table { state, hostname, ip, dns, self_online, peers_online,
--                 peers_total } on success, or nil + error message.
function Tailscale:statusSummary()
    local out, code = self.exec(self.cmd .. " status --json")
    if code ~= 0 then
        return nil, (out ~= "" and out) or "tailscale status failed"
    end
    local json = require("json")
    local ok, data = pcall(json.decode, out)
    if not ok or type(data) ~= "table" then
        return nil, "could not parse tailscale status"
    end
    local node = data.Self or {}
    local ips = node.TailscaleIPs or {}
    local peers_online, peers_total = 0, 0
    if type(data.Peer) == "table" then
        for _, peer in pairs(data.Peer) do
            peers_total = peers_total + 1
            if peer.Online then peers_online = peers_online + 1 end
        end
    end
    return {
        state = data.BackendState,   -- Running / Stopped / NeedsLogin / NoState / …
        hostname = node.HostName,
        dns = node.DNSName,
        ip = ips[1],
        self_online = node.Online,
        peers_online = peers_online,
        peers_total = peers_total,
    }
end

--- Run `tailscale up` and classify the result.
-- @return true on success;
--         false, auth_url|nil, output on failure (auth_url present when
--         the node needs browser authentication).
function Tailscale:up()
    local output, code = self.exec(
        self.cmd .. " up --timeout=30s --accept-routes")
    if code == 0 then return true end
    local auth_url = output:match("(https://login%.tailscale%.com/[^%s]+)")
    return false, auth_url, output
end

--- Run `tailscale down`.
-- @return boolean ok, string output
function Tailscale:down()
    local output, code = self.exec(self.cmd .. " down")
    return code == 0, output
end

--- Silent best-effort connect for the autostart setting: never prompts,
-- never installs, only logs. Brings the daemon up, then `tailscale up`
-- when WiFi is available (an unauthenticated node would need the QR flow,
-- which autostart deliberately avoids — the user connects manually once).
function Tailscale:autostart()
    if not self:isInstalled() then
        logger.dbg("Grimmory: Tailscale autostart skipped - not installed")
        return
    end
    if self:isDaemonRunning() then
        self:_autostartUp()
        return
    end
    self:startDaemon(function(ok, err)
        if not ok then
            logger.warn("Grimmory: Tailscale autostart daemon start failed:", err)
            return
        end
        self:_autostartUp()
    end)
end

function Tailscale:_autostartUp()
    if not self.wifi_is_on() then
        logger.dbg("Grimmory: Tailscale autostart - WiFi off, daemon started, skipping up")
        return
    end
    -- `tailscale up` blocks up to 30s; run it through run_blocking so on
    -- device it forks instead of freezing the reader. up()'s three return
    -- values are packed into a table because run_blocking carries one result.
    self.run_blocking(function()
        local ok, auth_url, output = self:up()
        return { ok = ok, auth_url = auth_url, output = output }
    end, function(res)
        if type(res) ~= "table" then return end
        if res.ok then
            logger.info("Grimmory: Tailscale autostart connected")
        elseif res.auth_url then
            logger.warn("Grimmory: Tailscale autostart needs authentication; use Connect")
        else
            logger.warn("Grimmory: Tailscale autostart up failed:", res.output)
        end
    end)
end

return Tailscale
