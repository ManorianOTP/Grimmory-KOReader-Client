-- Test-only KOReader plugin. It is copied into an isolated emulator checkout by
-- the visual-test runner and is never packaged with Grimmory releases.

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local json = require("json")
local logger = require("logger")
local util = require("util")

local scenarios = require("visual_scenarios")
local Screen = Device.screen
local scenario_started = false

local VisualDriver = WidgetContainer:extend{
    name = "visual_driver",
    is_doc_only = false,
}

local function joinPath(parent, child)
    return parent:gsub("[/\\]+$", "") .. "/" .. child
end

local function restoreField(target, name, value)
    target[name] = value
end

function VisualDriver:init()
    self.scenario_name = os.getenv("GRIMMORY_VISUAL_SCENARIO")
    if not self.scenario_name or self.scenario_name == "" then
        return
    end
    -- Opening a synthetic EPUB creates a ReaderUI plugin loader in the same Lua
    -- process. The visual driver must remain the single orchestrator rather
    -- than starting the selected scenario a second time inside the reader.
    if scenario_started then return end
    scenario_started = true
    -- Never put an untrusted environment value into a path. Unknown scenario
    -- IDs still produce a useful failure result, under this fixed filename.
    self.artifact_name = scenarios[self.scenario_name]
        and self.scenario_name or "invalid-scenario"

    self.output_dir = os.getenv("GRIMMORY_VISUAL_OUTPUT")
        or joinPath(require("datastorage"):getDataDir(), "grimmory-visual")
    self.source_fingerprint = os.getenv("GRIMMORY_VISUAL_SOURCE_FINGERPRINT")
    util.makePath(self.output_dir)
    self.assertions = {}

    -- Plugins are instantiated during FileManager/ReaderUI setup. Waiting a
    -- tick lets Grimmory finish loading and also gives KOReader a first paint.
    UIManager:nextTick(function()
        self:_startWhenReady(1)
    end)
end

function VisualDriver:_pluginInstance()
    if self.ui and self.ui.grimmory then
        return self.ui.grimmory
    end
    local loader = self.ui and self.ui.pluginloader
    if loader and loader.getPluginInstance then
        return loader:getPluginInstance("grimmory")
    end
end

function VisualDriver:_assert(name, pass, expected, actual, scope)
    self.assertions[#self.assertions + 1] = {
        scope = scope or "scenario",
        name = name,
        pass = pass and true or false,
        expected = expected,
        actual = actual,
    }
end

function VisualDriver:_assertProvenance(name, pass, expected, actual)
    self:_assert(name, pass, expected, actual, "provenance")
end

function VisualDriver:_overridePending(app, pending)
    local original = rawget(app, "pendingSyncBooks")
    app.pendingSyncBooks = function()
        return pending
    end
    return function()
        restoreField(app, "pendingSyncBooks", original)
    end
end

function VisualDriver:_setNetworkState(app, online)
    local NetworkMgr = require("ui/network/manager")
    local original_is_wifi_on = NetworkMgr.isWifiOn
    local original_offline_mode = app.offline_mode
    NetworkMgr.isWifiOn = function()
        return online
    end
    app.offline_mode = not online
    return function()
        NetworkMgr.isWifiOn = original_is_wifi_on
        app.offline_mode = original_offline_mode
    end
end

function VisualDriver:_setTouchKindleProfile()
    local Menu = require("ui/widget/menu")
    local capabilities = {
        hasKeyboard = false,
        hasKeys = false,
        hasDPad = false,
        hasFewKeys = false,
        hasScreenKB = false,
        hasSymKey = false,
        isTouchDevice = true,
    }
    local originals = {}
    for name, value in pairs(capabilities) do
        originals[name] = Device[name]
        Device[name] = function()
            return value
        end
    end

    -- Menu caches this default when its module is first loaded, which happens
    -- before plugin init. Changing Device:hasKeyboard() alone is therefore too
    -- late to remove desktop Q/W/E shortcut tiles from newly-created menus.
    local original_shortcuts = Menu.is_enable_shortcut
    Menu.is_enable_shortcut = false
    return function()
        for name, original in pairs(originals) do
            Device[name] = original
        end
        Menu.is_enable_shortcut = original_shortcuts
    end
end

local function chainCleanups(...)
    local cleanups = { ... }
    return function()
        for index = #cleanups, 1, -1 do
            if cleanups[index] then cleanups[index]() end
        end
    end
end

-- Walk only numeric widget children. KOReader widgets contain parent pointers
-- and callbacks, so following arbitrary table keys would create cycles.
local function findWidget(root, predicate, seen, depth)
    if type(root) ~= "table" then return nil end
    seen = seen or {}
    depth = depth or 0
    if seen[root] or depth > 30 then return nil end
    seen[root] = true
    if predicate(root) then return root end
    for index = 1, #root do
        local found = findWidget(root[index], predicate, seen, depth + 1)
        if found then return found end
    end
end

local function findMenu(root, title)
    return findWidget(root, function(widget)
        return type(widget.item_table) == "table"
            and (title == nil or widget.title == title)
    end)
end

local function findButton(root, text)
    return findWidget(root, function(widget)
        return widget.text == text and type(widget.callback) == "function"
    end)
end

local function loadSyncPluginClass(app)
    local info = debug.getinfo(app.addToMainMenu, "S")
    local source = info and info.source or ""
    source = source:gsub("^@", "")
    local path = source:gsub("grimmory%.koplugin[/\\]main%.lua$",
        "grimmory_sync.koplugin/main.lua")
    local chunk, err = loadfile(path)
    if not chunk then error("could not load production sync plugin: " .. tostring(err)) end
    return chunk()
end

function VisualDriver:_showWhiteStage()
    local stage = InputContainer:new{
        dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() },
    }
    table.insert(stage, FrameContainer:new{
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        InputContainer:new{
            dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() },
        },
    })
    UIManager:show(stage, "full")
    return stage
end

function VisualDriver:_assertScreenRoot(name, root)
    local size = root and root.getSize and root:getSize() or {}
    self:_assert(name .. " width", size.w == Screen:getWidth(),
        Screen:getWidth(), size.w or "absent")
    self:_assert(name .. " height", size.h == Screen:getHeight(),
        Screen:getHeight(), size.h or "absent")
end

function VisualDriver:_assertScrollableReachability(name, root, require_scroll)
    local scroll = root and root.cropping_widget
    self:_assert(name .. " exposes scroll viewport", scroll ~= nil,
        "scroll viewport", scroll and "scroll viewport" or "absent")
    if not scroll then return end
    local viewport = scroll.getSize and scroll:getSize() or {}
    local inner = scroll[1]
    local inner_size = inner and inner.getSize and inner:getSize() or {}
    local max_y = math.max(0, (inner_size.h or 0) - (viewport.h or 0))
    self:_assert(name .. " scroll amount is expected",
        require_scroll and max_y > 0 or (not require_scroll and max_y >= 0),
        require_scroll and "> 0" or ">= 0", max_y)
    self:_assert(name .. " scroll viewport fits screen",
        (viewport.h or 0) > 0 and viewport.h <= Screen:getHeight(),
        "1.." .. tostring(Screen:getHeight()), viewport.h or "absent")
    if max_y > 0 and scroll.setScrolledOffset and scroll.getScrolledOffset then
        scroll:setScrolledOffset(Geom:new{ x = 0, y = max_y })
        local reached = scroll:getScrolledOffset()
        self:_assert(name .. " can reach final row", reached and reached.y >= max_y,
            ">= " .. tostring(max_y), reached and reached.y or "absent")
        scroll:setScrolledOffset(Geom:new{ x = 0, y = 0 })
    end
end

local function readJsonFile(path)
    if not path or path == "" then return nil, "path is empty" end
    local file, open_err = io.open(path, "rb")
    if not file then return nil, tostring(open_err) end
    local encoded = file:read("*a")
    file:close()
    local ok, decoded = pcall(json.decode, encoded)
    if not ok or type(decoded) ~= "table" then
        return nil, ok and "JSON root is not an object" or tostring(decoded)
    end
    return decoded
end

