local _ = require("gettext")
return {
    name = "grimmory",
    -- Plain string, never _()-wrapped: this is the source of truth the
    -- in-app updater reads back to confirm a swap, not user-facing copy.
    -- Keep in lockstep with grimmory_sync.koplugin/_meta.lua per release.
    version = "2.0.0",
    fullname = _("Grimmory"),
    description = _("Grimmory library client"),
}
