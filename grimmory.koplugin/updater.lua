--[[
    In-app self-updater for the Grimmory plugin pair.

    Lets a non-technical Kindle owner update both plugins from inside KOReader
    over WiFi/Tailscale, no scp. Source of truth is a small JSON manifest on a
    stable URL (raw.githubusercontent — no GitHub API rate limit) that names the
    latest version and, per plugin, a .tar.gz artifact URL + SHA-256 checksum.

    Standalone module — no KOReader widget dependencies — so the whole
    fetch -> verify -> extract -> swap -> reconcile pipeline is unit-testable off
    device (mirrors tailscale.lua). UI flows (busy InfoMessage, ConfirmBox,
    restart prompt) live in main.lua; this module returns plain values and
    non-localized error strings for main to wrap.

    Side effects are injectable via the opts table to new():
      exec(cmd)        shell runner -> trimmed output, exit code
      request(req)     LTN12-style HTTP request -> result, status code
      hash_file(path)  -> sha256 hex or nil (defaults to `sha256sum`; a missing
                         or unverifiable checksum is always a hard failure)
      plugins_root, staging_dir, tmp_root, manifest_url, min_artifact_bytes,
      managed_dirs
    Defaults target the real device; tests point the paths and URL at a temp
    directory and the local HTTP fixture, so the pipeline runs the real shell
    (tar, mv, rm) end to end.

    THE SWAP (the dangerous bit). A plugin that rewrites its own live directory
    cannot reload itself mid-session — the change takes effect on the next
    KOReader start — so we never write in place. Each new tree is extracted to a
    staging dir, then renamed to a validated `<dir>.new` sibling. Only after
    BOTH trees are ready is a transaction marker published. The commit retains
    every live tree as `<dir>.old`, installs the pair, verifies both versions,
    then removes backups and the marker. grimmory_sync is committed first and
    grimmory (the running plugin) last. reconcile(), run at boot, either finishes
    a marked transaction or discards unmarked partial staging, so interruption
    cannot settle into a version-skewed pair after recovery.
]]

local logger = require("logger")

local Updater = {}
Updater.__index = Updater

-- The updater lives in grimmory.koplugin and must be committed LAST so the
-- running plugin's own directory is the final thing touched. Order here is the
-- swap/uninstall order: sync first, self last.
local DEFAULT_MANAGED_DIRS = { "grimmory_sync.koplugin", "grimmory.koplugin" }

local DEFAULTS = {
    plugins_root = "/mnt/us/koreader/plugins",
    manifest_url = "https://github.com/ManorianOTP/Grimmory-KOReader-Client/releases/latest/download/manifest.json",
    -- A plugin .tar.gz is tens of KB; < 256 bytes is an HTML error page.
    min_artifact_bytes = 256,
}

local TRANSACTION_MARKER = ".grimmory_update.ready"

--- Run a shell command, capture stdout + exit code. (Same idiom as tailscale.)
local function defaultExec(cmd)
    local handle = io.popen(cmd .. " 2>&1; echo __EXIT_$?")
    if not handle then return "", -1 end
    local raw = handle:read("*a")
    handle:close()
    local code = tonumber(raw:match("__EXIT_(%d+)%s*$")) or -1
    local output = raw:gsub("__EXIT_%d+%s*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
    return output, code
end

-- Single-quote a path for the shell (handles spaces and other special
-- characters in paths); '' escaping closes/reopens the quote.
local function shq(path)
    return "'" .. tostring(path):gsub("'", "'\\''") .. "'"
end

function Updater.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Updater)
    for k, default in pairs(DEFAULTS) do
        if opts[k] ~= nil then self[k] = opts[k] else self[k] = default end
    end
    self.managed_dirs = opts.managed_dirs or DEFAULT_MANAGED_DIRS
    -- Staging must be a SIBLING of the plugin dirs so promote/commit renames
    -- stay on one filesystem. Derive from plugins_root unless given,
    -- so a non-default deploy path still stages correctly. Dot-prefixed +
    -- non-.koplugin so KOReader's plugin scanner ignores it.
    self.staging_dir = opts.staging_dir or (self.plugins_root .. "/.grimmory_update")
    self.exec = opts.exec or defaultExec
    self.request = opts.request
    self.hash_file = opts.hash_file or function(path)
        local out, code = self.exec("sha256sum " .. shq(path))
        if code ~= 0 then return nil end
        return out:match("^(%x+)")
    end
    return self
