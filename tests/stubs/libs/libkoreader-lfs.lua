-- Re-export luafilesystem under the path KOReader uses.
-- Resolves require("libs/libkoreader-lfs") in api.lua and main.lua.
return require("lfs")
