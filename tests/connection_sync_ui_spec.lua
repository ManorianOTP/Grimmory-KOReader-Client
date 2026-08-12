-- Regression for Lua's lexical scoping: `_` is the gettext function in
-- main.lua and must not be reused as an iterator/callback argument anywhere
-- inside the Connection & Sync function before translated strings are built.

describe("Connection & Sync UI source safety", function()
    it("does not shadow gettext in the menu builder or its callbacks", function()
        local path = REPO_ROOT .. "/grimmory.koplugin/main.lua"
        local file = assert(io.open(path, "r"))
        local source = file:read("*a")
        file:close()
        local section = assert(source:match(
            "function Grimmory:showConnectionSyncMenu%(%)%s*(.-)%s*end%s*%-%- WiFi"))

        assert.is_nil(section:match("for%s+_,"),
            "an underscore iterator shadows gettext and crashes translated rows")
        assert.is_nil(section:match("function%s*%(_%s*,"),
            "an underscore callback parameter shadows gettext inside callbacks")
    end)
end)
