local _ = require("gettext")
return {
    name = "booklore",
    -- Plain string, never _()-wrapped: this is the source of truth the
    -- in-app updater reads back to confirm a swap, not user-facing copy.
    -- Keep in lockstep with booklore_sync.koplugin/_meta.lua per release.
    version = "1.0.0",
    fullname = _("BookLore"),
    description = _("BookLore library client"),
}