-- Companion runs substitute the complete scenario data before any screen is
-- built.  The old cache-only seam left scenario.books synthetic in callbacks,
-- probes and assertions, which could make a private gallery look real while
-- still exercising synthetic records.  Keep the opt-in local: the default CI
-- path never reads a private manifest.
function VisualDriver:_resolveScenarioData(scenario)
    local library_path = os.getenv("GRIMMORY_VISUAL_LIBRARY_JSON")
    if not library_path or library_path == "" then return scenario end

    local decoded, decode_err = readJsonFile(library_path)
    if not decoded then
        error("could not read GRIMMORY_VISUAL_LIBRARY_JSON: " .. tostring(decode_err))
    end
    if type(decoded.books) ~= "table" or #decoded.books == 0 then
        error("GRIMMORY_VISUAL_LIBRARY_JSON contains no books")
    end

    local resolved = {}
    for key, value in pairs(scenario) do resolved[key] = value end
    resolved.books = decoded.books
    resolved.libraries = decoded.libraries or scenario.libraries
    resolved.shelves = decoded.shelves or scenario.shelves

    local selected_id = tonumber(os.getenv("GRIMMORY_VISUAL_BOOK_ID"))
        or tonumber(decoded.books[1] and decoded.books[1].id)
    local selected_index
    for index, book in ipairs(decoded.books) do
        if tonumber(book.id) == selected_id then
            selected_index = index
            break
        end
    end
    if not selected_index then
        error("real companion book ID is absent from private library: "
            .. tostring(selected_id))
    end
    local selected = decoded.books[selected_index]
    self.data_profile = tostring(decoded.fixtureMode or "private-library")
    self.real_book_id = selected_id
    self.real_file_id = tonumber(os.getenv("GRIMMORY_VISUAL_FILE_ID"))
        or tonumber(selected.sourceFileId)
        or tonumber(selected.primaryFile and selected.primaryFile.id)

    if self.data_profile == "real-epub-companion" then
        local top_provenance = decoded.metadataProvenance or {}
        local provider = top_provenance.provider or {}
        local catalog = top_provenance.catalogStressOverlay or {}
        local selected_provenance = selected.metadataProvenance or {}
        local selected_provider = selected_provenance.provider or {}
        local selected_catalog = selected_provenance.catalogStressOverlay or {}
        local source_sha = os.getenv("GRIMMORY_VISUAL_EPUB_SHA256")
        self:_assertProvenance("real metadata comes from exact-SHA provider cache",
            provider.identityRule == "exact private EPUB SHA-256"
                and provider.providerNetworkUsed == false
                and selected_provider.sourceSha256 == source_sha
                and selected_provider.cacheKey == source_sha,
            "exact source SHA and offline cache",
            tostring(selected_provider.cacheKey))
        local evidence = selected_provider.captureEvidence or {}
        self:_assertProvenance("real metadata has visible Grimmory provider-selection evidence",
            evidence.captureMethod == "grimmory-web-metadata-selection"
                and type(evidence.provider) == "string" and evidence.provider ~= ""
                and type(evidence.providerItemId) == "string"
                and evidence.providerItemId ~= "",
            "visible provider selection and exact item",
            tostring(evidence.captureMethod))
        self:_assertProvenance("local catalogue stress state is not claimed as provider metadata",
            catalog.providerMetadata == false
                and selected_catalog.providerMetadata == false,
            false, selected_catalog.providerMetadata)
        local selected_cover = selected.cover
        self:_assertProvenance("real cover follows exact provider presence and source digest",
            (selected_provider.coverPresent == true
                and type(selected_cover) == "table"
                and selected_cover.sha256 == selected_provider.coverSourceSha256)
                or (selected_provider.coverPresent == false and selected_cover == nil),
            tostring(selected_provider.coverPresent) .. ":"
                .. tostring(selected_provider.coverSourceSha256),
            tostring(selected_cover and selected_cover.sha256))
        self.metadata_provenance = {
            cache_manifest_sha256 = provider.manifestSha256,
            cache_key = selected_provider.cacheKey,
            source_sha256 = selected_provider.sourceSha256,
            metadata_projection_sha256 = selected_provider.metadataProjectionSha256,
            capture_method = evidence.captureMethod,
            provider_network_used = selected_provider.providerNetworkUsed,
            catalog_stress_provider_metadata = selected_catalog.providerMetadata,
        }
    end

    if scenario.book_index ~= nil then resolved.book_index = selected_index end
    if scenario.local_file_id ~= nil then
        resolved.local_file_id = self.real_file_id
    end
    if scenario.expected_book_id ~= nil then
        resolved.expected_book_id = selected_id
        resolved.query = selected.title
    end
    if scenario.kind == "filter_values" and scenario.dimension == "author" then
        local authors = {}
        local seen = {}
        for _, book in ipairs(decoded.books) do
            for _, author in ipairs((book.metadata or {}).authors or {}) do
                if not seen[author] then
                    seen[author] = true
                    authors[#authors + 1] = author
                end
            end
        end
        if #authors < 2 then
            error("private library needs at least two distinct authors for filter values")
        end
        resolved.filters = { author = {
            [authors[1]] = true,
            [authors[2]] = true,
        } }
    end

    if type(scenario.pending) == "table" and #scenario.pending > 0 then
        resolved.pending = {}
        for index, pending in ipairs(scenario.pending) do
            local real_book = decoded.books[((selected_index + index - 2) % #decoded.books) + 1]
            local real_pending = {}
            for key, value in pairs(pending) do real_pending[key] = value end
            real_pending.id = real_book.id
            real_pending.title = real_book.title
            resolved.pending[index] = real_pending
        end
    end

    local required = os.getenv("GRIMMORY_VISUAL_REQUIRE_REAL_EPUB") == "1"
    if required then
        local epub_path = os.getenv("GRIMMORY_VISUAL_EPUB")
        if epub_path ~= selected.sourcePath then
            error("selected real EPUB does not match the companion library record")
        end
        local profile = selected.epubProfile or {}
        self:_assertProvenance("real companion uses a multi-document EPUB",
            tonumber(profile.contentDocuments or 0) > 1
                and tonumber(profile.spineItems or 0) > 1
                and tonumber(profile.contentBytes or 0) > 10000,
            "multiple content documents and >10KB markup",
            tostring(profile.contentDocuments or 0) .. " documents, "
                .. tostring(profile.spineItems or 0) .. " spine items, "
                .. tostring(profile.contentBytes or 0) .. " markup bytes")
    end
    return resolved
end

-- Install the same normalized records used by the local fixture server while
-- replacing every I/O boundary. Production screen builders, menus and button
-- callbacks remain untouched.
function VisualDriver:_installFixtureState(app, scenario)
    local fields = {
        "cached_books", "cached_libraries", "cached_shelves", "shelf_books",
        "unshelved_books", "view_state", "offline_mode", "server_url",
        "username", "download_dir", "cover_cache_dir", "cachedCoverPath", "getLocalPath",
        "_flushDeferredCalls", "_cover_attempted", "_deferred_calls",
        "_detail_recs", "_detail_recs_id", "_detail_extras_id",
    }
    local originals = {}
    for _, name in ipairs(fields) do originals[name] = rawget(app, name) end
    local session_logged_in = app.session and rawget(app.session, "isLoggedIn")

    -- Private companions are decoded from the ignored manifest, while the
    -- production online/cache paths normalize every Book DTO first. Exercise
    -- that same boundary here instead of letting KOReader's callable JSON-null
    -- sentinel leak into views through a test-only shortcut.
    app.cached_books = scenario.books or {}
    if self.data_profile == "real-epub-companion" then
        app.cached_books = {}
        for index, book in ipairs(scenario.books or {}) do
            app.cached_books[index] = require("api").normalizeBook(book)
        end
    end
    app.cached_libraries = scenario.libraries or {}
    app.cached_shelves = scenario.shelves or {}
    app.view_state = {
        sort = scenario.sort or { key = "title", dir = "asc" },
        filters = scenario.filters or {},
        combine = scenario.combine or "AND",
    }
    app.offline_mode = scenario.offline == true
    app.server_url = os.getenv("GRIMMORY_VISUAL_SERVER_URL")
        or "http://grimmory.visual.test:6060"
    app.username = "visual-reader"
    app.download_dir = "/mnt/us/documents/Grimmory Visual Tests"
    app.cover_cache_dir = self.output_dir
    app._cover_attempted = {}
    app._deferred_calls = {}
    app._detail_recs = { scenario.books and scenario.books[4], scenario.books and scenario.books[5] }
    app._detail_recs_id = scenario.books and scenario.books[1] and scenario.books[1].id
    app._detail_extras_id = scenario.books and scenario.books[1] and scenario.books[1].id
    local cover_paths = {}
    local cover_specs = {
        { bg = "#18253a", accent = "#b9cbe8", mark = "I" },
        { bg = "#3a2218", accent = "#ead0b9", mark = "II" },
        { bg = "#1f3828", accent = "#c5e5cc", mark = "III" },
    }
    for index, spec in ipairs(cover_specs) do
        local path = joinPath(self.output_dir, "synthetic-cover-" .. tostring(index) .. ".svg")
        local file = io.open(path, "wb")
        if file then
            file:write(string.format([[<svg xmlns="http://www.w3.org/2000/svg" width="600" height="840" viewBox="0 0 600 840">
<rect width="600" height="840" fill="%s"/><rect x="38" y="38" width="524" height="764" rx="12" fill="none" stroke="%s" stroke-width="5"/>
<circle cx="300" cy="300" r="132" fill="none" stroke="%s" stroke-width="10"/><path d="M180 510H420M220 560H380M250 610H350" stroke="%s" stroke-width="12"/>
<text x="300" y="330" fill="%s" font-family="sans-serif" font-size="70" text-anchor="middle">%s</text>
<text x="300" y="720" fill="%s" font-family="sans-serif" font-size="32" letter-spacing="8" text-anchor="middle">VISUAL TEST</text></svg>]],
                spec.bg, spec.accent, spec.accent, spec.accent,
                spec.accent, spec.mark, spec.accent))
            file:close()
            cover_paths[index] = path
        end
    end
    local external_cover_map
    local cover_map_path = os.getenv("GRIMMORY_VISUAL_COVERS_JSON")
        or os.getenv("GRIMMORY_VISUAL_COVER_MAP")
    if cover_map_path and cover_map_path ~= "" then
        local map_file = io.open(cover_map_path, "rb")
        if map_file then
            local encoded = map_file:read("*a")
            map_file:close()
            local ok, decoded = pcall(json.decode, encoded)
            if ok and type(decoded) == "table" then external_cover_map = decoded end
        end
    end
    app.cachedCoverPath = function(_, book)
        -- Keep one deliberate synthetic miss to preserve the production
        -- placeholder path. A real companion must honor the exact provider
        -- cover-presence contract instead of borrowing that fictional absence.
        if not book or (self.data_profile ~= "real-epub-companion"
                and book.id == 1007) then return nil end
        if external_cover_map then
            local mapped = external_cover_map[tostring(book.id)] or external_cover_map[book.id]
            if type(mapped) == "string" and mapped ~= "" then return mapped end
        end
        if type(book.cover) == "table" and type(book.cover.path) == "string"
                and book.cover.path ~= "" then
            return book.cover.path
        end
        if #cover_paths == 0 then return nil end
        return cover_paths[((book.id or 1) % #cover_paths) + 1]
    end
    app._flushDeferredCalls = function() end
    app.getLocalPath = function(_, _book, file)
        local id = file and file.id
        if scenario.local_file_id and id == scenario.local_file_id then
            return "/mnt/us/documents/Grimmory Visual Tests/downloaded-fixture.epub"
        end
        return nil
    end
    if app.session then
        app.session.isLoggedIn = function() return scenario.offline ~= true end
    end
    app:indexShelves(app.cached_books)

    return function()
        for _, name in ipairs(fields) do restoreField(app, name, originals[name]) end
        if app.session then restoreField(app.session, "isLoggedIn", session_logged_in) end
        for _, path in ipairs(cover_paths) do os.remove(path) end
    end
end

function VisualDriver:_withFixtureStage(app, scenario)
    return self:_showWhiteStage(), self:_installFixtureState(app, scenario)
end

function VisualDriver:_showWifi(app, scenario)
    local restore_pending = self:_overridePending(app, scenario.pending)
    local restore_network = self:_setNetworkState(app, true)
    local top_bar = app:buildTopBar(function() end, function() end, function() end)
    local root = InputContainer:new{
        dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() },
    }
    table.insert(root, FrameContainer:new{
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "left",
            top_bar,
        },
    })
    UIManager:show(root, "full")

    local button = app.wifi_button
    local badge = button and button.badge
    self:_assert("Wi-Fi tap gesture registered",
        button and button.ges_events and button.ges_events.Tap ~= nil,
        "registered", button and button.ges_events and button.ges_events.Tap
            and "registered" or (button and "missing" or "absent button"))
    self:_assert("Wi-Fi tap callback registered",
        button and type(button.onTap) == "function",
        "function", button and type(button.onTap) or "absent button")
    self:_assert("badge text", button and button.badge_text == scenario.badge_text,
        scenario.badge_text or "absent", button and button.badge_text or "absent")
    self:_assert("badge presence", (badge ~= nil) == (scenario.badge_text ~= nil),
        scenario.badge_text and "present" or "absent", badge and "present" or "absent")
    if button then
        local group_size = button.icon_group:getSize()
        self:_assert("icon group width is fixed", group_size.w == button.icon_size,
            button.icon_size, group_size.w)
        self:_assert("icon group height is fixed", group_size.h == button.icon_size,
            button.icon_size, group_size.h)
    end
    if badge and button then
        local badge_size = badge:getSize()
        local offset = badge.overlap_offset or {}
        local expected_diameter = math.max(1, math.floor(button.icon_size * 0.52 + 0.5))
        self:_assert("badge is circular", badge_size.w == expected_diameter
                and badge_size.h == expected_diameter
                and badge.radius == math.floor(expected_diameter / 2),
            expected_diameter .. "x" .. expected_diameter,
            tostring(badge_size.w) .. "x" .. tostring(badge_size.h))
        self:_assert("badge is at icon top right",
            offset[1] == button.icon_size - expected_diameter and offset[2] == 0,
            tostring(button.icon_size - expected_diameter) .. ",0",
            tostring(offset[1]) .. "," .. tostring(offset[2]))
    end

    return root, function()
        restore_pending()
        restore_network()
    end
end

function VisualDriver:_showConnection(app, scenario)
    local restore_pending = self:_overridePending(app, scenario.pending)
    local restore_network = self:_setNetworkState(app, scenario.online ~= false)
    local original_wifi_button = app.wifi_button
    -- A real Grimmory top bar supplies both the button under test and a stable
    -- full-screen background. The latter matters when a menu callback closes
    -- the menu before showing a modal (the error scenario): FileManager state
    -- must never leak into the reference image.
    local top_bar = app:buildTopBar(function() end, function() end, function() end)
    local stage = InputContainer:new{
        dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() },
    }
    table.insert(stage, FrameContainer:new{
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "left",
            top_bar,
        },
    })
    UIManager:show(stage, "full")
    local button = app.wifi_button
    self:_assert("Wi-Fi tap gesture registered",
        button.ges_events and button.ges_events.Tap ~= nil,
        "registered", button.ges_events and button.ges_events.Tap
            and "registered" or "missing")
    self:_assert("Wi-Fi tap callback registered", type(button.onTap) == "function",
        "function", type(button.onTap))
    local tap_handled = button:onTap()
    self:_assert("Wi-Fi tap opens connection menu", tap_handled == true,
        true, tap_handled)

    local root = app.connection_sync_widget
    local menu = root and root[1]
    self:_assert("connection menu shown", root ~= nil, "shown", root and "shown" or "absent")
    self:_assert("connection menu callback registered",
        menu and type(menu.onMenuChoice) == "function",
        "function", menu and type(menu.onMenuChoice) or "absent menu")
    self:_assert("desktop keyboard shortcuts suppressed",
        menu and menu.is_enable_shortcut == false,
        false, menu and tostring(menu.is_enable_shortcut) or "absent menu")
    self:_assert("connection item count",
        menu and #menu.item_table == 5 + #scenario.pending,
        5 + #scenario.pending, menu and #menu.item_table or 0)
    local expected_connection_text = scenario.online == false
        and "Try to go online (turn Wi-Fi on)" or "Wi-Fi is on — test Grimmory"
    self:_assert("connection action reflects Wi-Fi state",
        menu and menu.item_table[1].text == expected_connection_text,
        expected_connection_text,
        menu and menu.item_table[1].text or "absent")
    if menu then
        for index = 1, #scenario.pending do
            local item = menu.item_table[5 + index]
            self:_assert("pending title " .. tostring(index),
                item and item.text:find(scenario.pending[index].title, 1, true) ~= nil,
                scenario.pending[index].title, item and item.text or "absent")
            local expected_progress = string.format("Device %.1f%% · Server %.1f%%",
                scenario.pending[index].device_percentage,
                scenario.pending[index].server_percentage)
            self:_assert("pending progress labels " .. tostring(index),
                item and item.mandatory == expected_progress,
                expected_progress, item and item.mandatory or "absent")
        end
    end

    -- Preserve the offline menu as the visual reference, then select its real
    -- first item immediately after the PNG is captured. A spy prevents any
    -- network work while proving the production menu callback invokes the
    -- connection action exactly once.
    local original_try_go_online = rawget(app, "tryGoOnline")
    local connect_calls = 0
    local after_capture
    if scenario.exercise_connect then
        app.tryGoOnline = function()
            connect_calls = connect_calls + 1
        end
        after_capture = function()
            menu:onMenuChoice(menu.item_table[1])
            self:_assert("offline connection action invoked once",
                connect_calls == 1, 1, connect_calls)
        end
    end

    return root, function()
        if UIManager:isWidgetShown(stage) then UIManager:close(stage) end
        app.wifi_button = original_wifi_button
        if scenario.exercise_connect then
            app.tryGoOnline = original_try_go_online
        end
        if button.free then button:free() end
        restore_pending()
        restore_network()
    end, after_capture
end

function VisualDriver:_showConnectionError(app, scenario)
    local root, cleanup = self:_showConnection(app, scenario)
    local original_service = app.ui.grimmory_sync
    local sync_called = false
    app.ui.grimmory_sync = {
        syncAllNow = function(_, done)
            sync_called = true
            done(false, scenario.error)
        end,
    }
    local menu = root and root[1]
    if menu and menu.onMenuChoice then
        menu:onMenuChoice(menu.item_table[2])
    end
    local top = UIManager:getTopmostVisibleWidget()
    self:_assert("sync menu choice calls sync service", sync_called,
        true, sync_called)
    self:_assert("sync error shown", top ~= nil and top ~= root,
        "error dialog above menu", top and "dialog shown" or "absent")
    return root, function()
        app.ui.grimmory_sync = original_service
        cleanup()
    end
end

function VisualDriver:_showConnectionDetail(app, scenario)
    local root, cleanup = self:_showConnection(app, scenario)
    local menu = root and root[1]
    local item = menu and menu.item_table[6]
    if menu and item then
        menu:onMenuChoice(item)
    end
    local detail = UIManager:getTopmostVisibleWidget()
    local text = detail and detail.text or ""
    local book = scenario.pending[1]
    self:_assert("pending detail shown", detail ~= nil and detail ~= root,
        "detail above connection menu", detail and "detail shown" or "absent")
    self:_assert("pending detail title", text:find(book.title, 1, true) ~= nil,
        book.title, text)
    self:_assert("pending detail device position",
        text:find("Device position: " .. book.device_position, 1, true) ~= nil,
        book.device_position, text)
    self:_assert("pending detail server position",
        text:find("Last known server position: " .. book.server_position, 1, true) ~= nil,
        book.server_position, text)
    return root, cleanup
end

function VisualDriver:_showDashboard(app, scenario)
    local stage, restore_state = self:_withFixtureStage(app, scenario)
    local ImageWidget = require("ui/widget/imagewidget")
    local probe_path = app:cachedCoverPath(scenario.books[1])
    local image_ok, image_or_err = pcall(ImageWidget.new, ImageWidget, {
        file = probe_path, width = 120, height = 168, scale_factor = 0,
    })
    self:_assert("synthetic cover decodes in production ImageWidget",
        image_ok and image_or_err ~= nil,
        "decoded", image_ok and (image_or_err and "decoded" or "nil widget")
            or tostring(image_or_err))
    if image_ok and image_or_err and image_or_err.free then image_or_err:free() end
    local original_build_card = rawget(app, "buildCoverCard")
        or app.buildCoverCard
    local original_show_detail = rawget(app, "showBookDetail")
    local cards = {}
    app.buildCoverCard = function(this, book, width, callback)
        local card, height = original_build_card(this, book, width, callback)
        cards[#cards + 1] = card
        return card, height
    end
    app:showDashboard()
    local root = app.dashboard_widget
    self:_assert("dashboard shown", root ~= nil, "shown", root and "shown" or "absent")
    self:_assertScreenRoot("dashboard", root)
    self:_assert("dashboard cover cards", #cards == 6, 6, #cards)
    for index, card in ipairs(cards) do
        local content = card and card[1]
        self:_assert("dashboard card " .. index .. " contains its full laid-out height",
            card and content and card.dimen.h >= content:getSize().h,
            content and content:getSize().h or "content",
            card and card.dimen and card.dimen.h or "absent")
    end
    self:_assert("dashboard exercises real image-cover branch",
        app:cachedCoverPath(scenario.books[1]) ~= nil,
        "image path", app:cachedCoverPath(scenario.books[1]) or "absent")
    if self.data_profile == "real-epub-companion" then
        for index, book in ipairs(scenario.books) do
            local provider = ((book.metadataProvenance or {}).provider or {})
            local cover_path = app:cachedCoverPath(book)
            self:_assert("dashboard real provider cover contract " .. index,
                (provider.coverPresent == true and cover_path ~= nil)
                    or (provider.coverPresent == false and cover_path == nil),
                tostring(provider.coverPresent),
                cover_path and "present" or "absent")
        end
    else
        self:_assert("dashboard preserves missing-cover fallback",
            app:cachedCoverPath(scenario.books[7]) == nil,
            "absent", app:cachedCoverPath(scenario.books[7]) or "absent")
    end
    local first_cover_path = app:cachedCoverPath(scenario.books[1])
    local rendered_image = cards[1] and findWidget(cards[1], function(widget)
        return widget.file == first_cover_path
    end)
    self:_assert("dashboard card contains decoded image widget",
        rendered_image ~= nil, "image widget", rendered_image and "image widget" or "absent")
    local top_search = findWidget(root, function(widget)
        return widget.text == "Title, Author, Series, or ISBN…"
    end)
    local top_wifi = findWidget(root, function(widget) return widget == app.wifi_button end)
    self:_assert("dashboard fixed top-bar search remains in widget tree",
        top_search ~= nil, "search control", top_search and "search control" or "absent")
    self:_assert("dashboard fixed top-bar Wi-Fi remains in widget tree",
        top_wifi ~= nil, "Wi-Fi control", top_wifi and "Wi-Fi control" or "absent")
    self:_assertScrollableReachability("dashboard", root,
        Screen:getWidth() > Screen:getHeight())

    local detail_calls = 0
    app.showBookDetail = function(_, book)
        if book == scenario.books[1] then detail_calls = detail_calls + 1 end
    end
    local after_capture = function()
        if cards[1] and cards[1].onTap then cards[1]:onTap() end
        self:_assert("dashboard card navigates to detail once", detail_calls == 1, 1, detail_calls)
        self:_assert("dashboard installs detail back route",
            type(app._back_from_detail) == "function", "function", type(app._back_from_detail))
    end
    return root, function()
        restoreField(app, "buildCoverCard", original_build_card)
        restoreField(app, "showBookDetail", original_show_detail)
        restore_state()
        if UIManager:isWidgetShown(stage) then UIManager:close(stage) end
    end, after_capture
end

function VisualDriver:_showSidebar(app, scenario)
    local stage, restore_state = self:_withFixtureStage(app, scenario)
    local original_show_list = rawget(app, "showBookList")
    local final_shelf = scenario.shelves and scenario.shelves[#scenario.shelves]
    local final_shelf_name = final_shelf
        and (final_shelf.name or final_shelf.shelfName)
    local lower_shelf_calls = 0
    app.showBookList = function(_, _, title)
        if title == final_shelf_name then
            lower_shelf_calls = lower_shelf_calls + 1
        end
    end
    app:showSidebar()
    local root = app.sidebar_widget
    self:_assert("sidebar shown", root ~= nil, "shown", root and "shown" or "absent")
    self:_assertScreenRoot("sidebar", root)
    self:_assert("sidebar tap gesture registered",
        root and root.ges_events and root.ges_events.TapSidebar ~= nil,
        "registered", root and root.ges_events and root.ges_events.TapSidebar and "registered" or "missing")
    self:_assert("sidebar tap callback registered", root and type(root.onTapSidebar) == "function",
        "function", root and type(root.onTapSidebar) or "absent")
    -- The deterministic fixture deliberately overflows. A real library may
    -- genuinely fit, in which case its useful companion assertion is that all
    -- rows fit cleanly rather than pretending a scrollbar must exist.
    local require_scroll = self.data_profile ~= "real-epub-companion"
    self:_assertScrollableReachability("sidebar", root, require_scroll)
    local after_capture = function()
        local scroll = root.cropping_widget
        local viewport = scroll:getSize()
        local inner = scroll[1]:getSize()
        local max_y = math.max(0, inner.h - viewport.h)
        scroll:setScrolledOffset(Geom:new{ x = 0, y = max_y })
        if max_y == 0 then
            self:_assert("real sidebar content fits without forced scrolling",
                not require_scroll, true, not require_scroll)
            return
        end
        local original_schedule = UIManager.scheduleIn
        UIManager.scheduleIn = function(_, _delay, callback) callback() end
        local tap_ok, handled = pcall(root.onTapSidebar, root, nil,
            { pos = { x = 10, y = viewport.h - 2 } })
        UIManager.scheduleIn = original_schedule
        if not tap_ok then error(handled) end
        self:_assert("scrolled sidebar tap is handled", handled == true, true, handled)
        self:_assert("scrolled sidebar tap reaches final shelf once",
            lower_shelf_calls == 1, 1, lower_shelf_calls)
    end
    return root, function()
        restoreField(app, "showBookList", original_show_list)
        restore_state()
        if UIManager:isWidgetShown(stage) then UIManager:close(stage) end
    end, after_capture
end

function VisualDriver:_showBookList(app, scenario)
    local stage, restore_state = self:_withFixtureStage(app, scenario)
    local original_show_detail = rawget(app, "showBookDetail")
    local detail_calls = 0
    app.showBookDetail = function(_, book)
        if book == scenario.books[1] then detail_calls = detail_calls + 1 end
    end
    app:showBookList(scenario.books, scenario.title or "All Books", function() end)
    local root = app.book_list_widget
    local menu = findMenu(root)
    local active_filters = scenario.filters and 1 or 0
    local expected_items = active_filters > 0 and 2 or (#scenario.books + 1)
    self:_assert("book list shown", root ~= nil and menu ~= nil,
        "menu shown", menu and "menu shown" or "absent")
    self:_assertScreenRoot("book list", root)
    self:_assert("book list item count", menu and #menu.item_table == expected_items,
        expected_items, menu and #menu.item_table or 0)
    self:_assert("book list reserves right status column",
        menu and menu.single_line == true and menu.align_baselines == true,
        "single-line measured row", menu and tostring(menu.single_line) or "absent")
    if active_filters > 0 then
        self:_assert("filtered empty state",
            menu.item_table[2].text == "No books match these filters.",
            "No books match these filters.", menu.item_table[2].text)
    else
        local longest_book
        local longest_title = ""
        for _, book in ipairs(scenario.books) do
            local title = tostring((book.metadata or {}).title or book.title or "")
            if #title > #longest_title then
                longest_book = book
                longest_title = title
            end
        end
        local long_item
        for _, item in ipairs(menu.item_table) do
            if item.book_data == longest_book then long_item = item break end
        end
        self:_assert("longest title preserved in book model",
            long_item and long_item.book_data.metadata.title
                == longest_title,
            longest_title,
            long_item and long_item.book_data.metadata.title or "absent")
        local rendered_title = long_item and long_item.text
        local is_exact = rendered_title == longest_title
        local is_ellipsized = rendered_title ~= nil
            and rendered_title ~= longest_title
            and rendered_title:sub(-3) == "…"
        self:_assert("longest list title fits or is ellipsized before status",
            is_exact or is_ellipsized,
            "exact or ellipsized", rendered_title or "absent")
    end
    local after_capture
    if active_filters == 0 then
        after_capture = function()
            local target
            for _, item in ipairs(menu.item_table) do
                if item.book_data == scenario.books[1] then target = item break end
            end
            menu:onMenuChoice(target)
            self:_assert("book row navigates to detail once", detail_calls == 1, 1, detail_calls)
        end
    end
    return root, function()
        restoreField(app, "showBookDetail", original_show_detail)
        restore_state()
        if UIManager:isWidgetShown(stage) then UIManager:close(stage) end
    end, after_capture
end

function VisualDriver:_showViewOptions(app, scenario)
    local stage, restore_state = self:_withFixtureStage(app, scenario)
    local original_show_sort = rawget(app, "showSortMenu")
    local sort_calls = 0
    app.showSortMenu = function() sort_calls = sort_calls + 1 end
    app:showViewOptions(scenario.books, "All Books", function() end)
    local root = app.view_options_widget
    local menu = findMenu(root)
    self:_assert("view options shown", menu ~= nil, "shown", menu and "shown" or "absent")
    self:_assert("view options has sort and filter", menu and #menu.item_table == 2,
        2, menu and #menu.item_table or 0)
    local after_capture = function()
        menu.item_table[1].callback()
        self:_assert("sort option callback invoked once", sort_calls == 1, 1, sort_calls)
    end
    return root, function()
        restoreField(app, "showSortMenu", original_show_sort)
        restore_state()
        if UIManager:isWidgetShown(stage) then UIManager:close(stage) end
    end, after_capture
end

function VisualDriver:_showSortMenu(app, scenario)
    local stage, restore_state = self:_withFixtureStage(app, scenario)
    local original_show_list = rawget(app, "showBookList")
    local list_calls = 0
    app.showBookList = function() list_calls = list_calls + 1 end
    app:showSortMenu(scenario.books, "All Books", function() end)
    local root = app.sort_menu_widget
    local menu = findMenu(root)
    self:_assert("sort menu shown", menu ~= nil, "shown", menu and "shown" or "absent")
    self:_assert("all production sorts represented", menu and #menu.item_table >= 19,
        ">= 19", menu and #menu.item_table or 0)
    local active
    if menu then
        for _, item in ipairs(menu.item_table) do
            if item.sort_key == scenario.sort.key then active = item break end
        end
    end
    self:_assert("active sort is marked", active and active.text:find("●", 1, true) == 1,
        "marked", active and active.text or "absent")
    local after_capture = function()
        menu:onMenuChoice(active)
        self:_assert("active sort toggles direction", app.view_state.sort.dir == "asc",
            "asc", app.view_state.sort.dir)
        self:_assert("sort navigation invoked once", list_calls == 1, 1, list_calls)
    end
    return root, function()
        restoreField(app, "showBookList", original_show_list)
        restore_state()
        if UIManager:isWidgetShown(stage) then UIManager:close(stage) end
    end, after_capture
end

function VisualDriver:_showFilterMenu(app, scenario)
    local stage, restore_state = self:_withFixtureStage(app, scenario)
    app:showFilterMenu(scenario.books, "All Books", function() end)
    local root = app.filter_menu_widget
    local menu = findMenu(root)
    self:_assert("filter menu shown", menu ~= nil, "shown", menu and "shown" or "absent")
    self:_assert("filter combine row pinned", menu and menu.item_table[1].is_combine == true,
        true, menu and menu.item_table[1].is_combine or "absent")
    self:_assert("clear filters row visible", menu and menu.item_table[2].is_clear_all == true,
        true, menu and menu.item_table[2].is_clear_all or "absent")
    local after_capture = function()
        menu:onMenuChoice(menu.item_table[1])
        self:_assert("combine callback toggles to OR", app.view_state.combine == "OR",
            "OR", app.view_state.combine)
    end
    return root, function()
        restore_state()
        if UIManager:isWidgetShown(stage) then UIManager:close(stage) end
    end, after_capture
end

function VisualDriver:_showFilterValues(app, scenario)
    local stage, restore_state = self:_withFixtureStage(app, scenario)
    app:showFilterValues(scenario.books, "All Books", function() end, scenario.dimension)
    local root = app.filter_values_widget
    local menu = findMenu(root)
    self:_assert("filter values shown", menu ~= nil, "shown", menu and "shown" or "absent")
    self:_assert("filter values has pinned actions", menu and menu.item_table[1].is_select_all
        and menu.item_table[2].is_clear_dim, true, menu and "incorrect" or "absent")
    local selected = {}
    local configured = scenario.filters and scenario.filters[scenario.dimension] or {}
    if menu then
        for _, item in ipairs(menu.item_table) do
            if configured[item.value_key] then
                selected[#selected + 1] = item
            end
        end
    end
    self:_assert("all configured filter values are rendered",
        #selected == 2, 2, #selected)
    for index, item in ipairs(selected) do
        self:_assert("selected filter value " .. tostring(index) .. " is checked",
            item.text:find("☑", 1, true) == 1,
            "checked", item.text)
    end
    local after_capture = function()
        menu:onMenuChoice(selected[1])
        local cleared_key = selected[1] and selected[1].value_key
        self:_assert("filter value callback clears selected value",
            cleared_key and not app.view_state.filters[scenario.dimension][cleared_key],
            "cleared", cleared_key and tostring(
                app.view_state.filters[scenario.dimension][cleared_key]) or "absent")
    end
    return root, function()
        restore_state()
        if UIManager:isWidgetShown(stage) then UIManager:close(stage) end
    end, after_capture
end

function VisualDriver:_showSearchResults(app, scenario)
    local stage, restore_state = self:_withFixtureStage(app, scenario)
    local inherited_show_list = app.showBookList
    local original_show_list = rawget(app, "showBookList")
    local captured_books, captured_title
    app.showBookList = function(this, books, title, back_callback)
        captured_books = books
        captured_title = title
        return inherited_show_list(this, books, title, back_callback)
    end

    app:showSearchWithin(scenario.books, scenario.parent_title, function() end)
    local dialog = app.search_dialog
    dialog:setInputText(scenario.query)
    local search = findButton(dialog, "Search")
    self:_assert("search submit callback registered", search ~= nil,
        "registered", search and "registered" or "absent")
    search.callback()

    local root = app.book_list_widget
    local menu = findMenu(root)
    self:_assert("search opens filtered result list", root ~= nil and menu ~= nil,
        "filtered list", menu and "filtered list" or "absent")
    self:_assertScreenRoot("search result list", root)
    self:_assert("search result reserves right status column",
        menu and menu.single_line == true and menu.align_baselines == true,
        "single-line measured row", menu and tostring(menu.single_line) or "absent")
    self:_assert("search result model has exactly one match",
        captured_books and #captured_books == 1,
        1, captured_books and #captured_books or 0)
    self:_assert("search result is the matching fixture",
        captured_books and captured_books[1]
            and captured_books[1].id == scenario.expected_book_id,
        scenario.expected_book_id,
        captured_books and captured_books[1] and captured_books[1].id or "absent")
    self:_assert("nonmatching books are excluded",
        captured_books and #captured_books < #scenario.books,
        "fewer than " .. tostring(#scenario.books),
        captured_books and #captured_books or "absent")
    local expected_title = "Search: " .. scenario.query
    self:_assert("long search query is preserved in result title",
        captured_title == expected_title,
        expected_title, captured_title or "absent")
    local result_item
    if menu then
        for _, item in ipairs(menu.item_table) do
            if item.book_data and item.book_data.id == scenario.expected_book_id then
                result_item = item
                break
            end
        end
    end
    self:_assert("filtered result row is rendered", result_item ~= nil,
        scenario.expected_book_id, result_item and result_item.book_data.id or "absent")
    if self.data_profile == "real-epub-companion" then
        self:_assert("real metadata search result remains readable",
            result_item and type(result_item.text) == "string" and result_item.text ~= "",
            "non-empty title", result_item and result_item.text or "absent")
    else
        self:_assert("long search result is display-truncated before status",
            result_item and result_item.text ~= result_item.book_data.metadata.title
                and result_item.text:sub(-3) == "…",
            "ellipsized", result_item and result_item.text or "absent")
    end
    local after_capture = function()
        local original_ui_show = UIManager.show
        local no_result_text
        UIManager.show = function(manager, widget, ...)
            if widget and type(widget.text) == "string"
                    and widget.text:find("No results for:", 1, true) == 1 then
                no_result_text = widget.text
            end
            return original_ui_show(manager, widget, ...)
        end
        local ok, err = pcall(function()
            app:showSearchWithin(scenario.books, scenario.parent_title, function() end)
            local no_match_dialog = app.search_dialog
            no_match_dialog:setInputText(scenario.no_match_query)
            findButton(no_match_dialog, "Search").callback()
        end)
        UIManager.show = original_ui_show
        if not ok then error(err) end
        self:_assert("empty search reports the submitted query",
            no_result_text == "No results for: " .. scenario.no_match_query,
            "No results for: " .. scenario.no_match_query,
            no_result_text or "absent")
        self:_assert("empty search returns to the unfiltered parent list",
            captured_books == scenario.books and captured_title == scenario.parent_title,
            scenario.parent_title .. " with " .. tostring(#scenario.books) .. " books",
            tostring(captured_title) .. " with "
                .. tostring(captured_books and #captured_books or 0) .. " books")
    end
    return root, function()
        restoreField(app, "showBookList", original_show_list)
        restore_state()
        if UIManager:isWidgetShown(stage) then UIManager:close(stage) end
    end, after_capture
end

function VisualDriver:_showSearchDialog(app, scenario)
    local stage, restore_state = self:_withFixtureStage(app, scenario)
    local original_show_list = rawget(app, "showBookList")
    local list_calls = 0
    app.showBookList = function() list_calls = list_calls + 1 end
    app:showSearchWithin(scenario.books, scenario.title, function() end)
    local root = app.search_dialog
    self:_assert("search dialog shown", root ~= nil, "shown", root and "shown" or "absent")
    self:_assert("search dialog title", root and root.title == "Search in " .. scenario.title,
        "Search in " .. scenario.title, root and root.title or "absent")
    local cancel = findButton(root, "Cancel")
    self:_assert("search cancel callback registered", cancel ~= nil, "registered", cancel and "registered" or "absent")
    local after_capture = function()
        cancel.callback()
        self:_assert("search cancel returns to list once", list_calls == 1, 1, list_calls)
    end
    return root, function()
        restoreField(app, "showBookList", original_show_list)
        restore_state()
        if UIManager:isWidgetShown(stage) then UIManager:close(stage) end
    end, after_capture
end

function VisualDriver:_showBookDetail(app, scenario)
    local stage, restore_state = self:_withFixtureStage(app, scenario)
    local book = scenario.books[scenario.book_index or 1]
    local original_format_menu = rawget(app, "showDownloadFormatMenu")
    local original_refresh = rawget(app, "refreshDetailView")
    local format_calls, refresh_calls = 0, 0
    app.showDownloadFormatMenu = function(_, selected)
        if selected == book then format_calls = format_calls + 1 end
    end
    if scenario.spoiler_revealed then
        -- Recreate the state produced by tapping Reveal before rebuilding the
        -- same book, so this named capture verifies the post-consent view.
        app._detail_book = book
        app._detail_spoilers = { [2] = true }
    end
    app:showBookDetail(book)
    local root = app.detail_widget
    local scroll = root and root.cropping_widget
    self:_assert("book detail shown", root ~= nil and scroll ~= nil,
        "shown with scroll body", scroll and "shown with scroll body" or "absent")
    self:_assertScreenRoot("book detail", root)
    local scroll_size = scroll and scroll.getSize and scroll:getSize() or {}
    self:_assert("detail scroll viewport is positive",
        (scroll_size.w or 0) > 0 and (scroll_size.h or 0) > 0,
        "positive", tostring(scroll_size.w) .. "x" .. tostring(scroll_size.h))

    local inner = scroll and scroll[1]
    local inner_size = inner and inner.getSize and inner:getSize() or {}
    local max_y = math.max(0, (inner_size.h or 0) - (scroll_size.h or 0))
    local horizontal_overflow = math.max(0,
        (inner_size.w or 0) - (scroll_size.w or 0))
    self:_assert("outer detail body never scrolls horizontally",
        horizontal_overflow == 0, 0, horizontal_overflow)
    local target_y = 0
    if scenario.detail_position == "middle" then target_y = math.floor(max_y / 2) end
    if scenario.detail_position == "bottom" then target_y = max_y end
    if target_y > 0 and scroll.setScrolledOffset then
        scroll:setScrolledOffset(Geom:new{ x = 0, y = target_y })
        UIManager:setDirty(root, "ui")
    end
    self:_assert("detail requested scroll position is available",
        scenario.detail_position == "top" or target_y > 0,
        scenario.detail_position == "top" and 0 or "> 0", target_y)

    local real_companion = self.data_profile == "real-epub-companion"
    local files = type(book.downloadFiles) == "table" and book.downloadFiles or {}
    local selected_file = #files == 1 and files[1] or book.primaryFile
    local selected_is_local = selected_file and scenario.local_file_id
        and tonumber(selected_file.id) == tonumber(scenario.local_file_id)
    local expected_action
    if scenario.offline and not selected_is_local then
        expected_action = "Unavailable offline"
    elseif #files > 1 then
        expected_action = "Choose format (" .. tostring(#files) .. ")"
    elseif selected_is_local then
        expected_action = "Read"
    elseif selected_file and selected_file.fileSizeKb then
        expected_action = string.format("Download (%.1f MB)", selected_file.fileSizeKb / 1024)
    else
        expected_action = "Download"
    end
    local action = findWidget(root, function(widget) return widget.text == expected_action end)
    self:_assert("detail fixed action is visible in widget tree", action ~= nil,
        expected_action, action and action.text or "absent")
    local back = findWidget(root, function(widget) return widget.text == "← Back" end)
    self:_assert("detail fixed back action present", back ~= nil,
        "← Back", back and back.text or "absent")

    local show_more = findButton(root, "Show more  ▼")
    local reveal = findButton(root, "Reveal")
    local spoiler_title = findWidget(root, function(widget)
        return type(widget.text) == "string"
            and widget.text:find("Hidden fixture text", 1, true) ~= nil
    end)
    local spoiler_body = findWidget(root, function(widget)
        return widget.text == "Synthetic spoiler body."
    end)
    local spoiler_notice = findWidget(root, function(widget)
        return widget.text == "This review contains spoilers."
    end)
    if real_companion then
        self:_assert("real detail is bound to selected source book",
            tonumber(book.id) == tonumber(self.real_book_id),
            self.real_book_id, book.id)
        local rendered_title = findWidget(root, function(widget)
            return widget.text == book.title
        end)
        self:_assert("real detail renders embedded title",
            rendered_title ~= nil,
            book.title, rendered_title and rendered_title.text or "absent")
    elseif scenario.spoiler_revealed then
        self:_assert("revealed spoiler title and body are visible",
            spoiler_title ~= nil and spoiler_body ~= nil, "title + body",
            tostring(spoiler_title ~= nil) .. "/" .. tostring(spoiler_body ~= nil))
        self:_assert("revealed spoiler removes notice and Reveal action",
            spoiler_notice == nil and reveal == nil, "absent",
            tostring(spoiler_notice ~= nil) .. "/" .. tostring(reveal ~= nil))
    else
        self:_assert("spoiler title is absent before Reveal", spoiler_title == nil,
            "absent", spoiler_title and spoiler_title.text or "absent")
        self:_assert("spoiler body is absent before Reveal", spoiler_body == nil,
            "absent", spoiler_body and spoiler_body.text or "absent")
        self:_assert("spoiler has neutral notice and Reveal action",
            spoiler_notice ~= nil and reveal ~= nil, "notice + Reveal",
            tostring(spoiler_notice ~= nil) .. "/" .. tostring(reveal ~= nil))
    end
    if show_more or reveal then
        app.refreshDetailView = function(_, selected)
            if selected == book then refresh_calls = refresh_calls + 1 end
        end
    end
    local after_capture = function()
        local expected_refreshes = 0
        if action and action.callback and (not real_companion or #files > 1) then
            action.callback()
        end
        if scenario.offline then
            self:_assert("offline detail action is disabled",
                action.enabled == false, false, action.enabled)
        elseif not real_companion or #files > 1 then
            self:_assert("detail format action invokes chooser once",
                format_calls == 1, 1, format_calls)
        else
            self:_assert("real single-format action is registered",
                action and type(action.callback) == "function",
                "function", action and type(action.callback) or "absent")
        end
        if reveal then
            reveal.callback()
            expected_refreshes = expected_refreshes + 1
            self:_assert("Reveal records spoiler consent",
                app._detail_spoilers[2] == true, true, app._detail_spoilers[2])
            self:_assert("Reveal refreshes current detail",
                refresh_calls == expected_refreshes, expected_refreshes, refresh_calls)
        end
        if show_more then
            show_more.callback()
            expected_refreshes = expected_refreshes + 1
            self:_assert("Show more callback expands description",
                app._detail_desc_expanded == true, true, app._detail_desc_expanded)
            self:_assert("Show more refreshes current detail once",
                refresh_calls == expected_refreshes, expected_refreshes, refresh_calls)
        end
    end
    return root, function()
        restoreField(app, "showDownloadFormatMenu", original_format_menu)
        restoreField(app, "refreshDetailView", original_refresh)
        restore_state()
        if UIManager:isWidgetShown(stage) then UIManager:close(stage) end
    end, after_capture
end

function VisualDriver:_showDownloadFormats(app, scenario)
    local stage, restore_state = self:_withFixtureStage(app, scenario)
    local book = scenario.books[scenario.book_index or 1]
    local original_open = rawget(app, "openBook")
    local original_download = rawget(app, "downloadBook")
    local open_calls, download_calls = 0, 0
    app.openBook = function(_, path)
        if path then open_calls = open_calls + 1 end
    end
    app.downloadBook = function(_, selected_book, file)
        if selected_book == book and file then download_calls = download_calls + 1 end
    end
    app:showDownloadFormatMenu(book)
    local root = app.format_menu_widget
    local menu = findMenu(root)
    self:_assert("format chooser shown", menu ~= nil, "shown", menu and "shown" or "absent")
    self:_assert("all compatible formats listed", menu and #menu.item_table == 2,
        2, menu and #menu.item_table or 0)
    local primary_file = book.primaryFile
    local alternative_file = (book.alternativeFormats and book.alternativeFormats[1])
        or (book.downloadFiles and book.downloadFiles[2])
    local epub_item, pdf_item
    if menu then
        for _, item in ipairs(menu.item_table) do
            local id = item.book_file and item.book_file.id
            if primary_file and tonumber(id) == tonumber(primary_file.id) then epub_item = item end
            if alternative_file and tonumber(id) == tonumber(alternative_file.id) then pdf_item = item end
        end
    end
    self:_assert("downloaded format marked Read",
        epub_item and epub_item.mandatory == "Read", "Read",
        epub_item and epub_item.mandatory or "absent")
    local expected_remote_size = alternative_file and alternative_file.fileSizeKb
        and string.format("%.1f MB", alternative_file.fileSizeKb / 1024) or ""
    self:_assert("remote format shows size",
        pdf_item and pdf_item.mandatory == expected_remote_size, expected_remote_size,
        pdf_item and pdf_item.mandatory or "absent")
    local after_capture = function()
        menu:onMenuChoice(epub_item)
        self:_assert("downloaded format opens once", open_calls == 1, 1, open_calls)
        self:_assert("downloaded format does not redownload", download_calls == 0, 0, download_calls)
    end
    return root, function()
        restoreField(app, "openBook", original_open)
        restoreField(app, "downloadBook", original_download)
        restore_state()
        if UIManager:isWidgetShown(stage) then UIManager:close(stage) end
    end, after_capture
end

function VisualDriver:_showLoginDialog(app, scenario)
    local stage, restore_state = self:_withFixtureStage(app, scenario)
    local original_login = rawget(app, "doLogin")
    local login_calls, login_args = 0, nil
    app.doLogin = function(_, server_url, username, password, remember)
        login_calls = login_calls + 1
        login_args = { server_url, username, password, remember }
    end
    app:showLoginDialog()
    local root = app.login_dialog
    self:_assert("login dialog shown", root ~= nil, "shown", root and "shown" or "absent")
    self:_assert("login has three fields", root and root.fields and #root.fields == 3,
        3, root and root.fields and #root.fields or 0)
    local toggle = findButton(root, "☑ Set as default")
    local cancel = findButton(root, "Cancel")
    local login = findButton(root, "Login")
    self:_assert("default-account toggle callback registered", toggle ~= nil,
        "registered", toggle and "registered" or "absent")
    self:_assert("login Cancel action is reachable", cancel ~= nil,
        "Cancel", cancel and cancel.text or "absent")
    self:_assert("login submit action is reachable", login ~= nil,
        "Login", login and login.text or "absent")
    local dialog_size = root and root.dialog_frame and root.dialog_frame:getSize() or {}
    local keyboard_size = root and root._input_widget
        and root._input_widget:getKeyboardDimen() or {}
    local available_height = Screen:getHeight() - (keyboard_size.h or 0)
    self:_assert("complete login dialog fits above keyboard",
        (dialog_size.h or Screen:getHeight() + 1) <= available_height,
        "<= " .. tostring(available_height), dialog_size.h or "absent")
    local landscape = Screen:getWidth() > Screen:getHeight()
    self:_assert("landscape login actions use one reachable row",
        not landscape or (root.buttons and #root.buttons == 1
            and #root.buttons[1] == 3),
        landscape and "one row with three actions" or "not applicable",
        root and root.buttons and (#root.buttons .. " rows") or "absent")
    local after_capture = function()
        toggle.callback()
        self:_assert("default-account toggle changes state",
            app._login_set_default == false, false, app._login_set_default)
        self:_assert("toggle performs no login", login_calls == 0, 0, login_calls)
        root.input_fields[1]:setText("http://visual.test:6060")
        root.input_fields[2]:setText("visual-reader")
        root.input_fields[3]:setText("visual-password")
        login.callback()
        self:_assert("login submit invokes production route once",
            login_calls == 1, 1, login_calls)
        self:_assert("login submit passes all fields and toggle state",
            login_args and login_args[1] == "http://visual.test:6060"
                and login_args[2] == "visual-reader"
                and login_args[3] == "visual-password"
                and login_args[4] == false,
            "three fields, remember=false",
            login_args and table.concat({ tostring(login_args[1]), tostring(login_args[2]),
                tostring(login_args[3]), tostring(login_args[4]) }, " | ") or "absent")
    end
    return root, function()
        restoreField(app, "doLogin", original_login)
        restore_state()
        if UIManager:isWidgetShown(stage) then UIManager:close(stage) end
    end, after_capture
end

function VisualDriver:_showAccountSwitcher(app, scenario)
    local stage, restore_state = self:_withFixtureStage(app, scenario)
    local session = app.session
    local original_list = rawget(session, "listAccounts")
    local original_active = rawget(session, "activeAccount")
    local now = os.time()
    session.listAccounts = function()
        return {
            { server_url = app.server_url, username = app.username, refresh_token = "saved", active = true, resumable = true, token_time = now },
            { server_url = "https://remote.visual.test", username = "travelling-reader", refresh_token = "saved", resumable = true, token_time = now - 86400 },
            { server_url = "http://expired.visual.test:6060", username = "expired-reader", resumable = false },
        }
    end
    session.activeAccount = function()
        return { server_url = app.server_url, username = app.username }
    end
    app:showAccountSwitcher()
    local root = app.account_menu_widget
    local menu = findMenu(root)
    self:_assert("account switcher shown", menu ~= nil, "shown", menu and "shown" or "absent")
    self:_assert("mixed accounts listed", menu and #menu.item_table == 3,
        3, menu and #menu.item_table or 0)
    self:_assert("active account marked",
        menu and menu.item_table[1].text:find("●", 1, true) == 1,
        "marked", menu and menu.item_table[1].text or "absent")
    return root, function()
        restoreField(session, "listAccounts", original_list)
        restoreField(session, "activeAccount", original_active)
        restore_state()
        if UIManager:isWidgetShown(stage) then UIManager:close(stage) end
    end
end

function VisualDriver:_showDownloadFolder(app, scenario)
    local stage, restore_state = self:_withFixtureStage(app, scenario)
    local root
    local original_show = UIManager.show
    UIManager.show = function(manager, widget, ...)
        if widget and widget.title == "Download folder" then root = widget end
        return original_show(manager, widget, ...)
    end
    local show_ok, show_err = pcall(app.showDownloadFolderDialog, app)
    UIManager.show = original_show
    if not show_ok then error(show_err) end
    self:_assert("download folder dialog shown", root ~= nil and root ~= stage,
        "dialog", root and "dialog" or "absent")
    self:_assert("download folder title", root and root.title == "Download folder",
        "Download folder", root and root.title or "absent")
    self:_assert("download folder value", root and root:getInputText() == app.download_dir,
        app.download_dir, root and root:getInputText() or "absent")
    return root, function()
        restore_state()
        if UIManager:isWidgetShown(stage) then UIManager:close(stage) end
    end
end

function VisualDriver:_showSignOutConfirm(app, scenario)
    local stage, restore_state = self:_withFixtureStage(app, scenario)
    app:confirmSignOut()
    local root = UIManager:getTopmostVisibleWidget()
    self:_assert("sign-out confirmation shown", root ~= nil and root ~= stage,
        "confirm dialog", root and "confirm dialog" or "absent")
    self:_assert("sign-out callback registered", root and type(root.ok_callback) == "function",
        "function", root and type(root.ok_callback) or "absent")
    return root, function()
        restore_state()
        if UIManager:isWidgetShown(stage) then UIManager:close(stage) end
    end
end

function VisualDriver:_showUninstallConfirm(app, scenario)
    local stage, restore_state = self:_withFixtureStage(app, scenario)
    app:confirmUninstall()
    local root = UIManager:getTopmostVisibleWidget()
    self:_assert("uninstall choices shown", root ~= nil and root ~= stage,
        "choice dialog", root and "choice dialog" or "absent")
    self:_assert("uninstall has two destructive choices",
        root and type(root.choice1_callback) == "function"
            and type(root.choice2_callback) == "function",
        "two callbacks", root and type(root.choice1_callback) == "function"
            and type(root.choice2_callback) == "function" and "two callbacks"
            or (root and "callbacks missing" or "absent"))
    return root, function()
        restore_state()
        if UIManager:isWidgetShown(stage) then UIManager:close(stage) end
    end
end

function VisualDriver:_showUpdateAvailable(app, scenario)
    local stage, restore_state = self:_withFixtureStage(app, scenario)
    local restore_network = self:_setNetworkState(app, true)
    local original_async = app.async
    local update_calls = 0
    local original_perform = rawget(app, "_performUpdate")
    app.async = {
        run = function(_, _task, done)
            done({
                res = {
                    available = true,
                    installed = "1.4.0",
                    latest = "1.5.0",
                    manifest = { version = "1.5.0" },
                },
            })
        end,
    }
    app._performUpdate = function(_, manifest)
        if manifest and manifest.version == "1.5.0" then update_calls = update_calls + 1 end
    end
    app:checkForUpdates()
    local root = UIManager:getTopmostVisibleWidget()
    self:_assert("update confirmation shown", root ~= nil and root ~= stage,
        "confirm dialog", root and "confirm dialog" or "absent")
    self:_assert("update callback registered", root and type(root.ok_callback) == "function",
        "function", root and type(root.ok_callback) or "absent")
    local after_capture = function()
        root.ok_callback()
        self:_assert("update confirmation invokes installer once", update_calls == 1,
            1, update_calls)
    end
    return root, function()
        app.async = original_async
        restoreField(app, "_performUpdate", original_perform)
        restore_network()
        restore_state()
        if UIManager:isWidgetShown(stage) then UIManager:close(stage) end
    end, after_capture
end

function VisualDriver:_showTailscaleInstallPrompt(app, scenario)
    local stage, restore_state = self:_withFixtureStage(app, scenario)
    local original_tailscale = app.tailscale
    local original_install = rawget(app, "tailscaleInstall")
    local install_calls = 0
    app.tailscale = { isInstalled = function() return false end }
    app.tailscaleInstall = function() install_calls = install_calls + 1 end
    app:ensureTailscaleInstalled()
    local root = UIManager:getTopmostVisibleWidget()
    self:_assert("Tailscale install prompt shown", root ~= nil and root ~= stage,
        "confirm dialog", root and "confirm dialog" or "absent")
    self:_assert("Tailscale Install callback registered",
        root and type(root.ok_callback) == "function",
        "function", root and type(root.ok_callback) or "absent")
    local after_capture = function()
        root.ok_callback()
        self:_assert("Tailscale Install invoked once", install_calls == 1, 1, install_calls)
    end
    return root, function()
        app.tailscale = original_tailscale
        restoreField(app, "tailscaleInstall", original_install)
        restore_state()
        if UIManager:isWidgetShown(stage) then UIManager:close(stage) end
    end, after_capture
end

function VisualDriver:_showTailscaleStatus(app, scenario)
    local stage, restore_state = self:_withFixtureStage(app, scenario)
    local original_tailscale = app.tailscale
    local original_async = app.async
    app.tailscale = {
        isInstalled = function() return true end,
        isDaemonRunning = function() return true end,
    }
    app.async = {
        run = function(_, _task, done)
            done({ summary = {
                state = "Running",
                hostname = "kindle-visual",
                ip = "100.64.12.34",
                peers_online = 3,
                peers_total = 5,
            } })
        end,
    }
    app:showTailscaleStatus()
    local root = UIManager:getTopmostVisibleWidget()
    local text = root and root.text or ""
    self:_assert("Tailscale status shown", root ~= nil and root ~= stage,
        "status message", root and "status message" or "absent")
    self:_assert("Tailscale status includes device", text:find("kindle-visual", 1, true) ~= nil,
        "kindle-visual", text)
    self:_assert("Tailscale status includes peer count", text:find("3 of 5", 1, true) ~= nil,
        "3 of 5", text)
    return root, function()
        app.tailscale = original_tailscale
        app.async = original_async
        restore_state()
        if UIManager:isWidgetShown(stage) then UIManager:close(stage) end
    end
end

function VisualDriver:_showTailscaleAuth(app, scenario)
    local stage, restore_state = self:_withFixtureStage(app, scenario)
    local original_async = app.async
    app.async = {
        run = function(_, _task, done)
            done({ ok = false, auth_url = "https://login.tailscale.com/a/visual-fixture" })
        end,
        cancel = function() end,
    }
    app:_tailscaleUp()
    local root = UIManager:getTopmostVisibleWidget()
    local text = root and root.text or ""
    self:_assert("Tailscale authentication instructions shown",
        root ~= nil and root ~= stage, "instructions", root and "instructions" or "absent")
    self:_assert("Tailscale instructions explain QR step",
        text:find("QR code", 1, true) ~= nil, "mentions QR code", text)
    self:_assert("Tailscale instructions have follow-up callback",
        root and type(root.dismiss_callback) == "function",
        "function", root and type(root.dismiss_callback) or "absent")
    return root, function()
        app.async = original_async
        restore_state()
        if UIManager:isWidgetShown(stage) then UIManager:close(stage) end
    end
end

function VisualDriver:_showTailscaleAuthQr(app, scenario)
    local root, cleanup = self:_showTailscaleAuth(app, scenario)
    local dismiss = root and root.dismiss_callback
    if dismiss then dismiss() end
    local qr = UIManager:getTopmostVisibleWidget()
    self:_assert("Tailscale QR screen shown", qr ~= nil and qr ~= root,
        "QR screen", qr and "QR screen" or "absent")
    self:_assert("Tailscale QR contains exact authentication URL",
        qr and qr.text == "https://login.tailscale.com/a/visual-fixture",
        "https://login.tailscale.com/a/visual-fixture", qr and qr.text or "absent")
    return qr, function()
        if root and UIManager:isWidgetShown(root) then UIManager:close(root) end
        cleanup()
    end
end

function VisualDriver:_showSyncMainMenu(app, scenario)
    local Menu = require("ui/widget/menu")
    local stage, restore_state = self:_withFixtureStage(app, scenario)
    local Sync = loadSyncPluginClass(app)
    local sync_calls, detail_calls = 0, 0
    local fake = {
        enabled = true,
        _statusLine = function() return "Grimmory Sync · 2 changes pending" end,
        _statusDetail = function()
            detail_calls = detail_calls + 1
            return "Two position changes are waiting to sync."
        end,
        syncNow = function() sync_calls = sync_calls + 1 end,
    }
    local items = {}
    Sync.addToMainMenu(fake, items)
    local rows = items.grimmory_sync and items.grimmory_sync.sub_item_table or {}
    local root = InputContainer:new{
        dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() },
    }
    local menu = Menu:new{
        show_parent = root,
        title = "Grimmory Sync",
        item_table = rows,
        width = Screen:getWidth(), height = Screen:getHeight(),
        covers_fullscreen = true, is_borderless = true, is_popout = false,
    }
    table.insert(root, menu)
    UIManager:show(root)
    self:_assert("sync menu production rows present", #rows == 2, 2, #rows)
    local sync_item
    for _, item in ipairs(rows) do if item.text == "Sync now" then sync_item = item end end
    self:_assert("sync-now callback registered", sync_item and type(sync_item.callback) == "function",
        "function", sync_item and type(sync_item.callback) or "absent")
    local after_capture = function()
        sync_item.callback()
        self:_assert("sync-now production callback invokes service once", sync_calls == 1, 1, sync_calls)
        self:_assert("status detail remains lazy", detail_calls == 0, 0, detail_calls)
    end
    return root, function()
        restore_state()
        if UIManager:isWidgetShown(stage) then UIManager:close(stage) end
    end, after_capture
end

function VisualDriver:_showOfflineWifiPrompt(app, scenario)
    local stage, restore_state = self:_withFixtureStage(app, scenario)
    local NetworkMgr = require("ui/network/manager")
    local original_is_on = NetworkMgr.isWifiOn
    local original_turn_on = NetworkMgr.turnOnWifi
    local original_fetch = rawget(app, "fetchAndShowLibrary")
    local wifi_calls, fetch_calls = 0, 0
    NetworkMgr.isWifiOn = function() return false end
    NetworkMgr.turnOnWifi = function(_, done)
        wifi_calls = wifi_calls + 1
        if done then done() end
    end
    app.fetchAndShowLibrary = function() fetch_calls = fetch_calls + 1 end
    app:browseLibrary()
    local root = UIManager:getTopmostVisibleWidget()
    self:_assert("offline Wi-Fi prompt shown", root ~= nil and root ~= stage,
        "confirm dialog", root and "confirm dialog" or "absent")
    self:_assert("offline Wi-Fi prompt has turn-on callback",
        root and type(root.ok_callback) == "function",
        "function", root and type(root.ok_callback) or "absent")
    self:_assert("offline Wi-Fi prompt offers cache fallback",
        root and type(root.cancel_callback) == "function",
        "function", root and type(root.cancel_callback) or "absent")
    local after_capture = function()
        root.ok_callback()
        self:_assert("offline prompt turns Wi-Fi on once", wifi_calls == 1, 1, wifi_calls)
        self:_assert("offline prompt fetches after association once", fetch_calls == 1, 1, fetch_calls)
    end
    return root, function()
        NetworkMgr.isWifiOn = original_is_on
        NetworkMgr.turnOnWifi = original_turn_on
        restoreField(app, "fetchAndShowLibrary", original_fetch)
        restore_state()
        if UIManager:isWidgetShown(stage) then UIManager:close(stage) end
    end, after_capture
end

function VisualDriver:_showDownloadProgress(app, scenario)
    local stage, restore_state = self:_withFixtureStage(app, scenario)
    local book = scenario.books[scenario.book_index or 1]
    local file = book.primaryFile
    local original_async = app.async
    local original_dest = rawget(app, "buildDestPath")
    local original_refresh = rawget(app, "refreshDetailView")
    local progress_callback
    local cancel_calls = 0
    local dest = joinPath(self.output_dir, "download-progress-fixture.epub")
    app.buildDestPath = function() return dest end
    app.refreshDetailView = function() end
    app.async = {
        run = function(_, _task, _done, opts)
            progress_callback = opts and opts.on_progress
            return { finished = false }
        end,
        cancel = function() cancel_calls = cancel_calls + 1 end,
    }
    local part = dest .. ".part"
    local part_file = assert(io.open(part, "wb"))
    local half_bytes = math.floor(file.fileSizeKb * 1024 / 2)
    part_file:seek("set", half_bytes - 1)
    part_file:write("\0")
    part_file:close()
    app:_startBookDownload(book, file)
    if progress_callback then progress_callback() end
    local root = UIManager:getTopmostVisibleWidget()
    local text = root and root.text or ""
    self:_assert("download progress shown", root ~= nil and root ~= stage,
        "progress message", root and "progress message" or "absent")
    self:_assert("download progress reaches deterministic 50 percent",
        text:find("50%", 1, true) ~= nil, "50%", text)
    self:_assert("download progress cancel callback registered",
        root and type(root.dismiss_callback) == "function",
        "function", root and type(root.dismiss_callback) or "absent")
    local after_capture = function()
        root.dismiss_callback()
        self:_assert("download progress cancel invoked once", cancel_calls == 1, 1, cancel_calls)
    end
    return root, function()
        os.remove(part)
        os.remove(dest)
        app.async = original_async
        restoreField(app, "buildDestPath", original_dest)
        restoreField(app, "refreshDetailView", original_refresh)
        app._downloading_id = nil
        restore_state()
        if UIManager:isWidgetShown(stage) then UIManager:close(stage) end
    end, after_capture
end

function VisualDriver:_showLongError(app, scenario)
    local stage, restore_state = self:_withFixtureStage(app, scenario)
    local restore_network = self:_setNetworkState(app, true)
    local original_async = app.async
    local message = "The visual fixture server could not be reached after several attempts. Check the server address, Wi-Fi connection, reverse proxy, and certificate configuration before trying again."
    app.async = { run = function(_, _task, done) done({ err = message }) end }
    app:checkForUpdates()
    local root = UIManager:getTopmostVisibleWidget()
    local text = root and root.text or ""
    self:_assert("long production error shown", root ~= nil and root ~= stage,
        "error message", root and "error message" or "absent")
    self:_assert("long production error preserves actionable detail",
        text:find("reverse proxy", 1, true) ~= nil, "reverse proxy", text)
    return root, function()
        app.async = original_async
        restore_network()
        restore_state()
        if UIManager:isWidgetShown(stage) then UIManager:close(stage) end
    end
end

local function sha256File(path)
    local handle, open_err = io.open(path, "rb")
    if not handle then return nil, tostring(open_err) end
    local bytes = handle:read("*a")
    handle:close()
    return require("ffi/sha2").sha256(bytes)
end

local function assertionInventory(names)
    table.sort(names)
    return {
        count = #names,
        sha256 = require("ffi/sha2").sha256(table.concat(names, "\n")),
    }
end

local function outcomeEvidence(assertions)
    local names = { scenario = {}, provenance = {} }
    local seen = { scenario = {}, provenance = {} }
    for _, assertion in ipairs(assertions) do
        local scope = assertion.scope
        local name = assertion.name
        if names[scope] == nil then
            return nil, "assertion has invalid outcome scope: " .. tostring(scope)
        end
        if type(name) ~= "string" or name == "" then
            return nil, "assertion has no stable outcome name"
        end
        if seen[scope][name] then
            return nil, "duplicate " .. scope .. " outcome name: " .. name
        end
        if type(assertion.pass) ~= "boolean"
                or assertion.expected == nil or assertion.actual == nil then
            return nil, "assertion has an incomplete outcome record: " .. name
        end
        seen[scope][name] = true
        names[scope][#names[scope] + 1] = name
    end
    if #names.scenario == 0 then
        return nil, "scenario produced no named outcome assertions"
    end
    return {
        schemaVersion = 1,
        scenarioAssertions = assertionInventory(names.scenario),
        provenanceAssertions = assertionInventory(names.provenance),
    }
end

function VisualDriver:_showReaderDownload(app, scenario)
    local stage, restore_state = self:_withFixtureStage(app, scenario)
    local server_url = os.getenv("GRIMMORY_VISUAL_SERVER_URL")
    local source_path = os.getenv("GRIMMORY_VISUAL_EPUB")
    if not server_url or server_url == "" then
        error("GRIMMORY_VISUAL_SERVER_URL is required for reader_download_open")
    end
    local source_sha, source_err = sha256File(source_path)
    if not source_sha then error("could not hash source EPUB: " .. tostring(source_err)) end
    local expected_sha = (os.getenv("GRIMMORY_VISUAL_EPUB_SHA256") or source_sha):lower()
    self:_assert("selected source EPUB matches its expected SHA-256",
        source_sha == expected_sha, expected_sha, source_sha)

    local selected_id = tonumber(os.getenv("GRIMMORY_VISUAL_BOOK_ID"))
        or tonumber(scenario.books[1] and scenario.books[1].id)
    local selected_file_id = tonumber(os.getenv("GRIMMORY_VISUAL_FILE_ID"))
    local book
    for _, candidate in ipairs(scenario.books or {}) do
        if tonumber(candidate.id) == selected_id then book = candidate break end
    end
    if not book then error("download fixture book is absent: " .. tostring(selected_id)) end
    -- Synthetic catalogue records deliberately start as raw server-shaped
    -- data. Use the same production normalizer as an online library fetch.
    require("api").normalizeBook(book)
    local book_file = book.primaryFile
    for _, candidate in ipairs(book.downloadFiles or book.bookFiles or {}) do
        if selected_file_id and tonumber(candidate.id) == selected_file_id then
            book_file = candidate
            break
        end
    end
    if not book_file then error("download fixture has no primary EPUB file") end
    self:_assert("download selects the mapped Grimmory file",
        selected_file_id == nil or tonumber(book_file.id) == selected_file_id,
        selected_file_id or "primary file", book_file.id or "absent")

    local Downloads = require("downloads")
    local ffiutil = require("ffi/util")
    local original_downloads = app.downloads
    local original_async = app.async
    local original_refresh = rawget(app, "refreshDetailView")
    local original_library_fetched = app._library_fetched_online
    local original_collection_sync = app.sync_shelf_collections
    local restore_network = self:_setNetworkState(app, true)
    app.server_url = server_url
    app.download_dir = self.output_dir
    app.downloads = Downloads.new{ download_dir = self.output_dir }
    -- _installFixtureState replaces this delegate for static layout cases.
    -- This journey deliberately restores the production registry lookup.
    rawset(app, "getLocalPath", nil)
    app.refreshDetailView = function() end
    app._library_fetched_online = true
    app.sync_shelf_collections = true
    app.settings:saveSetting("server_url", server_url)
    app.settings:saveSetting("username", app.username)
    app.settings:saveSetting("active_account", {
        server_url = server_url, username = app.username,
    })
    app.settings:flush()
    app.session:loadTokens("visual-access-token", "visual-refresh-token", os.time())
    local download_payload
    app.async = {
        -- Keep process scheduling deterministic while running the complete
        -- production Session/API task, HTTP transfer and completion callback.
        run = function(_, task, done)
            local payload = task()
            download_payload = payload
            done(payload)
            return { finished = true }
        end,
        cancel = function() end,
    }

    local dest = app:buildDestPath(book, book_file)
    local part = dest .. ".part"
    os.remove(part)
    os.remove(dest)
    app:downloadBook(book, book_file)
    local downloaded_mode = lfs.attributes(dest, "mode")
    self:_assert("production download publishes a complete EPUB",
        downloaded_mode == "file" and lfs.attributes(part, "mode") == nil,
        "final file with no .part", downloaded_mode or "absent")
    if downloaded_mode ~= "file" then
        error("production download did not create its destination file: result="
            .. tostring(download_payload and download_payload.result)
            .. " err=" .. tostring(download_payload and download_payload.err))
    end
    local downloaded_sha, hash_err = sha256File(dest)
    if not downloaded_sha then error("could not hash downloaded EPUB: " .. tostring(hash_err)) end
    self:_assert("fixture server delivered the exact selected EPUB bytes",
        downloaded_sha == expected_sha, expected_sha, downloaded_sha)

    local local_path = app:getLocalPath(book, book_file)
    local registry_key = Downloads.registryKey(server_url, book.id,
        book_file.id, book_file.isPrimary == true)
    local registry_entry = app.downloads.registry:readSetting(registry_key)
    self:_assert("production registry lookup returns downloaded path",
        local_path == dest, dest, local_path or "absent")
    self:_assert("registry preserves exact server and file identity",
        registry_entry and tonumber(registry_entry.server_id) == tonumber(book.id)
            and registry_entry.server_url == server_url
            and tonumber(registry_entry.file_id) == tonumber(book_file.id),
        tostring(book.id) .. "/" .. tostring(book_file.id) .. " @ " .. server_url,
        registry_entry and (tostring(registry_entry.server_id) .. "/"
            .. tostring(registry_entry.file_id) .. " @ "
            .. tostring(registry_entry.server_url)) or "absent")
    self:_assert("registry preserves exact EPUB type and path",
        registry_entry and registry_entry.book_type == "EPUB"
            and registry_entry.path == dest and registry_entry.is_primary == true,
        "EPUB primary @ " .. dest,
        registry_entry and (tostring(registry_entry.book_type) .. " @ "
            .. tostring(registry_entry.path)) or "absent")

    -- registerDownload invokes the real shelf reconciler. Verify it used the
    -- actual canonical path, then add an unrelated user member and prove a
    -- second production reconciliation is both idempotent and additive.
    local shelf_ref = book.shelves and book.shelves[1]
    local shelf_id = type(shelf_ref) == "table" and (shelf_ref.id or shelf_ref.shelfId)
        or shelf_ref
    if not shelf_id then error("selected download fixture has no shelf membership") end
    local rc = app.shelf_collections and app.shelf_collections.read_collection
    if not rc then error("KOReader ReadCollection is unavailable") end
    rc:_read()
    local collection_name
    for name, settings in pairs(rc.coll_settings or {}) do
        local meta = settings and settings.grimmory_shelf
        if meta and tostring(meta.shelf_id) == tostring(shelf_id)
                and meta.server_url == server_url and meta.username == app.username then
            collection_name = name
            break
        end
    end
    local canonical_dest = ffiutil.realpath(dest)
    self:_assert("downloaded canonical path is persisted in its KOReader shelf",
        collection_name and canonical_dest
            and rc.coll[collection_name] and rc.coll[collection_name][canonical_dest] ~= nil,
        "managed canonical path", collection_name or "absent collection")
    if not collection_name then error("production shelf collection was not created") end

    local manual_path = joinPath(self.output_dir, "manual-collection-entry.epub")
    local manual_file = assert(io.open(manual_path, "wb"))
    manual_file:write("manual user-owned collection fixture\n")
    manual_file:close()
    local canonical_manual = ffiutil.realpath(manual_path)
    rc:addItem(canonical_manual, collection_name)
    rc:write()
    local second_summary, second_err = app:reconcileShelfCollections(
        app.cached_books, app.cached_shelves)
    if not second_summary then error("second shelf reconcile failed: " .. tostring(second_err)) end
    rc:_read()
    self:_assert("second shelf reconciliation is idempotent",
        second_summary.changed == false and second_summary.added == 0
            and second_summary.removed == 0,
        "no changes", string.format("changed=%s added=%d removed=%d",
            tostring(second_summary.changed), second_summary.added, second_summary.removed))
    self:_assert("shelf reconciliation preserves user-added members",
        rc.coll[collection_name] and rc.coll[collection_name][canonical_manual] ~= nil
            and rc.coll[collection_name][canonical_dest] ~= nil,
        "manual and managed paths",
        rc.coll[collection_name] and rc.coll[collection_name][canonical_manual]
            and rc.coll[collection_name][canonical_dest]
            and "manual and managed paths" or "missing collection member")

    local journey = {}
    -- Invoke the application's production open delegate. Its optional callback
    -- is the public ReaderUI after-open callback, so assertions cannot race the
    -- ReaderReady event that attaches and initializes the sync plugin.
    app:openBook(dest, function(opened_reader)
      UIManager:nextTick(function()
        local ok, inspect_err = pcall(function()
            local reader = opened_reader
            local document = reader and reader.document
            local page_count = document and document.getPageCount
                and document:getPageCount() or 0
            local start_xpointer = document and document.getXPointer
                and document:getXPointer()
            self:_assert("downloaded EPUB opens in production ReaderUI",
                reader ~= nil and document ~= nil and document.file == dest,
                "rendered downloaded reader",
                reader and document and "rendered reader" or "absent")
            local sync = reader and reader.grimmory_sync
            self:_assert("sync plugin consumes the downloaded registry contract",
                sync and tonumber(sync.book_id) == tonumber(book.id)
                    and tonumber(sync.file_id) == tonumber(book_file.id)
                    and sync.file_type == "EPUB" and sync.book_path == dest,
                tostring(book.id) .. "/" .. tostring(book_file.id)
                    .. " EPUB @ " .. dest,
                sync and (tostring(sync.book_id) .. "/" .. tostring(sync.file_id)
                    .. " " .. tostring(sync.file_type) .. " @ "
                    .. tostring(sync.book_path)) or "absent")
            self:_assert("downloaded EPUB renders more than five pages",
                page_count > 5, "> 5", page_count)
            if reader and reader.rolling and reader.rolling.onGotoPercent then
                reader.rolling:onGotoPercent(50)
            end
            local middle_xpointer = document and document.getXPointer
                and document:getXPointer()
            self:_assert("downloaded EPUB exposes distinct real positions",
                type(start_xpointer) == "string" and start_xpointer ~= ""
                    and type(middle_xpointer) == "string" and middle_xpointer ~= ""
                    and middle_xpointer ~= start_xpointer,
                "distinct start and middle XPointers",
                tostring(start_xpointer) .. " -> " .. tostring(middle_xpointer))
        end)
        journey.error = not ok and tostring(inspect_err) or nil
        journey.ready = ok
      end)
    end)

    return stage, function()
        os.remove(part)
        os.remove(dest)
        os.remove(manual_path)
        app.downloads = original_downloads
        app.async = original_async
        restoreField(app, "refreshDetailView", original_refresh)
        app._library_fetched_online = original_library_fetched
        app.sync_shelf_collections = original_collection_sync
        restore_network()
        restore_state()
        if UIManager:isWidgetShown(stage) then UIManager:close(stage) end
    end, function()
        if journey.error then error(journey.error) end
        if not journey.ready then
            error("downloaded ReaderUI journey did not finish before capture")
        end
    end
end

function VisualDriver:_showReader(app, scenario, with_conflict)
    local stage, restore_state = self:_withFixtureStage(app, scenario)
    local path = os.getenv("GRIMMORY_VISUAL_EPUB")
    local readable = path and io.open(path, "rb")
    if readable then readable:close() end
    if not readable then error("GRIMMORY_VISUAL_EPUB must name a readable EPUB") end

    if not with_conflict then
        local journey = {}
        local ReaderUI = require("apps/reader/readerui")
        ReaderUI:showReader(path, nil, nil, nil, function(opened_reader)
            local reader = opened_reader or ReaderUI.instance
            UIManager:nextTick(function()
                local document = reader and reader.document
                local page_count = document and document.getPageCount
                    and document:getPageCount() or 0
                local start_xpointer = document and document.getXPointer
                    and document:getXPointer()
                self:_assert("production EPUB reader shown",
                    reader ~= nil and document ~= nil,
                    "rendered reader",
                    reader and document and "rendered reader" or "absent")
                self:_assert("opened EPUB renders multiple KOReader pages",
                    page_count > 5, "> 5", page_count)
                if reader and reader.rolling and reader.rolling.onGotoPercent then
                    reader.rolling:onGotoPercent(50)
                end
                local middle_xpointer = document and document.getXPointer
                    and document:getXPointer()
                self:_assert("reader navigates through document-derived positions",
                    type(start_xpointer) == "string" and start_xpointer ~= ""
                        and type(middle_xpointer) == "string" and middle_xpointer ~= ""
                        and middle_xpointer ~= start_xpointer,
                    "distinct start and middle XPointers",
                    tostring(start_xpointer) .. " -> " .. tostring(middle_xpointer))
                journey.ready = true
            end)
        end)
        return stage, function()
            restore_state()
            if UIManager:isWidgetShown(stage) then UIManager:close(stage) end
        end, function()
            if not journey.ready then
                error("ReaderUI did not finish the document-derived open journey")
            end
        end
    end

    -- Register and authenticate before ReaderUI is created. The public
    -- after-open callback runs only after KOReader has loaded, rendered, and
    -- broadcast ReaderReady, so this avoids mistaking its temporary "Opening"
    -- message for the reader (the old smoke test did exactly that).
    local DataStorage = require("datastorage")
    local LuaSettings = require("luasettings")
    local server_url = "http://grimmory.visual.test:6060"
    local username = "visual-reader"
    local book_id = tonumber(os.getenv("GRIMMORY_VISUAL_BOOK_ID")) or 1001
    local file_id = tonumber(os.getenv("GRIMMORY_VISUAL_FILE_ID")) or 5001
    local title = os.getenv("GRIMMORY_VISUAL_BOOK_TITLE")
        or path:match("([^/\\]+)$") or "Visual sync fixture"
    local settings = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/grimmory.lua")
    settings:saveSetting("server_url", server_url)
    settings:saveSetting("username", username)
    settings:saveSetting("token", "visual-access-token")
    settings:saveSetting("token_time", os.time())
    settings:saveSetting("active_account", {
        server_url = server_url, username = username,
    })
    settings:saveSetting("sync_annotations", false)
    settings:saveSetting("sync_reading_sessions", false)
    settings:flush()
    local registry = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/grimmory_downloads.lua")
    registry:saveSetting("visual-sync-fixture", {
        path = path, server_id = book_id, server_url = server_url,
        file_id = file_id, book_type = "EPUB", title = title,
        file_name = path:match("([^/\\]+)$"), is_primary = true,
    })
    registry:flush()

    local journey = {}
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(path, nil, nil, nil, function(opened_reader)
        local reader = opened_reader or ReaderUI.instance
        -- after_open_callback fires at the end of ReaderUI:init(), immediately
        -- before ReaderUI itself is shown. Defer one tick so a conflict opened
        -- by the journey is layered above the rendered reader, not underneath
        -- it, and so event dispatch follows normal post-open behaviour.
        UIManager:nextTick(function()
            local ok, root, after_capture = pcall(
                self._beginReaderSyncJourney, self, reader, path)
            if ok then
                journey.ready = true
                journey.root = root
                journey.after_capture = after_capture
            else
                journey.error = tostring(root)
            end
        end)
    end)

    return stage, function()
        restore_state()
        if UIManager:isWidgetShown(stage) then UIManager:close(stage) end
    end, function()
        if journey.error then error(journey.error) end
        if not journey.ready or type(journey.after_capture) ~= "function" then
            error("ReaderUI after-open callback did not complete before capture")
        end
        journey.after_capture()
    end
end

function VisualDriver:_exerciseReaderSession(sync, gotoPercent)
    local Wire = require("wire")
    local original_async = sync._async
    local original_record = Wire.recordSession
    local recorded
    Wire.recordSession = function(_server_url, payload, credentials)
        recorded = payload
        return { code = 201, body = "{}", auth = credentials }
    end
    sync._async = {
        run = function(_, task, done) done(task()) end,
    }
    sync.sync_reading_sessions = true
    sync.session_min_seconds = 30

    local start = gotoPercent(44)
    sync:_beginReadingSession()
    local state_entry = sync.state:get(sync:_bookMeta())
    local active = state_entry and state_entry.active_session
    self:_assert("real reader session starts with actual EPUB CFI",
        active and active.start_position == start.cfi,
        start.cfi, active and active.start_position or "absent")
    if not active then error("production reading session did not start") end
    -- Make the deterministic journey long enough to survive the production
    -- accidental-open threshold without sleeping for real time.
    active.started_at = os.time() - 90
    active.last_event_at = active.started_at
    sync.state._store:flush()

    local finish = gotoPercent(48)
    sync:onPageUpdate()
    sync:_finishReadingSession()
    local pending = sync.state:pendingSessions(sync.username, sync.server_url)
    self:_assert("page activity finalises one durable reading session",
        #pending == 1, 1, #pending)
    self:_assert("session records real start and end positions",
        pending[1] and pending[1].session.start_position == start.cfi
            and pending[1].session.end_position == finish.cfi
            and pending[1].session.start_position ~= pending[1].session.end_position,
        "distinct actual CFIs",
        pending[1] and tostring(pending[1].session.end_position) or "absent")

    sync:_drainSessions(sync.username, sync.server_url, {
        token = "visual-access-token",
    })
    self:_assert("production session drain sends EPUB identity and duration",
        recorded and recorded.bookId == tonumber(sync.book_id)
            and recorded.bookType == "EPUB"
            and recorded.durationSeconds >= 90,
        "book id, EPUB, >= 90 seconds",
        recorded and string.format("%s,%s,%s", tostring(recorded.bookId),
            tostring(recorded.bookType), tostring(recorded.durationSeconds)) or "absent")
    self:_assert("session drain sends KOReader's exact positions",
        recorded and recorded.startLocation == start.cfi
            and recorded.endLocation == finish.cfi,
        "actual start/end CFI",
        recorded and tostring(recorded.endLocation) or "absent")
    self:_assert("successful session drain clears pending session",
        #sync.state:pendingSessions(sync.username, sync.server_url) == 0,
        0, #sync.state:pendingSessions(sync.username, sync.server_url))

    -- onPageUpdate also captures progress. It is setup noise for this focused
    -- session check and must not leak into the following annotation journey.
    sync.queue._store.data = {}
    sync.queue._store:flush()
    sync.sync_reading_sessions = false
    sync._async = original_async
    Wire.recordSession = original_record
end

function VisualDriver:_exerciseReaderAnnotations(sync, reader, gotoPercent)
    local Wire = require("wire")
    local original_async = sync._async
    local originals = {
        get = Wire.getAnnotations,
        create = Wire.createAnnotation,
        update = Wire.updateAnnotation,
        delete = Wire.deleteAnnotation,
    }
    local remote, creates, updates, deletes = {}, 0, 0, 0
    Wire.getAnnotations = function(_server_url, _book_id, credentials)
        return { code = 200, body = json.encode(remote), auth = credentials }
    end
    Wire.createAnnotation = function(_server_url, body, credentials)
        creates = creates + 1
        remote[1] = {
            id = 9101,
            bookId = body.bookId,
            cfi = body.cfi,
            chapterTitle = body.chapterTitle,
            text = body.text,
            color = body.color,
            style = body.style,
            note = body.note,
            createdAt = "2026-08-01T12:00:00Z",
            updatedAt = "2026-08-01T12:00:00Z",
        }
        return { code = 201, body = json.encode(remote[1]), auth = credentials }
    end
    Wire.updateAnnotation = function(_server_url, _id, _body, credentials)
        updates = updates + 1
        return { code = 200, body = "{}", auth = credentials }
    end
    Wire.deleteAnnotation = function(_server_url, _id, credentials)
        deletes = deletes + 1
        return { code = 200, body = "{}", auth = credentials }
    end
    sync._async = {
        run = function(_, task, done) done(task()) end,
    }
    sync.sync_annotations = true

    local range_start = gotoPercent(52)
    local range_end = gotoPercent(53)
    self:_assert("annotation range uses distinct rendered XPointers",
        range_start.xpointer ~= range_end.xpointer,
        "distinct XPointers", tostring(range_end.xpointer))
    local highlight = {
        pos0 = range_start.xpointer,
        pos1 = range_end.xpointer,
        page = range_start.xpointer,
        datetime = "2026-08-01 12:00:00Z",
        datetime_updated = "2026-08-01 12:00:00Z",
        color = "yellow",
        drawer = "lighten",
        chapter = "Field Note",
        text = "A deterministic highlight over genuinely rendered fixture text.",
        note = "device note",
    }
    reader.annotation.annotations = { highlight }

    local function flushModified(phase)
        sync:onAnnotationsModified()
        local flush = sync._annotation_flush_fn
        self:_assert(phase .. " annotation hook schedules production reconciliation",
            type(flush) == "function", "scheduled", type(flush))
        if not flush then error("annotation reconciliation was not scheduled") end
        UIManager:unschedule(flush)
        flush()
    end

    flushModified("initial")
    local adopted = reader.annotation.annotations[1]
    local entry = sync.state:get(sync:_bookMeta())
    self:_assert("local highlight becomes a valid real CFI range",
        remote[1] and type(remote[1].cfi) == "string"
            and remote[1].cfi:match("^epubcfi%(.+%)$") ~= nil,
        "valid range CFI", remote[1] and tostring(remote[1].cfi) or "absent")
    self:_assert("production annotation create and final pull adopt server id",
        creates == 1 and adopted and adopted.grimmory_id == 9101,
        "one create and id 9101",
        string.format("creates=%d id=%s", creates,
            adopted and tostring(adopted.grimmory_id) or "absent"))
    self:_assert("clean annotation reconciliation clears dirty state",
        entry and entry.annotations_dirty == false,
        false, entry and tostring(entry.annotations_dirty) or "absent")

    -- Modify both sides from the established shadow. Production planning must
    -- fail closed and retain the device note rather than PUT either version.
    adopted.note = "device edit after adoption"
    remote[1].note = "server edit after adoption"
    remote[1].updatedAt = "2026-08-01T12:05:00Z"
    flushModified("conflict")
    entry = sync.state:get(sync:_bookMeta())
    local conflict = entry and entry.annotation_conflicts
        and entry.annotation_conflicts["9101"]
    self:_assert("concurrent annotation edits fail closed as a conflict",
        conflict == "both-edited" and updates == 0 and deletes == 0,
        "both-edited, no mutation",
        string.format("%s updates=%d deletes=%d", tostring(conflict), updates, deletes))
    self:_assert("annotation conflict preserves the device version",
        reader.annotation.annotations[1]
            and reader.annotation.annotations[1].note == "device edit after adoption",
        "device edit after adoption",
        reader.annotation.annotations[1]
            and tostring(reader.annotation.annotations[1].note) or "absent")

    sync.sync_annotations = false
    sync._async = original_async
    Wire.getAnnotations = originals.get
    Wire.createAnnotation = originals.create
    Wire.updateAnnotation = originals.update
    Wire.deleteAnnotation = originals.delete
end

function VisualDriver:_beginReaderSyncJourney(reader, path)
    self:_assert("production EPUB reader shown",
        reader ~= nil and reader.document ~= nil,
        "reader", reader and "reader" or "absent")
    local loader = reader and reader.pluginloader
    local sync = reader and reader.grimmory_sync
        or (loader and loader.getPluginInstance
            and loader:getPluginInstance("grimmory_sync"))
    self:_assert("production sync plugin is attached to ReaderUI",
        sync ~= nil and sync.ui == reader,
        "ReaderUI sync instance", sync and "sync instance" or "absent")
    if not sync then error("production Grimmory Sync instance was not loaded") end
    self:_assert("sync plugin registered the opened EPUB",
        sync.book_id ~= nil and sync.file_type == "EPUB"
            and sync.book_path == path,
        "registered EPUB", tostring(sync.file_type) .. ":" .. tostring(sync.book_id))
    self:_assert("production CFI engine initialised", sync.cfi ~= nil,
        "CFI engine", sync.cfi and "CFI engine" or "absent")
    if not sync.cfi then error("production CFI engine did not initialise for " .. path) end

    local Event = require("ui/event")
    local function gotoPercent(percent)
        -- This setup navigation happens while building the scenario, not as a
        -- simulated tap. Call KOReader's real rolling module directly so its
        -- position update is complete before we capture the resulting CFI.
        reader.rolling:onGotoPercent(percent)
        local percentage = math.floor(sync:getPercentage() * 10000) / 100
        local cfi = sync:getPositionData()
        local xpointer = reader.document:getXPointer()
        return { percentage = percentage, cfi = cfi, xpointer = xpointer }
    end
    local function validPosition(position)
        return type(position.percentage) == "number"
            and type(position.cfi) == "string"
            and position.cfi:match("^epubcfi%(.+%)$") ~= nil
            and type(position.xpointer) == "string"
            and position.xpointer ~= ""
    end
    local function clearQueue()
        sync.queue._store.data = {}
        sync.queue._store:flush()
    end

    -- Capture both ends from the rendered document. The server position is a
    -- real CFI produced near 72%; the device position is independently read
    -- near 24%. This fails on one-page or malformed fixtures instead of merely
    -- painting a plausible dialog over them.
    local remote = gotoPercent(72)
    local device = gotoPercent(24)
    self:_assert("reader produces a valid device CFI", validPosition(device),
        "valid CFI", tostring(device.cfi))
    self:_assert("reader produces a valid server CFI", validPosition(remote),
        "valid CFI", tostring(remote.cfi))
    self:_assert("fixture exposes meaningfully separated positions",
        remote.percentage > device.percentage + 20
            and remote.cfi ~= device.cfi
            and remote.xpointer ~= device.xpointer,
        "> 20 percentage points and distinct CFI/XPointer",
        string.format("device=%.2f server=%.2f", device.percentage, remote.percentage))
    if not validPosition(device) or not validPosition(remote) then
        error("opened EPUB did not yield two valid KOReader CFI positions")
    end

    -- The fake boundary speaks in the same response/result shapes as the
    -- async HTTP worker. It never supplies document positions: those always
    -- originate above from KOReader and pass through production pull/push code.
    clearQueue()
    sync.pulled = false
    sync.awaiting_decision = false
    local remote_server = {
        progress = { percentage = remote.percentage, cfi = remote.cfi },
        expect_pull = false, gets = 0, puts = 0, uploaded = nil,
    }
    sync._async = {
        run = function(_, _task, done)
            if remote_server.expect_pull then
                remote_server.expect_pull = false
                remote_server.gets = remote_server.gets + 1
                done({
                    code = 200,
                    body = json.encode({ epubProgress = remote_server.progress }),
                    auth = { token = "visual-access-token" },
                })
                return
            end
            local items = sync.queue:currentBookDrainable(sync.book_id,
                sync.username, sync.server_url, sync.file_id, sync.file_type)
            local entry = items[1] and items[1].entry
            remote_server.puts = remote_server.puts + 1
            remote_server.uploaded = entry and {
                percentage = entry.percentage,
                cfi = entry.position_data,
            } or nil
            if entry then
                remote_server.progress = {
                    percentage = entry.percentage, cfi = entry.position_data,
                }
            end
            done({
                results = {{
                    success = entry ~= nil,
                    remote_percentage = entry and entry.percentage or nil,
                    remote_position = entry and entry.position_data or nil,
                }},
                auth = { token = "visual-access-token" },
            })
        end,
    }
    local function pullFromServer()
        remote_server.expect_pull = true
        sync:pullProgress()
    end

    pullFromServer()
    local root = UIManager:getTopmostVisibleWidget()
    self:_assert("real server-ahead conflict shown over reader",
        root ~= nil and root ~= reader and sync.awaiting_decision == true,
        "conflict dialog", root and "conflict dialog" or "absent")
    self:_assert("sync conflict exposes both decisions",
        root and type(root.choice1_callback) == "function"
            and type(root.choice2_callback) == "function",
        "two callbacks", root and type(root.choice1_callback) == "function"
            and type(root.choice2_callback) == "function" and "two callbacks"
            or (root and "callbacks missing" or "absent"))
    local after_capture = function()
        -- Journey one: Jump Ahead converts the genuine server CFI back into an
        -- XPointer and asks ReaderUI to navigate there.
        root.choice1_callback()
        local jumped = {
            percentage = math.floor(sync:getPercentage() * 10000) / 100,
            cfi = sync:getPositionData(),
            xpointer = reader.document:getXPointer(),
        }
        self:_assert("Jump Ahead moves the real reader forward",
            jumped.percentage > device.percentage + 20
                and jumped.xpointer ~= device.xpointer,
            "reader moved > 20 percentage points", jumped.percentage)
        self:_assert("Jump Ahead lands on the server CFI",
            jumped.cfi == remote.cfi or jumped.xpointer == remote.xpointer,
            remote.cfi, jumped.cfi)
        self:_assert("Jump Ahead releases the conflict gate",
            sync.awaiting_decision == false and sync.pulled == true,
            "released", tostring(sync.awaiting_decision))
        UIManager:close(root)

        -- A repeat pull at the landed position must be clean: no conflict and
        -- no pending book should remain.
        pullFromServer()
        self:_assert("second sync after Jump Ahead has no conflict",
            sync.awaiting_decision == false and sync.pulled == true
                and UIManager:getTopmostVisibleWidget() == reader,
            "clean", tostring(sync.awaiting_decision))
        self:_assert("Jump Ahead leaves no pending sync",
            sync:pendingCount() == 0, 0, sync:pendingCount())

        -- Journey two: return to another genuine local position, receive the
        -- same server-ahead conflict, and choose Sync Here. PageUpdate may
        -- enqueue while arranging the test, so discard that setup-only event;
        -- the entry inspected below must be created by pushProgress itself.
        local local_push = gotoPercent(31)
        self:_assert("Sync Here starts from another valid device CFI",
            validPosition(local_push), "valid CFI", tostring(local_push.cfi))
        clearQueue()
        sync.pulled = false
        sync.awaiting_decision = false
        remote_server.progress = {
            percentage = remote.percentage, cfi = remote.cfi,
        }
        pullFromServer()
        local second_conflict = UIManager:getTopmostVisibleWidget()
        self:_assert("second real conflict is detected",
            second_conflict ~= reader and sync.awaiting_decision == true,
            "conflict dialog", second_conflict == reader and "reader" or "dialog")
        second_conflict.choice2_callback()
        local uploaded = remote_server.uploaded
        self:_assert("Sync Here performs one production push",
            remote_server.puts == 1, 1, remote_server.puts)
        self:_assert("Sync Here uploads the reader's actual percentage",
            uploaded and math.abs(uploaded.percentage - local_push.percentage) < 0.01,
            local_push.percentage, uploaded and uploaded.percentage or "absent")
        self:_assert("Sync Here uploads the reader's actual CFI",
            uploaded and uploaded.cfi == local_push.cfi,
            local_push.cfi, uploaded and uploaded.cfi or "absent")
        self:_assert("successful push removes the durable queue entry",
            sync.queue:size() == 0, 0, sync.queue:size())
        UIManager:close(second_conflict)

        -- The fake server now returns exactly what production pushProgress
        -- uploaded. A final production pull must therefore be conflict-free.
        pullFromServer()
        self:_assert("second sync after Sync Here clears conflict and pending",
            remote_server.gets == 4
                and sync.awaiting_decision == false and sync.pulled == true
                and sync:pendingCount() == 0
                and UIManager:getTopmostVisibleWidget() == reader,
            "4 pulls, no conflict, no pending",
            string.format("pulls=%d conflict=%s pending=%d",
                remote_server.gets, tostring(sync.awaiting_decision), sync:pendingCount()))

        -- Continue in the same genuinely rendered document: production hooks
        -- now prove that sessions and annotations carry KOReader-derived EPUB
        -- positions too, rather than being validated only with hand-written
        -- CFI strings in isolated unit tests.
        self:_exerciseReaderSession(sync, gotoPercent)
        self:_exerciseReaderAnnotations(sync, reader, gotoPercent)
    end
    return root, after_capture
end

function VisualDriver:_showMainMenu(app, scenario, submenu)
    local Menu = require("ui/widget/menu")
    local stage, restore_state = self:_withFixtureStage(app, scenario)
    local original_tailscale = app.tailscale
    app.tailscale = { isInstalled = function() return true end }
    local items = {}
    app:addToMainMenu(items)
    local grimmory = items.grimmory
    local rows = grimmory and grimmory.sub_item_table or {}
    if submenu then
        local wanted = submenu == "settings" and "Settings" or "Tailscale"
        local parent
        for _, item in ipairs(rows) do if item.text == wanted then parent = item break end end
        rows = parent and parent.sub_item_table or {}
    end
    local root = InputContainer:new{
        dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() },
    }
    local title = submenu == "settings" and "Grimmory Settings"
        or (submenu == "tailscale" and "Tailscale" or "Grimmory")
    local menu = Menu:new{
        show_parent = root,
        title = title,
        item_table = rows,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
    }
    table.insert(root, menu)
    UIManager:show(root)
    self:_assert("main menu production rows present", #rows > 0,
        "> 0", #rows)
    if not submenu then
        local account_action = rows[1] and rows[1].text_func
            and rows[1].text_func() or (rows[1] and rows[1].text)
        self:_assert("signed-in main menu starts with Add account",
            account_action == "Add account", "Add account",
            account_action or "absent")
    end
    if submenu == "settings" then
        local account_label = rows[1] and rows[1].text_func and rows[1].text_func() or ""
        self:_assert("settings menu shows active account identity",
            account_label:find(app.username, 1, true) ~= nil
                and account_label:find(app.server_url, 1, true) ~= nil,
            "username and server", account_label)
    end
    if submenu == "tailscale" then
        local install
        for _, item in ipairs(rows) do if item.text == "Install Tailscale" then install = item end end
        self:_assert("Tailscale menu exposes explicit Install action", install ~= nil,
            "Install Tailscale", install and install.text or "absent")
        self:_assert("Tailscale Install is disabled when already installed",
            install and type(install.enabled_func) == "function"
                and install.enabled_func() == false,
            false, install and type(install.enabled_func) == "function"
                and install.enabled_func() or "absent")
    end
    return root, function()
        app.tailscale = original_tailscale
        restore_state()
        if UIManager:isWidgetShown(stage) then UIManager:close(stage) end
    end
end

function VisualDriver:_build(app, scenario)
    if scenario.kind == "wifi" then
        return self:_showWifi(app, scenario)
    elseif scenario.kind == "connection" then
        return self:_showConnection(app, scenario)
    elseif scenario.kind == "connection_detail" then
        return self:_showConnectionDetail(app, scenario)
    elseif scenario.kind == "connection_error" then
        return self:_showConnectionError(app, scenario)
    elseif scenario.kind == "dashboard" then
        return self:_showDashboard(app, scenario)
    elseif scenario.kind == "sidebar" then
        return self:_showSidebar(app, scenario)
    elseif scenario.kind == "book_list" then
        return self:_showBookList(app, scenario)
    elseif scenario.kind == "view_options" then
        return self:_showViewOptions(app, scenario)
    elseif scenario.kind == "sort_menu" then
        return self:_showSortMenu(app, scenario)
    elseif scenario.kind == "filter_menu" then
        return self:_showFilterMenu(app, scenario)
    elseif scenario.kind == "filter_values" then
        return self:_showFilterValues(app, scenario)
    elseif scenario.kind == "search_dialog" then
        return self:_showSearchDialog(app, scenario)
    elseif scenario.kind == "search_results" then
        return self:_showSearchResults(app, scenario)
    elseif scenario.kind == "book_detail" then
        return self:_showBookDetail(app, scenario)
    elseif scenario.kind == "download_formats" then
        return self:_showDownloadFormats(app, scenario)
    elseif scenario.kind == "login_dialog" then
        return self:_showLoginDialog(app, scenario)
    elseif scenario.kind == "account_switcher" then
        return self:_showAccountSwitcher(app, scenario)
    elseif scenario.kind == "download_folder" then
        return self:_showDownloadFolder(app, scenario)
    elseif scenario.kind == "main_menu" then
        return self:_showMainMenu(app, scenario)
    elseif scenario.kind == "settings_menu" then
        return self:_showMainMenu(app, scenario, "settings")
    elseif scenario.kind == "tailscale_menu" then
        return self:_showMainMenu(app, scenario, "tailscale")
    elseif scenario.kind == "sign_out_confirm" then
        return self:_showSignOutConfirm(app, scenario)
    elseif scenario.kind == "uninstall_confirm" then
        return self:_showUninstallConfirm(app, scenario)
    elseif scenario.kind == "update_available" then
        return self:_showUpdateAvailable(app, scenario)
    elseif scenario.kind == "tailscale_install_prompt" then
        return self:_showTailscaleInstallPrompt(app, scenario)
    elseif scenario.kind == "tailscale_status" then
        return self:_showTailscaleStatus(app, scenario)
    elseif scenario.kind == "tailscale_auth" then
        return self:_showTailscaleAuth(app, scenario)
    elseif scenario.kind == "tailscale_auth_qr" then
        return self:_showTailscaleAuthQr(app, scenario)
    elseif scenario.kind == "sync_main_menu" then
        return self:_showSyncMainMenu(app, scenario)
    elseif scenario.kind == "offline_wifi_prompt" then
        return self:_showOfflineWifiPrompt(app, scenario)
    elseif scenario.kind == "download_progress" then
        return self:_showDownloadProgress(app, scenario)
    elseif scenario.kind == "long_error" then
        return self:_showLongError(app, scenario)
    elseif scenario.kind == "reader_download_open" then
        return self:_showReaderDownload(app, scenario)
    elseif scenario.kind == "reader_open" then
        return self:_showReader(app, scenario, false)
    elseif scenario.kind == "reader_sync_conflict" then
        return self:_showReader(app, scenario, true)
    end
    error("unknown scenario kind: " .. tostring(scenario.kind))
end

function VisualDriver:_writeResult(result)
    local result_path = joinPath(self.output_dir, self.artifact_name .. ".json")
    local temporary_path = result_path .. ".tmp"
    local file, err = io.open(temporary_path, "wb")
    if not file then
        logger.err("visual driver could not write result:", err)
        return false
    end
    local encoded_ok, encoded = pcall(json.encode, result)
    if not encoded_ok then
        file:close()
        os.remove(temporary_path)
        logger.err("visual driver could not encode result:", encoded)
        return false
    end
    file:write(encoded)
    file:write("\n")
    file:close()
    os.remove(result_path)
    local ok, rename_err = os.rename(temporary_path, result_path)
    if not ok then
        logger.err("visual driver could not publish result:", rename_err)
        return false
    end
    return true
end

function VisualDriver:_finish(fatal_error, root, cleanup, after_capture)
    -- tickAfterNext is deliberately used instead of a time delay: KOReader
    -- documents it as the way to run callbacks without skipping repaints.
    UIManager:tickAfterNext(function()
        local screenshot_path = joinPath(self.output_dir, self.artifact_name .. ".png")
        local shot_ok, shot_err = pcall(Screen.shot, Screen, screenshot_path)
        if not shot_ok then
            fatal_error = fatal_error or ("screenshot failed: " .. tostring(shot_err))
        end
        local screenshot_sha
        if shot_ok then
            local hash_err
            screenshot_sha, hash_err = sha256File(screenshot_path)
            if not screenshot_sha then
                fatal_error = fatal_error or ("screenshot hashing failed: " .. tostring(hash_err))
            end
        end
        if after_capture then
            local action_ok, action_err = pcall(after_capture)
            if not action_ok then
                fatal_error = fatal_error or ("post-capture action failed: " .. tostring(action_err))
            end
        end

        local outcome, outcome_err = outcomeEvidence(self.assertions)
        if not outcome then
            fatal_error = fatal_error or outcome_err
        end
        local passed = fatal_error == nil
        for _, assertion in ipairs(self.assertions) do
            if not assertion.pass then
                passed = false
                break
            end
        end
        local result = {
            version = 2,
            scenario = self.scenario_name,
            source_fingerprint = self.source_fingerprint or "missing",
            status = passed and "passed" or "failed",
            error = fatal_error,
            screenshot = shot_ok and screenshot_path or nil,
            screenshot_sha256 = screenshot_sha,
            screen = {
                width = Screen:getWidth(),
                height = Screen:getHeight(),
                orientation = Screen:getWidth() > Screen:getHeight() and "landscape" or "portrait",
            },
            assertions = self.assertions,
            outcome = outcome,
            data_profile = self.data_profile or "synthetic-ci",
            real_book_id = self.real_book_id,
            real_file_id = self.real_file_id,
            source_book_id = self.real_book_id,
            validation_class = os.getenv("GRIMMORY_VISUAL_VALIDATION_CLASS")
                or "synthetic-ci-baseline",
            fixture_mode = os.getenv("GRIMMORY_VISUAL_FIXTURE_MODE")
                or "synthetic-injected",
            epub_sha256 = os.getenv("GRIMMORY_VISUAL_EPUB_SHA256"),
            metadata_provenance = self.metadata_provenance,
            koreader = {
                version = os.getenv("GRIMMORY_VISUAL_KOREADER_VERSION"),
                commit = os.getenv("GRIMMORY_VISUAL_KOREADER_COMMIT"),
            },
        }
        local write_ok, wrote = pcall(self._writeResult, self, result)
        if not write_ok then
            logger.err("visual driver result write failed:", wrote)
            wrote = false
        end

        if root and UIManager:isWidgetShown(root) then
            UIManager:close(root)
        end
        if cleanup then
            local cleanup_ok, cleanup_err = pcall(cleanup)
            if not cleanup_ok then
                logger.warn("visual driver cleanup failed:", cleanup_err)
            end
        end
        UIManager:quit((passed and wrote) and 0 or 1)
    end)
end

function VisualDriver:_startWhenReady(attempt)
    local fingerprint_digest = self.source_fingerprint
        and self.source_fingerprint:match("^sha256:([0-9a-f]+)$")
    if not fingerprint_digest or #fingerprint_digest ~= 64 then
        self:_finish("GRIMMORY_VISUAL_SOURCE_FINGERPRINT is missing or invalid")
        return
    end
    local scenario = scenarios[self.scenario_name]
    if not scenario then
        self:_finish("unknown scenario: " .. tostring(self.scenario_name))
        return
    end
    local app = self:_pluginInstance()
    if not app then
        if attempt < 30 then
            UIManager:scheduleIn(0.1, function()
                self:_startWhenReady(attempt + 1)
            end)
            return
        end
        self:_finish("Grimmory plugin instance was not loaded")
        return
    end

    local resolve_ok, resolved_or_err = pcall(self._resolveScenarioData, self, scenario)
    if not resolve_ok then
        self:_finish(tostring(resolved_or_err))
        return
    end
    scenario = resolved_or_err

    local restore_device = self:_setTouchKindleProfile()
    local ok, root, cleanup, after_capture = pcall(self._build, self, app, scenario)
    if not ok then
        restore_device()
        self:_finish(tostring(root))
        return
    end
    self:_finish(nil, root, function()
        if cleanup then cleanup() end
        restore_device()
    end, after_capture)
end

return VisualDriver
