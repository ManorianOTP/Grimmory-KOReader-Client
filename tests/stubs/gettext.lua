-- Stub gettext shim: returns the identity function.
-- grimmory_sync/main.lua does: local _ = require("gettext")
-- With this stub, _(str) returns str unchanged.
return function(str) return str end
