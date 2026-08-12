-- Minimal deterministic profile for KOReader v2026.03 visual tests.
--
-- These values suppress first-run UI that is unrelated to Grimmory. In
-- particular, coverbrowser creates a fresh cache database and displays a
-- three-second modal during startup, which would otherwise cover the scene.
return {
    ["color_rendering"] = false,
    ["last_migration_date"] = 20260306,
    ["plugins_disabled"] = {
        ["coverbrowser"] = true,
    },
    ["quickstart_shown_version"] = 202603000000,
}
