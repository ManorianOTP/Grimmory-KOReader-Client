--[[
  Test entry point. Invoked by scripts/test.sh.

  Sets up package.path to inject stubs before any plugin require(),
  then delegates to busted.
]]

-- busted rewrites arg[0] to its binary path; use REPO_ROOT env var set
-- by scripts/test.sh instead. Fall back to cwd with validation.
local repo_root = os.getenv("REPO_ROOT")
if not repo_root or repo_root == "" then
    repo_root = "."
    local probe = io.open(repo_root .. "/tests", "r")
    if not probe then
        io.stderr:write("run.lua: cannot locate tests/ from cwd; set REPO_ROOT\n")
        os.exit(1)
    end
    probe:close()
end

package.path = table.concat({
    repo_root .. "/tests/stubs/?.lua",
    repo_root .. "/tests/stubs/?/init.lua",
    repo_root .. "/tests/support/?.lua",
    repo_root .. "/tests/?.lua",
    repo_root .. "/booklore_sync.koplugin/?.lua",
    repo_root .. "/booklore.koplugin/?.lua",
    repo_root .. "/?.koplugin/main.lua",
    repo_root .. "/tests/stubs/libs/?.lua",
    package.path,
}, ";")

REPO_ROOT = repo_root

if not arg or #arg == 0 then
    arg = arg or {}
    local function shq(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
    local find_cmd = "find " .. shq(repo_root .. "/tests") .. " -maxdepth 1 -name '*_spec.lua' | sort"
    local pipe = io.popen(find_cmd)
    if pipe then
        for line in pipe:lines() do
            table.insert(arg, line)
        end
        pipe:close()
    end
end

require("busted.runner")({ standalone = false })
