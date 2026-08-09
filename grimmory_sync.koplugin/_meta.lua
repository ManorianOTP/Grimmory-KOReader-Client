local _ = require("gettext")
return {
    name = "grimmory_sync",
    -- Plain string, never _()-wrapped. Kept in lockstep with
    -- grimmory.koplugin/_meta.lua: the updater ships both plugins per release.
    version = "2.0.0",
    fullname = _("Grimmory Sync"),
    description = _("Syncs reading progress with Grimmory"),
}
