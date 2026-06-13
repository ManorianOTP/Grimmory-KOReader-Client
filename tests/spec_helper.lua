--[[
  Common helpers imported at the top of each spec file.

  Three isolation layers:
  1. File-level: purge plugin module-level state on first load.
  2. Test-level: setup()/teardown() called from before_each/after_each.
  3. Factories: make_reader(), start_http_fixture(), virtual_clock.
]]

local spec_helper = {}

local PLUGIN_PREFIXES = {
    "booklore", "booklore_sync", "cfi", "api", "view",
    "queue", "library_cache", "downloads", "session", "tailscale",
    "logger", "luasettings", "datastorage",
    "json", "ltn12", "optmath", "gettext", "util",
}

local function purge_plugin_modules()
    for key in pairs(package.loaded) do
        for _, prefix in ipairs(PLUGIN_PREFIXES) do
            if key == prefix or key:sub(1, #prefix + 1) == prefix .. "/" or
               key:sub(1, #prefix + 1) == prefix .. "." then
                package.loaded[key] = nil
                break
            end
        end
        if key:match("^ui/") or key:match("^ffi/") or key:match("^socket") or
           key:match("^libs/") then
            package.loaded[key] = nil
        end
    end
end

purge_plugin_modules()

local function get_logger()       return require("logger")       end
local function get_virtual_clock() return require("virtual_clock") end
local function get_uimanager()    return require("ui/uimanager")  end

function spec_helper.make_reader(dir)
    local epub_reader = require("epub_reader")
    local r = epub_reader:new()
    r:open(dir)
    return r
end

function spec_helper.start_http_fixture(spec_table)
    local http_fixture = require("http_fixture")
    return http_fixture.start(spec_table)
end

spec_helper.virtual_clock = nil

function spec_helper.setup()
    purge_plugin_modules()

    local logger = get_logger()
    if logger.reset then logger.reset() end

    local vc = get_virtual_clock()
    vc.reset()
    spec_helper.virtual_clock = vc

    local uim = get_uimanager()
    uim._reset()
    uim._set_clock(vc)

    -- Create an isolated DataStorage tmp dir per test so plugin on-disk
    -- state does not leak between tests.
    local lfs = require("lfs")
    local base = os.getenv("TMPDIR") or "/tmp"
    local tmp = base .. "/spec_" .. tostring(os.time()) .. "_" .. tostring(math.random(99999))
    lfs.mkdir(tmp)
    local datastorage = require("datastorage")
    datastorage._set_dir(tmp)
    spec_helper._tmp_dir = tmp
end

function spec_helper.teardown(opts)
    opts = opts or {}

    local uim = get_uimanager()
    uim._drain_all()

    if opts.http_handle then
        opts.http_handle.stop()
    end

    if spec_helper._tmp_dir then
        local lfs = require("lfs")
        local function rmdir(path)
            for entry in lfs.dir(path) do
                if entry ~= "." and entry ~= ".." then
                    local full = path .. "/" .. entry
                    local mode = lfs.attributes(full, "mode")
                    if mode == "file" then os.remove(full)
                    elseif mode == "directory" then rmdir(full) end
                end
            end
            lfs.rmdir(path)
        end
        pcall(rmdir, spec_helper._tmp_dir)
        spec_helper._tmp_dir = nil
    end

    purge_plugin_modules()
end

return spec_helper