end

-- ─── Pure helpers (no IO) ────────────────────────────────────────────

--- Compare dotted-numeric versions. Returns -1, 0, or 1 (a<b, a==b, a>b).
-- Missing trailing segments count as 0, so "1.2" == "1.2.0".
function Updater.compareVersions(a, b)
    local function parts(v)
        local t = {}
        for n in tostring(v or ""):gmatch("%d+") do t[#t + 1] = tonumber(n) end
        return t
    end
    local pa, pb = parts(a), parts(b)
    local n = math.max(#pa, #pb)
    for i = 1, n do
        local x, y = pa[i] or 0, pb[i] or 0
        if x < y then return -1 elseif x > y then return 1 end
    end
    return 0
end

--- Extract the `version = "..."` field from a plugin _meta.lua source string.
-- Regex, not load(): no code execution, and it works without resolving the
-- file's `require("gettext")`. Returns the version string or nil.
function Updater.parseMetaVersion(text)
    if type(text) ~= "string" then return nil end
    return text:match('version%s*=%s*"([^"]+)"')
        or text:match("version%s*=%s*'([^']+)'")
end

--- Shape-validate an already-decoded manifest. The two plugins are released
-- in lockstep; accepting a partial or unknown set could leave KOReader running
-- version-skewed plugins or report success without committing the staged tree.
function Updater.validateManifest(manifest, managed_dirs)
    managed_dirs = managed_dirs or DEFAULT_MANAGED_DIRS
    if type(manifest) ~= "table" then return nil, "could not parse update manifest" end
    if type(manifest.version) ~= "string" or manifest.version == "" then
        return nil, "update manifest missing version"
    end
    if type(manifest.plugins) ~= "table" or #manifest.plugins ~= #managed_dirs then
        return nil, "update manifest missing plugins"
    end

    local expected = {}
    for i = 1, #managed_dirs do expected[managed_dirs[i]] = true end
    local seen = {}
    for i = 1, #manifest.plugins do
        local p = manifest.plugins[i]
        if type(p) ~= "table" or type(p.dir) ~= "string"
                or type(p.url) ~= "string" or p.url == "" then
            return nil, "update manifest plugin entry " .. i .. " is malformed"
        end
        if p.dir:find("/", 1, true) or p.dir:find("\\", 1, true)
                or p.dir == "." or p.dir == ".." then
            return nil, "update manifest plugin directory is unsafe: " .. p.dir
        end
        if not expected[p.dir] then
            return nil, "update manifest contains unknown plugin: " .. p.dir
        end
        if seen[p.dir] then
            return nil, "update manifest contains duplicate plugin: " .. p.dir
        end
        seen[p.dir] = true
        if p.sha256 == nil or p.sha256 == "" then
            return nil, "update manifest missing checksum for " .. p.dir
        end
        if type(p.sha256) ~= "string" or #p.sha256 ~= 64
                or p.sha256:find("[^0-9a-fA-F]") then
            return nil, "update manifest has invalid checksum for " .. p.dir
        end
    end
    for i = 1, #managed_dirs do
        if not seen[managed_dirs[i]] then
            return nil, "update manifest missing plugin: " .. managed_dirs[i]
        end
    end
    return manifest
end

--- Decode + shape-validate a manifest JSON string.
-- Returns the manifest table, or nil + error message.
function Updater.parseManifest(json_text, managed_dirs)
    local json = require("json")
    local ok, manifest = pcall(json.decode, json_text)
    if not ok then return nil, "could not parse update manifest" end
    return Updater.validateManifest(manifest, managed_dirs)
end

-- ─── Installed-version reads (UI-thread safe: local file reads) ───────

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function writeFile(path, data)
    local f, err = io.open(path, "w")
    if not f then return nil, err end
    local ok, write_err = f:write(data)
    f:close()
    if not ok then return nil, write_err end
    return true
end

local function markerPath(self)
    return self.plugins_root .. "/" .. TRANSACTION_MARKER
end

local function transactionVersion(self)
    local value = readFile(markerPath(self))
    if not value then return nil end
    return value:match("^%s*([^%s]+)%s*$")
end

--- Installed version of one plugin dir (e.g. "grimmory.koplugin"), or nil.
function Updater:getInstalledVersion(dir)
    return Updater.parseMetaVersion(
        readFile(self.plugins_root .. "/" .. dir .. "/_meta.lua"))
end

--- Canonical installed version: grimmory.koplugin's (both ship in lockstep).
function Updater:installedVersion()
    return self:getInstalledVersion("grimmory.koplugin")
end

-- ─── HTTP ────────────────────────────────────────────────────────────

function Updater:_request(req)
    if self.request then return self.request(req) end
    local https = require("ssl.https")
    return https.request(req)
end

--- Fetch + parse the manifest. Returns manifest table, or nil + error.
function Updater:fetchManifest()
    local ltn12 = require("ltn12")
    local body = {}
    local result, code = self:_request{
        url = self.manifest_url,
        sink = ltn12.sink.table(body),
        headers = { ["User-Agent"] = "KOReader-Grimmory/1.0" },
    }
    if not result or code ~= 200 then
        return nil, "couldn't reach the update server (HTTP " .. tostring(code) .. ")"
    end
    return Updater.parseManifest(table.concat(body), self.managed_dirs)
end

--- High-level check: fetch manifest, compare against installed.
-- Returns { available, installed, latest, manifest }, or nil + error.
function Updater:checkForUpdate()
    local manifest, err = self:fetchManifest()
    if not manifest then return nil, err end
    local installed = self:installedVersion()
    return {
        available = installed ~= nil
            and Updater.compareVersions(manifest.version, installed) > 0,
        installed = installed,
        latest = manifest.version,
        manifest = manifest,
    }
end

-- ─── Download + stage + commit ───────────────────────────────────────

local function fileSize(self, path)
    local out = self.exec("wc -c < " .. shq(path))
    return tonumber(out) or 0
end

local function looksLikeGzip(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local magic = f:read(2)
    f:close()
    return magic == "\031\139"  -- 0x1f 0x8b
end

local function archiveHasSafeMembers(self, path, expected_root)
    -- Verbose tar output begins with the member type. Accept only directories
    -- and regular files: symlinks, hardlinks, devices, fifos and sockets are
    -- rejected before extraction.
    local listing, code = self.exec("tar tvzf " .. shq(path))
    if code ~= 0 or type(listing) ~= "string" or listing == "" then
        return false, "could not list archive"
    end
    local found = false
    for line in listing:gmatch("[^\r\n]+") do
        local member_type = line:sub(1, 1)
        if member_type ~= "d" and member_type ~= "-" then
            return false, "archive contains a link or special file"
        end
        local name = line:match("(%S+)%s*$")
        if not name then return false, "could not parse archive listing" end
        name = name:gsub("^%./", "")
        if name:sub(1, 1) == "/" or name:find("\\", 1, true) then
            return false, "archive contains an unsafe path"
        end
        local first = name:match("^([^/]+)")
        if first ~= expected_root then return false, "archive has the wrong root" end
        for part in name:gmatch("[^/]+") do
            if part == "." or part == ".." then
                return false, "archive contains an unsafe path"
            end
        end
        found = true
    end
    if not found then return false, "archive is empty" end
    return true
end

local function dirExists(self, path)
    local _out, code = self.exec("test -d " .. shq(path))
    return code == 0
end

--- Download, verify, extract, and validate every plugin artifact named by the
-- manifest into the staging dir, then promote each validated tree to
-- a `<dir>.new` sibling ready for commit. Returns true, or nil + error (and
-- cleans up on every failure path).
function Updater:stageUpdate(manifest)
    local ltn12 = require("ltn12")
    local staging = self.staging_dir

    local valid, manifest_err = Updater.validateManifest(manifest, self.managed_dirs)
    if not valid then return nil, manifest_err end

    if transactionVersion(self) then
        return nil, "an unfinished update must be recovered before staging another"
    end

    local function fail(msg)
        self.exec("rm -rf " .. shq(staging))
        for i = 1, #self.managed_dirs do
            self.exec("rm -rf " .. shq(self.plugins_root .. "/" .. self.managed_dirs[i] .. ".new"))
        end
        return nil, msg
    end

    self.exec("rm -rf " .. shq(staging))
    for i = 1, #self.managed_dirs do
        self.exec("rm -rf " .. shq(self.plugins_root .. "/"
            .. self.managed_dirs[i] .. ".new"))
    end
    local _out, mk = self.exec("mkdir -p " .. shq(staging))
    if mk ~= 0 then return fail("cannot create staging dir: " .. shq(staging)) end

    for i = 1, #manifest.plugins do
        local p = manifest.plugins[i]
        local tgz = staging .. "/" .. p.dir .. ".tar.gz"
        local part = tgz .. ".part"

        local f, open_err = io.open(part, "wb")
        if not f then return fail("cannot create temp file: " .. tostring(open_err)) end
        local dl_ok, dl_code = self:_request{
            url = p.url,
            sink = ltn12.sink.file(f),  -- closes f
            headers = { ["User-Agent"] = "KOReader-Grimmory/1.0" },
        }
        if not dl_ok or dl_code ~= 200 then
            return fail("download failed for " .. p.dir .. " (HTTP " .. tostring(dl_code) .. ")")
        end

        if fileSize(self, part) < self.min_artifact_bytes then
            return fail("downloaded " .. p.dir .. " is too small — likely a server error")
        end
        if not looksLikeGzip(part) then
            return fail("downloaded " .. p.dir .. " is not a valid archive")
        end
        local got = self.hash_file(part)
        if not got then
            return fail("could not verify checksum for " .. p.dir)
        end
        if got:lower() ~= p.sha256:lower() then
            return fail("checksum mismatch for " .. p.dir)
        end

        local renamed, rename_err = os.rename(part, tgz)
        if not renamed then
            return fail("could not finalize archive for " .. p.dir .. ": "
                .. tostring(rename_err))
        end

        local safe, archive_err = archiveHasSafeMembers(self, tgz, p.dir)
        if not safe then
            return fail("update archive for " .. p.dir .. " is unsafe: "
                .. tostring(archive_err))
        end

        -- `cd <dir> && tar xzf` rather than `tar -C`: busybox tar on Kindle does
        -- not reliably support -C. This mirrors the proven tailscale install.
        local _to, tar_code = self.exec("cd " .. shq(staging) .. " && tar xzf " .. shq(tgz))
        if tar_code ~= 0 then
            return fail("could not extract " .. p.dir)
        end

        local staged_dir = staging .. "/" .. p.dir
        local staged_version = Updater.parseMetaVersion(readFile(staged_dir .. "/_meta.lua"))
        if not staged_version then
            return fail("update archive for " .. p.dir .. " is missing _meta.lua")
        end
        if staged_version ~= manifest.version then
            return fail("update archive for " .. p.dir .. " has version " .. staged_version
                .. ", expected " .. manifest.version)
        end
        if not readFile(staged_dir .. "/main.lua") then
            return fail("update archive for " .. p.dir .. " is missing main.lua")
        end
    end

    -- Every tree downloaded + validated. Promote each to a `<dir>.new` sibling
    -- with a sibling rename, so a crash never leaves a half-extracted .new.
    for i = 1, #manifest.plugins do
        local dir = manifest.plugins[i].dir
        local new_path = self.plugins_root .. "/" .. dir .. ".new"
        self.exec("rm -rf " .. shq(new_path))
        local _o, code = self.exec("mv " .. shq(staging .. "/" .. dir) .. " " .. shq(new_path))
        if code ~= 0 then return fail("could not stage " .. dir) end
    end

    -- Publishing the marker is the transaction boundary. Before this point,
    -- reconcile discards any partial .new set. After it, every managed .new
    -- tree exists and has already passed checksum, archive and version checks.
    local marker_tmp = staging .. "/transaction.ready"
    local wrote, write_err = writeFile(marker_tmp, manifest.version .. "\n")
    if not wrote then return fail("could not write update marker: " .. tostring(write_err)) end
    local _mout, marker_code = self.exec("mv " .. shq(marker_tmp) .. " "
        .. shq(markerPath(self)))
    if marker_code ~= 0 then return fail("could not publish update marker") end

    self.exec("rm -rf " .. shq(staging))
    return true
end

--- Commit promoted `<dir>.new` trees with the per-plugin rename dance, in
-- managed_dirs order (sync first, self last). Returns true, or nil + error.
function Updater:commitStaged(expected_version)
    -- Preflight the complete pair before moving either live directory. This is
    -- what prevents a partial manifest or interrupted staging pass from being
    -- reported as a successful lockstep update.
    local target_version = transactionVersion(self)
    if not target_version then return nil, "staged update is missing its transaction marker" end
    if expected_version and target_version ~= expected_version then
        return nil, "staged update marker has version " .. target_version
            .. ", expected " .. expected_version
    end

    local previous_version
    for i = 1, #self.managed_dirs do
        local dir = self.managed_dirs[i]
        if not dirExists(self, self.plugins_root .. "/" .. dir .. ".new") then
            return nil, "staged update missing " .. dir
        end
        if self:getInstalledVersion(dir .. ".new") ~= target_version then
            return nil, "staged update has wrong version for " .. dir
        end
        local current = self:getInstalledVersion(dir)
        if not current then return nil, "installed plugin missing " .. dir end
        if previous_version and current ~= previous_version then
            return nil, "installed plugin pair is already version-skewed"
        end
        previous_version = current
    end
    local moved_old = {}
    local installed_new = {}

    local function rollback(message)
        local restored = true
        for i = #self.managed_dirs, 1, -1 do
            local dir = self.managed_dirs[i]
            local live = self.plugins_root .. "/" .. dir
            local new_path = live .. ".new"
            local old_path = live .. ".old"
            if installed_new[dir] and dirExists(self, live) then
                local _o, code = self.exec("rm -rf " .. shq(live))
                if code ~= 0 then restored = false end
            end
            if moved_old[dir] and dirExists(self, old_path) then
                local _o, code = self.exec("mv " .. shq(old_path) .. " " .. shq(live))
                if code ~= 0 then restored = false end
            end
            if dirExists(self, new_path) then
                local _o, code = self.exec("rm -rf " .. shq(new_path))
                if code ~= 0 then restored = false end
            end
        end
        if restored then
            for i = 1, #self.managed_dirs do
                if self:getInstalledVersion(self.managed_dirs[i]) ~= previous_version then
                    restored = false
                end
            end
        end
        if restored then self.exec("rm -f " .. shq(markerPath(self))) end
        return nil, message .. (restored and "; previous plugin pair restored"
            or "; automatic rollback was incomplete")
    end

    -- Retain every old tree before installing either new tree. These exact
    -- sibling backups are the rollback boundary for a failed second rename.
    for i = 1, #self.managed_dirs do
        local dir = self.managed_dirs[i]
        local live = self.plugins_root .. "/" .. dir
        local old_path = live .. ".old"
        self.exec("rm -rf " .. shq(old_path))
        if dirExists(self, live) then
            local _o, c = self.exec("mv " .. shq(live) .. " " .. shq(old_path))
            if c ~= 0 then return rollback("could not back up " .. dir) end
            moved_old[dir] = true
        end
    end

    for i = 1, #self.managed_dirs do
        local dir = self.managed_dirs[i]
        local live = self.plugins_root .. "/" .. dir
        local new_path = live .. ".new"
        local _o, c = self.exec("mv " .. shq(new_path) .. " " .. shq(live))
        if c ~= 0 then return rollback("could not install " .. dir) end
        installed_new[dir] = true
    end


    for i = 1, #self.managed_dirs do
        local dir = self.managed_dirs[i]
        if self:getInstalledVersion(dir) ~= target_version then
            return nil, "installed version verification failed for " .. dir
                .. "; recovery marker retained"
        end
    end

    -- Both live trees are now installed. Only now discard their exact backups.
    for i = 1, #self.managed_dirs do
        local dir = self.managed_dirs[i]
        local _o, remove_code = self.exec("rm -rf " .. shq(self.plugins_root .. "/"
            .. dir .. ".old"))
        if remove_code ~= 0 then
            return nil, "could not remove backup for " .. dir
                .. "; recovery marker retained"
        end
    end
    local _o, marker_code = self.exec("rm -f " .. shq(markerPath(self)))
    if marker_code ~= 0 then
        return nil, "could not clear update marker; startup recovery required"
    end
    return true
end

--- Full update in one call (run inside the async child on device): download +
-- stage + commit. Returns true + version, or nil + error.
function Updater:performUpdate(manifest)
    local ok, err = self:stageUpdate(manifest)
    if not ok then return nil, err end
    local cok, cerr = self:commitStaged(manifest.version)
    if not cok then return nil, cerr end
    for i = 1, #self.managed_dirs do
        local dir = self.managed_dirs[i]
        if self:getInstalledVersion(dir) ~= manifest.version then
            return nil, "installed version verification failed for " .. dir
        end
    end
    logger.info("Grimmory: updated to", manifest.version)
    return true, manifest.version
end

--- Boot-time recovery for an interrupted paired swap. An unmarked `.new` set
-- was interrupted before every tree was ready and is discarded. A marked set
-- is completed only when the target version exists in either live or `.new`
-- for every managed plugin. Backups and the marker are removed last.
function Updater:reconcile()
    local target_version = transactionVersion(self)

    local function rollbackBackups(reason)
        local restored_any = false
        for i = #self.managed_dirs, 1, -1 do
            local dir = self.managed_dirs[i]
            local live = self.plugins_root .. "/" .. dir
            local old_path = live .. ".old"
            if dirExists(self, old_path) then
                if dirExists(self, live) then self.exec("rm -rf " .. shq(live)) end
                local _o, code = self.exec("mv " .. shq(old_path) .. " " .. shq(live))
                if code ~= 0 then return nil, "could not restore " .. dir end
                restored_any = true
            end
        end
        for i = 1, #self.managed_dirs do
            self.exec("rm -rf " .. shq(self.plugins_root .. "/"
                .. self.managed_dirs[i] .. ".new"))
        end
        local version
        for i = 1, #self.managed_dirs do
            local current = self:getInstalledVersion(self.managed_dirs[i])
            if not current or (version and current ~= version) then
                return nil, "recovery could not restore a matching plugin pair"
            end
            version = current
        end
        if target_version then self.exec("rm -f " .. shq(markerPath(self))) end
        if restored_any then logger.warn("Grimmory: rolled back interrupted update", reason) end
        return true
    end

    if not target_version then
        return rollbackBackups("before transaction marker")
    end

    -- Every plugin must still have the target either live or ready in `.new`.
    -- If not, use the retained old pair rather than completing only one side.
    for i = 1, #self.managed_dirs do
        local dir = self.managed_dirs[i]
        local live = self.plugins_root .. "/" .. dir
        local new_path = live .. ".new"
        local old_path = live .. ".old"
        if self:getInstalledVersion(dir) ~= target_version
                and self:getInstalledVersion(dir .. ".new") ~= target_version then
            return rollbackBackups("target tree missing for " .. dir)
        end
    end

    for i = 1, #self.managed_dirs do
        local dir = self.managed_dirs[i]
        local live = self.plugins_root .. "/" .. dir
        local new_path = live .. ".new"
        local old_path = live .. ".old"
        if self:getInstalledVersion(dir) ~= target_version then
            if dirExists(self, live) then
                if not dirExists(self, old_path) then
                    local _o, backup_code = self.exec("mv " .. shq(live) .. " " .. shq(old_path))
                    if backup_code ~= 0 then return nil, "could not back up " .. dir end
                else
                    local _o, remove_code = self.exec("rm -rf " .. shq(live))
                    if remove_code ~= 0 then return nil, "could not replace " .. dir end
                end
            end
            local _o, install_code = self.exec("mv " .. shq(new_path) .. " " .. shq(live))
            if install_code ~= 0 then return nil, "could not finish installing " .. dir end
            logger.info("Grimmory: reconciled interrupted update for", dir)
        elseif dirExists(self, new_path) then
            self.exec("rm -rf " .. shq(new_path))
        end
    end

    for i = 1, #self.managed_dirs do
        if self:getInstalledVersion(self.managed_dirs[i]) ~= target_version then
            return nil, "recovery left the plugin pair version-skewed"
        end
    end
    for i = 1, #self.managed_dirs do
        local dir = self.managed_dirs[i]
        local _o, remove_code = self.exec("rm -rf " .. shq(self.plugins_root .. "/"
            .. dir .. ".old"))
        if remove_code ~= 0 then
            return nil, "could not clean recovered backup for " .. dir
        end
    end
    local _o, marker_code = self.exec("rm -f " .. shq(markerPath(self)))
    if marker_code ~= 0 then
        return nil, "could not clear recovered update marker"
    end
    return true
end

--- Remove both plugin directories (sync first, self last). When
-- opts.purge_settings, also remove every path in opts.extra_paths (settings,
-- registry, caches — supplied by main.lua, which owns the DataStorage paths).
-- The running plugin deletes its own dir; the loaded chunks stay in RAM until
-- KOReader restarts, so main prompts a restart afterward.
function Updater:uninstall(opts)
    opts = opts or {}
    for i = 1, #self.managed_dirs do
        self.exec("rm -rf " .. shq(self.plugins_root .. "/" .. self.managed_dirs[i]))
    end
    if opts.purge_settings and type(opts.extra_paths) == "table" then
        for i = 1, #opts.extra_paths do
            self.exec("rm -rf " .. shq(opts.extra_paths[i]))
        end
    end
    return true
end

return Updater
