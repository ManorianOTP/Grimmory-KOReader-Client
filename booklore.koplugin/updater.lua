--[[
    In-app self-updater for the BookLore plugin pair.

    Lets a non-technical Kindle owner update both plugins from inside KOReader
    over WiFi/Tailscale, no scp. Source of truth is a small JSON manifest on a
    stable URL (raw.githubusercontent — no GitHub API rate limit) that names the
    latest version and, per plugin, a .tar.gz artifact URL + checksum.

    Standalone module — no KOReader widget dependencies — so the whole
    fetch -> verify -> extract -> swap -> reconcile pipeline is unit-testable off
    device (mirrors tailscale.lua). UI flows (busy InfoMessage, ConfirmBox,
    restart prompt) live in main.lua; this module returns plain values and
    non-localized error strings for main to wrap.

    Side effects are injectable via the opts table to new():
      exec(cmd)        shell runner -> trimmed output, exit code
      request(req)     LTN12-style HTTP request -> result, status code
      hash_file(path)  -> sha256 hex or nil (defaults to `sha256sum`; nil when
                         the tool is absent, so verification falls back to the
                         size floor + gzip magic-byte check)
      plugins_root, staging_dir, tmp_root, manifest_url, min_artifact_bytes,
      managed_dirs
    Defaults target the real device; tests point the paths and URL at a temp
    directory and the local HTTP fixture, so the pipeline runs the real shell
    (tar, mv, rm) end to end.

    THE SWAP (the dangerous bit). A plugin that rewrites its own live directory
    cannot reload itself mid-session — the change takes effect on the next
    KOReader start — so we never write in place. Each new tree is extracted to a
    staging dir, then atomically renamed to a validated `<dir>.new` sibling, then
    a per-plugin rename dance commits it: `mv live live.old; mv live.new live;
    rm -rf live.old`. booklore_sync is committed first and booklore (the running
    plugin) last. reconcile(), run at boot, finishes any interrupted swap: a
    `<dir>.new` only ever exists after a fully downloaded+validated tree was
    promoted, so installing it is always safe.
]]

local logger = require("logger")

local Updater = {}
Updater.__index = Updater

-- The updater lives in booklore.koplugin and must be committed LAST so the
-- running plugin's own directory is the final thing touched. Order here is the
-- swap/uninstall order: sync first, self last.
local DEFAULT_MANAGED_DIRS = { "booklore_sync.koplugin", "booklore.koplugin" }

local DEFAULTS = {
    plugins_root = "/mnt/us/koreader/plugins",
    -- Sibling of the plugin dirs so promote/swap renames stay same-filesystem
    -- (and therefore atomic). Dot-prefixed + non-.koplugin so KOReader's plugin
    -- scanner ignores it.
    staging_dir = "/mnt/us/koreader/plugins/.booklore_update",
    manifest_url = "https://raw.githubusercontent.com/ManorianOTP/BookLore-KOReader-Client/main/release/manifest.json",
    -- A plugin .tar.gz is tens of KB; < 256 bytes is an HTML error page.
    min_artifact_bytes = 256,
}

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

-- Single-quote a path for the shell (handles the repo's "BookLore KOReader Client"
-- space and anything else); '' escaping closes/reopens the quote.
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

--- Decode + shape-validate a manifest JSON string.
-- Returns the manifest table, or nil + error message.
function Updater.parseManifest(json_text)
    local json = require("json")
    local ok, manifest = pcall(json.decode, json_text)
    if not ok or type(manifest) ~= "table" then
        return nil, "could not parse update manifest"
    end
    if type(manifest.version) ~= "string" then
        return nil, "update manifest missing version"
    end
    if type(manifest.plugins) ~= "table" or #manifest.plugins == 0 then
        return nil, "update manifest missing plugins"
    end
    for i = 1, #manifest.plugins do
        local p = manifest.plugins[i]
        if type(p) ~= "table" or type(p.dir) ~= "string" or type(p.url) ~= "string" then
            return nil, "update manifest plugin entry " .. i .. " is malformed"
        end
    end
    return manifest
end

-- ─── Installed-version reads (UI-thread safe: local file reads) ───────

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

--- Installed version of one plugin dir (e.g. "booklore.koplugin"), or nil.
function Updater:getInstalledVersion(dir)
    return Updater.parseMetaVersion(
        readFile(self.plugins_root .. "/" .. dir .. "/_meta.lua"))
end

