--[[
  Helper that constructs a tmp settings directory pre-populated with
  grimmory.lua (auth settings) and grimmory_downloads.lua (download registry).

  Lets sync_spec.lua resolve the active book id without loading
  grimmory.koplugin/main.lua.
]]
local fake_settings = {}

local json = require("dkjson")
local lfs  = require("lfs")

local function tmpdir()
    local base = os.getenv("TMPDIR") or "/tmp"
    local name = base .. "/grimmory_test_" .. tostring(os.time()) .. "_" .. tostring(math.random(99999))
    lfs.mkdir(name)
    return name
end

local function write_json(path, tbl)
    local f = io.open(path, "w")
    if not f then error("cannot write: " .. path) end
    f:write(json.encode(tbl, { indent = true }))
    f:close()
end

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

function fake_settings.create(opts)
    opts = opts or {}
    local dir = tmpdir()

    write_json(dir .. "/grimmory.lua", {
        server_url = opts.server_url or "",
        token = opts.token or "",
        refresh_token = opts.refresh_token,
        token_time = opts.token_time or 0,
        username = opts.username,
        active_account = opts.active_account,
        accounts = opts.accounts,
    })

    write_json(dir .. "/grimmory_downloads.lua", opts.downloads or {})

    local handle = { dir = dir }

    function handle.cleanup()
        rmdir(dir)
    end

    return handle
end

return fake_settings
