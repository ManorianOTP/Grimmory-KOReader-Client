local _ = require("gettext")
return {
    name = "booklore_sync",
    -- Plain string, never _()-wrapped. Kept in lockstep with
    -- booklore.koplugin/_meta.lua: the updater ships both plugins per release.
    version = "1.0.0",
    fullname = _("BookLore Sync"),
    description = _("Syncs reading progress with BookLore via kosync protocol"),
}
