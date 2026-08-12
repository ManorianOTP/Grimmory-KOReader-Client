--[[
  Lua-side helper for the Python http fixture server.

  start(spec) launches tests/support/http_server.py via io.popen,
  reads the bound port from stdout line 1, and returns a handle.
  Designed for before_each / after_each in api_spec.lua.

  To swap canned response sets mid-test, call handle.swap(new_spec);
  this stops the running server and restarts it with the new spec,
  updating the handle in-place so existing references stay valid.
]]
local http_fixture = {}

local function find_server_script()
    local dir = REPO_ROOT or "."
    return dir .. "/tests/support/http_server.py"
end

local function shq(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

function http_fixture.start(spec_table)
    local json = require("dkjson")
    local spec_json = json.encode(spec_table)

    local script = find_server_script()
    local cmd = "python3 " .. shq(script) .. " " .. shq(spec_json) .. " 2>/dev/null"
    local pipe = io.popen(cmd, "r")
    if not pipe then
        error("http_fixture: failed to launch http_server.py")
    end

    local pid_line = pipe:read("*l")
    local port_line = pipe:read("*l")
    local pid = tonumber(pid_line)
    local port = tonumber(port_line)
    if not pid or not port then
        error("http_fixture: could not read pid/port from server stdout: pid=" ..
              tostring(pid_line) .. " port=" .. tostring(port_line))
    end

    local base = "http://127.0.0.1:" .. tostring(port)

    local handle = {
        _pipe = pipe,
        _pid  = pid,
        _port = port,
        _base = base,
    }

    function handle.url(path)
        return handle._base .. (path or "")
    end

    function handle.base_url()
        return handle._base
    end

    -- Return the server-observed request ledger.  The control request itself
    -- is deliberately excluded by http_server.py, making this suitable for
    -- load-bearing zero-request and exact-count assertions.
    function handle.requests()
        local http = require("socket.http")
        local ltn12 = require("ltn12")
        local chunks = {}
        local _, code = http.request{
            url = handle.url("/__fixture__/requests"),
            method = "GET",
            sink = ltn12.sink.table(chunks),
        }
        if tonumber(code) ~= 200 then
            error("http_fixture: request ledger returned HTTP " .. tostring(code))
        end
        local decoded, _, err = require("dkjson").decode(table.concat(chunks))
        if type(decoded) ~= "table" then
            error("http_fixture: invalid request ledger: " .. tostring(err))
        end
        return decoded
    end

    -- swap(new_spec) stops the current server and restarts it with new_spec,
    -- updating handle fields in-place so existing references remain valid.
    -- Use this to change which canned responses the server serves mid-test.
    function handle.swap(new_spec)
        handle.stop()
        local new_h = http_fixture.start(new_spec)
        handle._pipe = new_h._pipe
        handle._pid  = new_h._pid
        handle._port = new_h._port
        handle._base = new_h._base
    end

    function handle.stop()
        if handle._pid then
            os.execute("kill " .. tostring(handle._pid) .. " 2>/dev/null")
            handle._pid = nil
        end
        if handle._pipe then
            pcall(function() handle._pipe:close() end)
            handle._pipe = nil
        end
    end

    return handle
end

return http_fixture