--- Canonical installed version: booklore.koplugin's (both ship in lockstep).
function Updater:installedVersion()
    return self:getInstalledVersion("booklore.koplugin")
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
        headers = { ["User-Agent"] = "KOReader-BookLore/1.0" },
    }
    if not result or code ~= 200 then
        return nil, "couldn't reach the update server (HTTP " .. tostring(code) .. ")"
    end
    return Updater.parseManifest(table.concat(body))
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

local function dirExists(self, path)
    local _out, code = self.exec("test -d " .. shq(path))
    return code == 0
end

--- Download, verify, extract, and validate every plugin artifact named by the
-- manifest into the staging dir, then atomically promote each validated tree to
-- a `<dir>.new` sibling ready for commit. Returns true, or nil + error (and
-- cleans up on every failure path).
function Updater:stageUpdate(manifest)
    local ltn12 = require("ltn12")
    local staging = self.staging_dir

    local function fail(msg)
        self.exec("rm -rf " .. shq(staging))
        for i = 1, #self.managed_dirs do
            self.exec("rm -rf " .. shq(self.plugins_root .. "/" .. self.managed_dirs[i] .. ".new"))
        end
        return nil, msg
    end

    self.exec("rm -rf " .. shq(staging))
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
            headers = { ["User-Agent"] = "KOReader-BookLore/1.0" },
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
        if p.sha256 then
            local got = self.hash_file(part)
            if got and got:lower() ~= tostring(p.sha256):lower() then
                return fail("checksum mismatch for " .. p.dir)
            end
        end

        os.rename(part, tgz)

        local _to, tar_code = self.exec("tar xzf " .. shq(tgz) .. " -C " .. shq(staging))
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
    -- with an atomic rename, so a crash never leaves a half-extracted .new.
    for i = 1, #manifest.plugins do
        local dir = manifest.plugins[i].dir
        local new_path = self.plugins_root .. "/" .. dir .. ".new"
        self.exec("rm -rf " .. shq(new_path))
        local _o, code = self.exec("mv " .. shq(staging .. "/" .. dir) .. " " .. shq(new_path))
        if code ~= 0 then return fail("could not stage " .. dir) end
    end

    self.exec("rm -rf " .. shq(staging))
    return true
end

--- Commit promoted `<dir>.new` trees with the per-plugin rename dance, in
-- managed_dirs order (sync first, self last). Returns true, or nil + error.
function Updater:commitStaged()
    for i = 1, #self.managed_dirs do
        local dir = self.managed_dirs[i]
        local live = self.plugins_root .. "/" .. dir
        local new_path = live .. ".new"
        local old_path = live .. ".old"
        if dirExists(self, new_path) then
            self.exec("rm -rf " .. shq(old_path))
            if dirExists(self, live) then
                local _o, c = self.exec("mv " .. shq(live) .. " " .. shq(old_path))
                if c ~= 0 then return nil, "could not move aside " .. dir end
            end
            local _o2, c2 = self.exec("mv " .. shq(new_path) .. " " .. shq(live))
            if c2 ~= 0 then return nil, "could not install " .. dir end
            self.exec("rm -rf " .. shq(old_path))
        end
    end
    return true
end

--- Full update in one call (run inside the async child on device): download +
-- stage + commit. Returns true + version, or nil + error.
function Updater:performUpdate(manifest)
    local ok, err = self:stageUpdate(manifest)
    if not ok then return nil, err end
    local cok, cerr = self:commitStaged()
    if not cok then return nil, cerr end
    logger.info("BookLore: updated to", manifest.version)
    return true, manifest.version
end

--- Boot-time recovery for an interrupted swap. A `<dir>.new` is always a fully
-- validated tree, so install it; otherwise restore from `<dir>.old`; finally
-- clean up any leftover `<dir>.old`. Safe to call on every start.
function Updater:reconcile()
    for i = 1, #self.managed_dirs do
        local dir = self.managed_dirs[i]
        local live = self.plugins_root .. "/" .. dir
        local new_path = live .. ".new"
        local old_path = live .. ".old"
        if dirExists(self, new_path) then
            if dirExists(self, live) then self.exec("rm -rf " .. shq(live)) end
            self.exec("mv " .. shq(new_path) .. " " .. shq(live))
            logger.info("BookLore: reconciled interrupted update for", dir)
        elseif not dirExists(self, live) and dirExists(self, old_path) then
            self.exec("mv " .. shq(old_path) .. " " .. shq(live))
            logger.warn("BookLore: rolled back interrupted update for", dir)
        end
        if dirExists(self, old_path) then self.exec("rm -rf " .. shq(old_path)) end
    end
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
