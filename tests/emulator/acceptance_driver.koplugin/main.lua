-- Test-only driver for the disposable full Grimmory/MariaDB acceptance lane.
-- It is copied beside the two production plugins in an isolated KO_HOME and
-- is never shipped in the release archive.

local DataStorage = require("datastorage")
local Device = require("device")
local Event = require("ui/event")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local json = require("json")
local util = require("util")
local Exactness = require("acceptance_exactness")

local Screen = Device.screen
local started = false

local Driver = WidgetContainer:extend{
    name = "acceptance_driver",
    is_doc_only = false,
}

local function join(parent, child)
    return parent:gsub("[/\\]+$", "") .. "/" .. child
end

local function readJson(path)
    local handle, err = io.open(path, "rb")
    if not handle then error("cannot read JSON: " .. tostring(err)) end
    local bytes = handle:read("*a")
    handle:close()
    local ok, value = pcall(json.decode, bytes)
    if not ok or type(value) ~= "table" then
        error("invalid JSON: " .. tostring(value))
    end
    return value
end

-- KOReader's decoder represents JSON null as a callable sentinel. The
-- production API normalizer removes it from DTOs; do the same for the private
-- expected-value descriptor before comparing the two.
local function stripNull(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return value end
    seen[value] = true
    for key, child in pairs(value) do
        if type(child) == "function" then
            value[key] = nil
        elseif type(child) == "table" then
            stripNull(child, seen)
        end
    end
    return value
end

local function findWidget(root, predicate, seen, depth)
    if type(root) ~= "table" then return nil end
    seen = seen or {}
    depth = depth or 0
    if seen[root] or depth > 40 then return nil end
    seen[root] = true
    if predicate(root) then return root end
    for index = 1, #root do
        local found = findWidget(root[index], predicate, seen, depth + 1)
        if found then return found end
    end
end

local function collectText(root, out, seen, depth)
    if type(root) ~= "table" then return end
    out = out or {}
    seen = seen or {}
    depth = depth or 0
    if seen[root] or depth > 40 then return out end
    seen[root] = true
    if type(root.text) == "string" and root.text ~= "" then
        out[#out + 1] = root.text
    end
    if type(root.title) == "string" and root.title ~= "" then
        out[#out + 1] = root.title
    end
    for index = 1, #root do
        collectText(root[index], out, seen, depth + 1)
    end
    return out
end

local function textContains(root, needle)
    if type(needle) ~= "string" or needle == "" then return false end
    for _, text in ipairs(collectText(root) or {}) do
        if text:find(needle, 1, true) then return true end
    end
    return false
end

local function textEquals(root, needle)
    if type(needle) ~= "string" or needle == "" then return false end
    for _, text in ipairs(collectText(root) or {}) do
        if text == needle then return true end
    end
    return false
end

local function rendersImageFile(root, path)
    if type(path) ~= "string" or path == "" then return false end
    return findWidget(root, function(widget)
        return widget.file == path
    end) ~= nil
end

local function withinScreen(widget)
    local dimen = widget and widget.dimen
    if not dimen or type(dimen.x) ~= "number" or type(dimen.y) ~= "number"
            or type(dimen.w) ~= "number" or type(dimen.h) ~= "number" then
        return false
    end
    return dimen.x >= 0 and dimen.y >= 0 and dimen.w > 0 and dimen.h > 0
        and dimen.x + dimen.w <= Screen:getWidth()
        and dimen.y + dimen.h <= Screen:getHeight()
end

local function rectOf(widget)
    local dimen = widget and widget.dimen
    if not dimen then return nil end
    return { x = dimen.x, y = dimen.y, w = dimen.w, h = dimen.h }
end

local function findWidgetPath(root, predicate, path, seen, depth)
    if type(root) ~= "table" then return nil end
    path = path or {}
    seen = seen or {}
    depth = depth or 0
    if seen[root] or depth > 40 then return nil end
    seen[root] = true
    path[#path + 1] = root
    if predicate(root) then return path end
    for index = 1, #root do
        local child_path = {}
        for path_index, ancestor in ipairs(path) do
            child_path[path_index] = ancestor
        end
        local found = findWidgetPath(root[index], predicate, child_path,
            seen, depth + 1)
        if found then return found end
    end
end

local function equalArray(a, b)
    if a == nil and b == nil then return true end
    if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then return false end
    for index = 1, #a do
        if tostring(a[index]) ~= tostring(b[index]) then return false end
    end
    return true
end

local function equalSet(a, b)
    if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then return false end
    local counts = {}
    for _, item in ipairs(a) do
        local key = tostring(item)
        counts[key] = (counts[key] or 0) + 1
    end
    for _, item in ipairs(b) do
        local key = tostring(item)
        if not counts[key] or counts[key] == 0 then return false end
        counts[key] = counts[key] - 1
    end
    return true
end

local function sameScalar(a, b)
    return Exactness.sameScalar(a, b)
end

local function coverCardForExactTitle(root, title)
    local path = findWidgetPath(root, function(widget)
        return widget.text == title
    end)
    if not path then return nil end
    for index = #path - 1, 1, -1 do
        if type(path[index].onTap) == "function" then return path[index] end
    end
end

local function sha256File(path)
    local handle = io.open(path, "rb")
    if not handle then return nil end
    local bytes = handle:read("*a")
    handle:close()
    return require("ffi/sha2").sha256(bytes)
end

function Driver:init()
    self.mode = os.getenv("GRIMMORY_ACCEPTANCE_MODE")
    if self.mode ~= "metadata" and self.mode ~= "reader" then return end
    if started then return end
    started = true

    self.runtime_path = assert(os.getenv("GRIMMORY_ACCEPTANCE_RUNTIME"),
        "GRIMMORY_ACCEPTANCE_RUNTIME is required")
    self.output_dir = assert(os.getenv("GRIMMORY_ACCEPTANCE_OUTPUT"),
        "GRIMMORY_ACCEPTANCE_OUTPUT is required")
    util.makePath(self.output_dir)
    self.runtime = stripNull(readJson(self.runtime_path))
    self.alias = os.getenv("GRIMMORY_ACCEPTANCE_ALIAS")
    self.phase = os.getenv("GRIMMORY_ACCEPTANCE_PHASE")
    if self.mode == "reader" then
        assert(self.phase == "jump" or self.phase == "sync-here",
            "reader acceptance requires jump or sync-here phase")
        if self.phase == "sync-here" then
            local prior_path = assert(os.getenv("GRIMMORY_ACCEPTANCE_PRIOR_RESULT"),
                "sync-here phase requires the jump result")
            self.prior_result = stripNull(readJson(prior_path))
        end
    end
    self.assertions = {}
    self.screenshots = {}
    self.started_at = os.time()
    self.timeout_at = self.started_at + tonumber(os.getenv(
        "GRIMMORY_ACCEPTANCE_TIMEOUT") or "180")

    -- Desktop KOReader has no physical Wi-Fi manager. Model the emulator as a
    -- connected device while leaving every HTTP call and production callback
    -- untouched.
    self._network_originals = {
        isWifiOn = NetworkMgr.isWifiOn,
        isConnected = NetworkMgr.isConnected,
    }
    NetworkMgr.isWifiOn = function() return true end
    NetworkMgr.isConnected = function() return true end

    UIManager:nextTick(function() self:_waitForApp() end)
end

function Driver:_app()
    if self.ui and self.ui.grimmory then return self.ui.grimmory end
    local loader = self.ui and self.ui.pluginloader
    if loader and loader.getPluginInstance then
        return loader:getPluginInstance("grimmory")
    end
end

function Driver:_assert(name, pass)
    self.assertions[#self.assertions + 1] = {
        name = name,
        pass = pass and true or false,
    }
    if not pass then error("assertion failed: " .. name) end
end

function Driver:_later(seconds, callback)
    if os.time() > self.timeout_at then
        self:_finish("acceptance journey timed out")
        return
    end
    UIManager:scheduleIn(seconds, function()
        local ok, err = pcall(callback)
        if not ok then self:_finish(tostring(err)) end
    end)
end

function Driver:_waitUntil(label, predicate, callback, timeout)
    local deadline = os.time() + (timeout or 30)
    local function poll()
        local ok, result = pcall(predicate)
        if ok and result then callback(result); return end
        if os.time() >= deadline then
            error("timed out waiting for " .. label
                .. (ok and "" or (": " .. tostring(result))))
        end
        self:_later(0.2, poll)
    end
    poll()
end

function Driver:_closeTopMessages()
    for dummy = 1, 8 do
        local top = UIManager:getTopmostVisibleWidget()
        if not top or top == self.ui then return end
        -- Do not close the production library or reader screens.
        if top == self.app.dashboard_widget or top == self.app.detail_widget
                or top == self.app.book_list_widget then return end
        if top.choice1_callback or top.choice2_callback then return end
        UIManager:close(top)
    end
end

function Driver:_capture(name, root)
    local path = join(self.output_dir, name .. ".png")
    -- Drain any queued cropped-child repaint from the final async detail
    -- rebuild first. Combining that stale partial repaint with a new full
    -- stack request can leave the child painted last at (0,0), visually
    -- covering the fixed top and bottom bars.
    UIManager:forceRePaint()
    -- Acceptance screenshots represent the whole visible device. Repaint the
    -- complete window stack: repainting only a recently rebuilt child can
    -- leave unrelated top/bottom chrome stale in the shared framebuffer.
    UIManager:setDirty("all", "ui")
    -- Screen.shot reads the current framebuffer; setDirty only queues work for
    -- a later UI tick. Force the queued production widgets to paint first so
    -- the artifact records the state requested by this journey (especially a
    -- new scroll offset), rather than whichever frame happened to be present.
    UIManager:forceRePaint()
    -- Paint the exact current top-level widget synchronously as the final
    -- framebuffer writer. Cropped children may enqueue their own repaint while
    -- a detail page is rebuilt; painting only the queue can therefore leave a
    -- body-only frame even though the fixed header/footer are valid in the
    -- widget tree. This uses KOReader's normal widget paint boundary and does
    -- not alter application state.
    if root and root.dimen then
        UIManager:widgetRepaint(root, root.dimen.x, root.dimen.y)
    end
    local ok, err = pcall(Screen.shot, Screen, path)
    if not ok then error("screenshot failed: " .. tostring(err)) end
    self.screenshots[#self.screenshots + 1] = name .. ".png"
    return path
end

function Driver:_preserveCover(alias, source)
    local extension = source and source:match("%.([%w]+)$") or "jpg"
    local name = alias .. "-server-cover." .. tostring(extension)
    local input = assert(io.open(source, "rb"))
    local bytes = input:read("*a")
    input:close()
    local output = assert(io.open(join(self.output_dir, name), "wb"))
    output:write(bytes)
    output:close()
    self.cover_artifacts = self.cover_artifacts or {}
    self.cover_artifacts[alias] = name
end

function Driver:_bookDescriptor(alias)
    for _, book in ipairs(self.runtime.books or {}) do
        if book.alias == alias then return book end
    end
end

function Driver:_serverBook(id)
    for _, book in ipairs(self.app.cached_books or {}) do
        if tonumber(book.id) == tonumber(id) then return book end
    end
end

function Driver:_waitForApp()
    local app = self:_app()
    if not app then
        self:_later(0.1, function() self:_waitForApp() end)
        return
    end
    self.app = app
    self:_login()
end

function Driver:_login()
    self.app:showLoginDialog()
    local dialog = self.app.login_dialog
    self:_assert("production login dialog opens", dialog ~= nil)
    local values = {
        self.runtime.baseUrl, self.runtime.username, self.runtime.password,
    }
    for index, value in ipairs(values) do
        local field = dialog.input_fields and dialog.input_fields[index]
        self:_assert("production login field " .. index .. " exists", field ~= nil)
        field:setText(value)
    end
    local submit = findWidget(dialog, function(widget)
        return widget.text == "Login" and type(widget.callback) == "function"
    end)
    self:_assert("production Login button exists", submit ~= nil)
    submit.callback()
    self:_waitUntil("production login", function()
        return self.app.session and self.app.session:isLoggedIn()
    end, function()
        self:_assert("production login action authenticates", true)
        self:_closeTopMessages()
        -- These are the exact callbacks used by the Settings checkboxes.
        self.app:_setSyncOption("sync_annotations", true)
        -- The dedicated session journey enables this only after it has moved
        -- to an independently observed rendered start position.  Otherwise
        -- the earlier annotation navigation would contaminate the session's
        -- start and make the expected fingerprint come from its own queue.
        self.app:_setSyncOption("sync_reading_sessions", false)
        self.app:browseLibrary()
        self:_waitUntil("full library", function()
            return type(self.app.cached_books) == "table"
                and #self.app.cached_books == #(self.runtime.books or {})
                and self.app.dashboard_widget
        end, function()
            if self.mode == "metadata" then
                self:_metadataJourney()
            else
                self:_readerJourney()
            end
        end, 60)
    end, 30)
end

local METADATA_SCALARS = {
    "title", "subtitle", "description", "seriesName", "seriesNumber",
    "seriesTotal", "publisher", "publishedDate", "pageCount", "language",
    "isbn10", "isbn13", "amazonRating", "amazonReviewCount",
    "goodreadsRating", "goodreadsReviewCount", "hardcoverRating",
    "hardcoverReviewCount",
}

local METADATA_ARRAYS = { "authors" }
local METADATA_SETS = { "categories", "tags", "moods" }

function Driver:_verifyMetadata(book, descriptor)
    local actual = book.metadata or {}
    local expected = descriptor.expectedKoreaderMetadata or {}
    for _, key in ipairs(METADATA_SCALARS) do
        self:_assert(descriptor.alias .. " exact metadata field " .. key,
            sameScalar(actual[key], expected[key]))
    end
    for _, key in ipairs(METADATA_ARRAYS) do
        self:_assert(descriptor.alias .. " exact metadata array " .. key,
            equalArray(actual[key] or {}, expected[key] or {}))
    end
    for _, key in ipairs(METADATA_SETS) do
        self:_assert(descriptor.alias .. " exact metadata set " .. key,
            equalSet(actual[key] or {}, expected[key] or {}))
    end
    self:_assert(descriptor.alias .. " exact review records",
        Exactness.equalRecords(actual.bookReviews or {}, expected.bookReviews or {}))
    self:_assert(descriptor.alias .. " exact personal rating",
        sameScalar(book.personalRating, expected.personalRating))
    self:_assert(descriptor.alias .. " exact metadata match score",
        sameScalar(book.metadataMatchScore, expected.metadataMatchScore))
end

local function firstThreeSorted(books, field)
    local selected = {}
    for _, book in ipairs(books or {}) do
        if book[field] and book[field] ~= "" then selected[#selected + 1] = book end
    end
    table.sort(selected, function(left, right)
        return tostring(left[field]) > tostring(right[field])
    end)
    while #selected > 3 do table.remove(selected) end
    return selected
end

local function descriptorForBook(runtime, book)
    for _, descriptor in ipairs(runtime.books or {}) do
        if tonumber(descriptor.serverBookId) == tonumber(book.id) then
            return descriptor
        end
    end
end

local function dashboardBooks(app)
    local candidates = firstThreeSorted(app.cached_books, "lastReadTime")
    local recent = firstThreeSorted(app.cached_books, "addedOn")
    for _, book in ipairs(recent) do candidates[#candidates + 1] = book end
    if #candidates == 0 then
        for index = 1, math.min(3, #app.cached_books) do
            candidates[#candidates + 1] = app.cached_books[index]
        end
    end
    local seen, visible = {}, {}
    for _, book in ipairs(candidates) do
        if not seen[tostring(book.id)] then
            seen[tostring(book.id)] = true
            visible[#visible + 1] = book
        end
    end
    return visible
end

function Driver:_assertDashboardMetadata()
    local root = self.app.dashboard_widget
    local cards = dashboardBooks(self.app)
    for _, book in ipairs(cards) do
        local descriptor = descriptorForBook(self.runtime, book)
        local expected = descriptor and descriptor.expectedKoreaderMetadata or {}
        local card = coverCardForExactTitle(root, expected.title)
        self:_assert(descriptor.alias .. " dashboard exact card exists", card ~= nil)
        self:_assert(descriptor.alias .. " dashboard title rendered",
            card and textEquals(card, expected.title))
        if expected.authors and expected.authors[1] then
            local displayed_author = expected.authors[1]
                .. (#expected.authors > 1 and " …" or "")
            self:_assert(descriptor.alias .. " dashboard author rendered",
                card and textEquals(card, displayed_author))
        end
        local cover_path = self.app:cachedCoverPath(book)
        self:_assert(descriptor.alias .. " dashboard exact cover state",
            (cover_path ~= nil) == (expected.coverPresent == true))
        if expected.coverPresent then
            self:_assert(descriptor.alias .. " dashboard cover widget rendered",
                rendersImageFile(root, cover_path))
        end
    end
    return cards
end

local function roundedRating(rating)
    return tostring(math.floor(tonumber(rating) / 5 * 100 + 0.5)) .. "%"
end

local function reviewCountLabel(value)
    value = tonumber(value)
    if not value then return nil end
    if value >= 1000 then
        local scaled = math.floor(value / 100) / 10
        return tostring(scaled):gsub("%.0$", "") .. "k"
    end
    return tostring(value)
end

function Driver:_assertDetailRendering(root, book, descriptor)
    local expected = descriptor.expectedKoreaderMetadata or {}
    self:_assert(descriptor.alias .. " detail title rendered",
        textEquals(root, expected.title))
    local author_widget = findWidget(root, function(widget)
        return type(widget.text) == "string"
            and widget.text:find("By: ", 1, true) == 1
    end)
    local expected_author_line = #(expected.authors or {}) > 0
        and "By: " .. table.concat(expected.authors, ", ") or nil
    self:_assert(descriptor.alias .. " exact detail author line",
        expected_author_line and author_widget
            and author_widget.text == expected_author_line
            or (not expected_author_line and not author_widget))

    local optional_text = {
        { "subtitle", expected.subtitle },
        { "series", expected.seriesName },
        { "publisher", expected.publisher },
        { "published date", expected.publishedDate },
        { "page count", expected.pageCount and tostring(expected.pageCount) },
        { "language", expected.language },
        { "ISBN", expected.isbn13 or expected.isbn10 },
    }
    for _, field in ipairs(optional_text) do
        if field[2] then
            self:_assert(descriptor.alias .. " detail " .. field[1] .. " rendered",
                textContains(root, tostring(field[2])))
        end
    end
    -- Category/tag ordering is not part of the replay provenance contract:
    -- the cache canonicalizes those fields as sets. Production renders the
    -- already-verified enriched Book DTO in its received order, so use that
    -- exact live sequence for the ordered widget projection.
    local live_metadata = book.metadata or {}
    local expected_genres = Exactness.detailGenreSequence(
        live_metadata.categories or {}, live_metadata.tags or {})
    local genre_path = findWidgetPath(root, function(widget)
        return widget.text == "Genres"
    end)
    -- Production nests the Genres label row in the section VerticalGroup; the
    -- grandparent therefore contains exactly the label plus every wrapped
    -- chip, and excludes reviews/recommendations elsewhere in the detail root.
    local genre_section = genre_path and genre_path[#genre_path - 2]
    local actual_genres = genre_section and collectText(genre_section) or {}
    self:_assert(descriptor.alias .. " exact detail genre chip sequence",
        equalArray(actual_genres, expected_genres))

    self:_assert(descriptor.alias .. " detail personal-rating row rendered",
        textContains(root, "Your rating"))
    if expected.personalRating then
        self:_assert(descriptor.alias .. " detail personal rating rendered",
            textContains(root, tostring(expected.personalRating) .. "/10"))
    else
        self:_assert(descriptor.alias .. " detail unrated state rendered",
            textContains(root, "?/10"))
    end

    local ratings = {
        { "Amazon", expected.amazonRating, expected.amazonReviewCount },
        { "Goodreads", expected.goodreadsRating, expected.goodreadsReviewCount },
        { "Hardcover", expected.hardcoverRating, expected.hardcoverReviewCount },
    }
    for _, rating in ipairs(ratings) do
        if rating[2] then
            self:_assert(descriptor.alias .. " detail " .. rating[1] .. " rating rendered",
                textContains(root, rating[1])
                    and textContains(root, roundedRating(rating[2])))
            if rating[3] then
                self:_assert(descriptor.alias .. " detail " .. rating[1] .. " count rendered",
                    textContains(root, reviewCountLabel(rating[3])))
            end
        else
            self:_assert(descriptor.alias .. " absent " .. rating[1] .. " row omitted",
                not textContains(root, rating[1]))
        end
    end

    if expected.description then
        local description = Exactness.displayedDescription(
            expected.description,
            util.htmlToPlainTextIfHtml,
            function(value) return util.fixUtf8(value, "") end)
        self:_assert(descriptor.alias .. " detail complete displayed description rendered",
            description and textEquals(root, description))
    else
        self:_assert(descriptor.alias .. " absent description controls omitted",
            not textContains(root, "Show more") and not textContains(root, "Show less"))
    end

    local rows = {
        { "Pages", expected.pageCount },
        { "Language", expected.language },
        { "ISBN", expected.isbn13 or expected.isbn10 },
        { "Genres", #expected_genres > 0 },
        { "Reviews", #(expected.bookReviews or {}) > 0 },
        { "Similar Books", #(expected.recommendations or {}) > 0 },
    }
    if expected.publisher then
        rows[#rows + 1] = { "Publisher", true }
    elseif expected.publishedDate then
        rows[#rows + 1] = { "Published", true }
        rows[#rows + 1] = { "Publisher", false }
    else
        rows[#rows + 1] = { "Publisher", false }
        rows[#rows + 1] = { "Published", false }
    end
    for _, row in ipairs(rows) do
        if not row[2] then
            self:_assert(descriptor.alias .. " absent " .. row[1] .. " section omitted",
                not textEquals(root, row[1]))
        else
            self:_assert(descriptor.alias .. " present " .. row[1] .. " section rendered",
                textEquals(root, row[1]))
        end
    end
    local expected_reviews = Exactness.reviewDisplaySequence(
        expected.bookReviews or {},
        function(value) return util.fixUtf8(value, "") end)
    self:_assert(descriptor.alias .. " detail exact ordered review records rendered",
        Exactness.containsOrderedExact(collectText(root) or {}, expected_reviews))
end

function Driver:_assertPaintedDetailChrome(root, descriptor)
    local controls = {
        { "menu", findWidget(root, function(widget)
            return type(widget.text) == "string"
                and widget.text:find("☰", 1, true)
                and type(widget.callback) == "function"
        end) },
        { "search", findWidget(root, function(widget)
            return type(widget.text) == "string"
                and widget.text:find("Title, Author, Series, or ISBN", 1, true)
                and type(widget.callback) == "function"
        end) },
        { "Wi-Fi", findWidget(root, function(widget)
            return widget == self.app.wifi_button
        end) },
        { "close", findWidget(root, function(widget)
            return type(widget.text) == "string"
                and widget.text:find("✕", 1, true)
                and type(widget.callback) == "function"
        end) },
        { "Back", findWidget(root, function(widget)
            return widget.text == "← Back" and type(widget.callback) == "function"
        end) },
        { "action", findWidget(root, function(widget)
            return type(widget.text) == "string"
                and (widget.text:match("^Download") or widget.text == "Read"
                    or widget.text:match("^Choose format"))
                and type(widget.callback) == "function"
        end) },
    }
    for _, control in ipairs(controls) do
        self:_assert(descriptor.alias .. " painted " .. control[1]
                .. " control remains within screen",
            withinScreen(control[2]))
    end
    self.observations = self.observations or {}
    self.observations.detailSurfaces = self.observations.detailSurfaces or {}
    local recorded = {
        screen = { w = Screen:getWidth(), h = Screen:getHeight() },
        controls = {},
    }
    for _, control in ipairs(controls) do
        recorded.controls[control[1]] = rectOf(control[2])
    end
    self.observations.detailSurfaces[descriptor.alias] = recorded
end

function Driver:_metadataJourney()
    local expected_count = #(self.runtime.books or {})
    self:_assert("real server returned every imported book",
        #self.app.cached_books == expected_count)

    -- Let the visible dashboard cards complete their deferred cover batch.
    -- The dashboard intentionally renders only a small recent/reading subset;
    -- every other cover is exercised on that book's detail screen below.
    self:_later(2, function()
        for _, descriptor in ipairs(self.runtime.books or {}) do
            local book = self:_serverBook(descriptor.serverBookId)
            self:_assert(descriptor.alias .. " mapped to live Book DTO", book ~= nil)
            local expected = descriptor.expectedKoreaderMetadata or {}
            self:_assert(descriptor.alias .. " exact list title",
                sameScalar((book.metadata or {}).title, expected.title))
            self:_assert(descriptor.alias .. " exact list authors",
                equalArray((book.metadata or {}).authors or {}, expected.authors or {}))
        end
        local dashboard_cards = self:_assertDashboardMetadata()
        -- Paint the current production dashboard before inspecting absolute
        -- child bounds; TextWidget dimensions are finalized during layout.
        self:_capture("metadata-dashboard", self.app.dashboard_widget)
        -- Reading sessions legitimately change which recent books production
        -- selects for the dashboard. Bounds-check an author from the actual
        -- visible firstThreeSorted set, preferring a unique author so the
        -- observation is tied to one exact card rather than a hardcoded book.
        local visible_descriptor, visible_author
        for _, book in ipairs(dashboard_cards) do
            local descriptor = descriptorForBook(self.runtime, book)
            local author = descriptor and (descriptor.expectedKoreaderMetadata or {}).authors
                and descriptor.expectedKoreaderMetadata.authors[1]
            if author then
                local occurrences = 0
                for _, other in ipairs(dashboard_cards) do
                    local other_descriptor = descriptorForBook(self.runtime, other)
                    local other_author = other_descriptor
                        and (other_descriptor.expectedKoreaderMetadata or {}).authors
                        and other_descriptor.expectedKoreaderMetadata.authors[1]
                    if other_author == author then occurrences = occurrences + 1 end
                end
                if not visible_descriptor or occurrences == 1 then
                    visible_descriptor, visible_author = descriptor, author
                    if occurrences == 1 then break end
                end
            end
        end
        local author_widget = visible_author and findWidget(
            self.app.dashboard_widget,
            function(widget)
                return type(widget.text) == "string"
                    and widget.text:find(visible_author, 1, true) ~= nil
            end) or nil
        local author_path = author_widget and findWidgetPath(
            self.app.dashboard_widget,
            function(widget) return widget == author_widget end) or nil
        local author_card
        if author_path then
            for index = #author_path - 1, 1, -1 do
                local candidate = author_path[index]
                if type(candidate.onTap) == "function" and candidate.dimen then
                    author_card = candidate
                    break
                end
            end
        end
        local author_size = author_widget and author_widget.getSize
            and author_widget:getSize()
        local card_content = author_card and author_card[1]
        local content_size = card_content and card_content.getSize
            and card_content:getSize()
        local author_bounds
        if author_card and author_card.dimen and author_size and content_size then
            -- TextWidget exposes its laid-out size but not an absolute dimen.
            -- The author is the final child in buildCoverCard's VerticalGroup,
            -- so derive the exact painted rectangle from the card's absolute
            -- origin and the production group's total height.
            author_bounds = {
                x = author_card.dimen.x,
                y = author_card.dimen.y + content_size.h - author_size.h,
                w = author_size.w,
                h = author_size.h,
            }
        end
        local dashboard_label = visible_descriptor and visible_descriptor.alias
            or "visible dashboard card"
        self:_assert(dashboard_label .. " dashboard author text widget exists",
            author_widget ~= nil)
        self:_assert(dashboard_label .. " dashboard author exact widget text",
            author_widget and author_widget.text == visible_author)
        self:_assert(dashboard_label .. " dashboard card contains its full content height",
            author_card and author_card.dimen and content_size
                and author_card.dimen.h >= content_size.h)
        self:_assert(dashboard_label .. " dashboard author derived bounds remain on-screen",
            author_bounds and author_bounds.x >= 0 and author_bounds.y >= 0
                and author_bounds.w > 0 and author_bounds.h > 0
                and author_bounds.x + author_bounds.w <= Screen:getWidth()
                and author_bounds.y + author_bounds.h <= Screen:getHeight())
        self:_assert(dashboard_label .. " dashboard author derived bounds remain inside card",
            author_bounds and author_card and author_card.dimen
                and author_bounds.x >= author_card.dimen.x
                and author_bounds.y >= author_card.dimen.y
                and author_bounds.x + author_bounds.w
                    <= author_card.dimen.x + author_card.dimen.w
                and author_bounds.y + author_bounds.h
                    <= author_card.dimen.y + author_card.dimen.h)
        self.observations = self.observations or {}
        self.observations.dashboardVisibleAuthor = {
            alias = visible_descriptor and visible_descriptor.alias,
            text = author_widget and author_widget.text,
            bounds = author_bounds,
            cardBounds = rectOf(author_card),
            contentSize = content_size and {
                w = content_size.w, h = content_size.h,
            } or nil,
        }
        self.app:showSidebar()
        self:_capture("metadata-sidebar", self.app.sidebar_widget)
        UIManager:close(self.app.sidebar_widget)
        self.app.sidebar_widget = nil
        UIManager:close(self.app.dashboard_widget)
        self.app.dashboard_widget = nil
        self.app:showBookList(self.app.cached_books, "All Books",
            function() self.app:showDashboard() end)
        local list_root = self.app.book_list_widget
        local list_menu = findWidget(list_root, function(widget)
            return type(widget.item_table) == "table"
        end)
        for _, descriptor in ipairs(self.runtime.books or {}) do
            local expected = descriptor.expectedKoreaderMetadata or {}
            self:_assert(descriptor.alias .. " appears in all-books list",
                textContains(list_root, expected.title))
            if expected.authors and expected.authors[1] then
                local author_info = false
                local expected_info = table.concat(expected.authors, ", ")
                for _, item in ipairs((list_menu and list_menu.item_table) or {}) do
                    if item.book_data
                            and tonumber(item.book_data.id)
                                == tonumber(descriptor.serverBookId)
                            and item.info == expected_info then
                        author_info = true
                    end
                end
                self:_assert(descriptor.alias .. " exact author list info",
                    author_info)
            end
        end
        self:_capture("metadata-all-books", list_root)
        self.metadata_index = 1
        self:_nextMetadataBook()
    end)
end

function Driver:_nextMetadataBook()
    local descriptor = self.runtime.books[self.metadata_index]
    if not descriptor then self:_finish(); return end
    local book = self:_serverBook(descriptor.serverBookId)
    local expected = descriptor.expectedKoreaderMetadata or {}
    if self.app.book_list_widget then
        UIManager:close(self.app.book_list_widget)
        self.app.book_list_widget = nil
    end

    -- The query is entered into the production search dialog, and its visible
    -- Search button executes the same callback a tap would execute.
    self.app:showSearch()
    self.app.search_dialog:setInputText(expected.title)
    local search = findWidget(self.app.search_dialog, function(widget)
        return widget.text == "Search" and type(widget.callback) == "function"
    end)
    self:_assert(descriptor.alias .. " production search button exists", search ~= nil)
    search.callback()
    local result_root = self.app.book_list_widget
    self:_assert(descriptor.alias .. " exact title search returns result",
        result_root and textContains(result_root, expected.title))
    local result_menu = findWidget(result_root, function(widget)
        return type(widget.item_table) == "table"
    end)
    local expected_result_ids = Exactness.expectedSearchIds(
        self.runtime.books or {}, expected.title)
    local actual_result_ids = Exactness.resultIds(
        (result_menu and result_menu.item_table) or {})
    self:_assert(descriptor.alias .. " exact title search result set",
        equalSet(actual_result_ids, expected_result_ids))
    if expected.authors and expected.authors[1] then
        local author_info = false
        local expected_info = table.concat(expected.authors, ", ")
        for _, item in ipairs((result_menu and result_menu.item_table) or {}) do
            if item.book_data and tonumber(item.book_data.id) == tonumber(book.id)
                    and item.info == expected_info then
                author_info = true
            end
        end
        self:_assert(descriptor.alias .. " exact author search result rendered",
            author_info)
    end
    self:_capture(descriptor.alias .. "-metadata-search", result_root)
    UIManager:close(result_root)
    self.app.book_list_widget = nil

    self.app._back_from_detail = function() end
    self.app:showBookDetail(book)
    self:_waitUntil(descriptor.alias .. " detail enrichment", function()
        if not self.app.detail_widget then return false end
        local has_cover = self.app:cachedCoverPath(book) ~= nil
        if expected.coverPresent and not has_cover then return false end
        local enriched = (book.metadata or {})._enriched == true
        local recommendations_ready = self.app._detail_recs_id == book.id
        return enriched and recommendations_ready
            and self.app._deferred_calls and #self.app._deferred_calls == 0
            and (not self.app.async or not self.app.async:isBusy())
    end, function()
        local root = self.app.detail_widget
        self:_verifyMetadata(book, descriptor)
        self:_assert(descriptor.alias .. " exact recommendation count",
            #(self.app._detail_recs or {}) == #(expected.recommendations or {}))
        for index, recommendation in ipairs(expected.recommendations or {}) do
            local actual_rec = self.app._detail_recs[index]
            local actual_projection = Exactness.recommendationProjection(actual_rec)
            local expected_projection = Exactness.expectedRecommendationProjection(
                recommendation, self.runtime.books or {})
            self:_assert(descriptor.alias .. " exact recommendation record " .. index,
                expected_projection
                    and Exactness.equalExactRecords(actual_projection, expected_projection))
            local recommendation_card = coverCardForExactTitle(root, recommendation.title)
            self:_assert(descriptor.alias .. " exact recommendation card " .. index,
                recommendation_card and textEquals(recommendation_card, recommendation.title))
            local recommendation_author = recommendation.authors and recommendation.authors[1]
            if recommendation_author and recommendation_card then
                local displayed_author = recommendation_author
                    .. (#recommendation.authors > 1 and " …" or "")
                self:_assert(descriptor.alias .. " recommendation author belongs to card " .. index,
                    textEquals(recommendation_card, displayed_author))
            end
        end
        local cover_path = self.app:cachedCoverPath(book)
        self:_assert(descriptor.alias .. " exact cover presence",
            (cover_path ~= nil) == (expected.coverPresent == true))
        if expected.coverPresent then
            self:_assert(descriptor.alias .. " detail cover widget rendered",
                rendersImageFile(root, cover_path))
        end
        if cover_path then self:_preserveCover(descriptor.alias, cover_path) end
        self:_assertDetailRendering(root, book, descriptor)
        local function finishDetail()
            local current = self.app.detail_widget
            if current then UIManager:close(current) end
            self.app.detail_widget = nil
            self.metadata_index = self.metadata_index + 1
            self:_later(0.1, function() self:_nextMetadataBook() end)
        end
        local function capturePaintedDetail()
            local current_root = self.app.detail_widget
            local scroll = current_root and current_root.cropping_widget
            self:_assert(descriptor.alias .. " detail is the visible top window",
                current_root ~= nil
                    and UIManager:getTopmostVisibleWidget() == current_root)
            self:_assertPaintedDetailChrome(current_root, descriptor)
            self.observations.detailSurfaces[descriptor.alias].scrollable =
                scroll and scroll._is_scrollable == true or false
            local top_path = self:_capture(
                descriptor.alias .. "-metadata-detail-top", current_root)
            local top_hash = sha256File(top_path)
            if descriptor.alias == "synthetic" then
                self:_assert("synthetic sparse detail is explicitly non-scrollable",
                    scroll and scroll._is_scrollable == false)
            end
            if not (scroll and scroll._is_scrollable
                    and scroll.scrollToRatio and scroll.getScrolledOffset) then
                finishDetail()
                return
            end
            -- Use the production scrollbar action so KOReader applies its own
            -- true crop size, clamping and scrollbar update. Calculating an
            -- offset from widget sizes can land both "middle" and "bottom" at
            -- the same clamped endpoint.
            scroll:scrollToRatio(nil, 0.5)
            local middle_offset = scroll:getScrolledOffset().y
            self:_later(0.2, function()
                -- A deferred cover batch may legitimately rebuild the detail
                -- in place while preserving its scroll offset. Always act on
                -- the currently visible widget, not an obsolete pre-rebuild
                -- table that would move in memory without changing the UI.
                local middle_root = self.app.detail_widget
                local middle_scroll = middle_root and middle_root.cropping_widget
                self:_assert(descriptor.alias .. " middle detail remains visible",
                    middle_scroll and middle_scroll._is_scrollable == true)
                local middle_path = self:_capture(
                    descriptor.alias .. "-metadata-detail-middle", middle_root)
                local middle_hash = sha256File(middle_path)
                self:_assert(descriptor.alias .. " middle screenshot differs from top",
                    middle_hash ~= nil and middle_hash ~= top_hash)
                middle_scroll:scrollToRatio(nil, 1)
                local bottom_offset = middle_scroll:getScrolledOffset().y
                self:_assert(descriptor.alias .. " detail screenshot offsets advance",
                    middle_offset == 0 or bottom_offset > middle_offset)
                self:_later(0.2, function()
                    local bottom_root = self.app.detail_widget
                    local bottom_path = self:_capture(
                        descriptor.alias .. "-metadata-detail-bottom", bottom_root)
                    local bottom_hash = sha256File(bottom_path)
                    self:_assert(descriptor.alias .. " bottom screenshot differs from middle",
                        bottom_hash ~= nil and bottom_hash ~= middle_hash)
                    finishDetail()
                end)
            end)
        end
        -- Data enrichment can complete before the newly rebuilt detail has
        -- reached KOReader's first paint. Wait for initState rather than
        -- photographing the previous framebuffer or calling scroll APIs with
        -- uninitialised crop dimensions.
        local stable_deadline = os.time() + 10
        local function waitForStableDetail()
            local candidate = self.app.detail_widget
            local candidate_scroll = candidate and candidate.cropping_widget
            if not candidate_scroll or candidate_scroll._is_scrollable == nil
                    or (self.app.async and self.app.async:isBusy()) then
                if os.time() >= stable_deadline then
                    error("timed out waiting for " .. descriptor.alias
                        .. " stable detail")
                end
                self:_later(0.2, waitForStableDetail)
                return
            end
            -- A deferred response can replace detail_widget after the first
            -- idle/paint observation. Require the same rebuilt root to remain
            -- current and idle across a real UI settle interval.
            self:_later(0.75, function()
                local current = self.app.detail_widget
                local current_scroll = current and current.cropping_widget
                if current == candidate and current_scroll
                        and current_scroll._is_scrollable ~= nil
                        and (not self.app.async or not self.app.async:isBusy()) then
                    capturePaintedDetail()
                elseif os.time() < stable_deadline then
                    waitForStableDetail()
                else
                    error("timed out waiting for " .. descriptor.alias
                        .. " stable detail")
                end
            end)
        end
        waitForStableDetail()
    end, 30)
end

function Driver:_checkpoint()
    local path = assert(os.getenv("GRIMMORY_ACCEPTANCE_CHECKPOINT"),
        "GRIMMORY_ACCEPTANCE_CHECKPOINT is required")
    local payload = stripNull(readJson(path))
    for _, item in ipairs(payload.checkpoints or {}) do
        if item.journey == "web-to-koreader-producer"
                and item.alias == self.alias then return item end
    end
    error("no persistent web checkpoint for alias " .. tostring(self.alias))
end

function Driver:_readerJourney()
    local descriptor = assert(self:_bookDescriptor(self.alias),
        "unknown acceptance alias")
    local book = assert(self:_serverBook(descriptor.serverBookId),
        "book missing from live library")
    local primary = assert(book.primaryFile, "book has no primary file")
    self.descriptor, self.book, self.primary = descriptor, book, primary
    self.checkpoint = self:_checkpoint()
    self:_assert(self.alias .. " checkpoint book identity",
        tonumber(self.checkpoint.serverBookId) == tonumber(book.id))
    self:_assert(self.alias .. " checkpoint source identity",
        self.checkpoint.sourceSha256 == descriptor.sourceSha256)

    self.app.download_dir = join(DataStorage:getFullDataDir(),
        "grimmory-acceptance-downloads")
    self.app.downloads.download_dir = self.app.download_dir
    util.makePath(self.app.download_dir)
    self.app:showBookDetail(book)
    self:_capture(self.alias .. "-download-before", self.app.detail_widget)
    self.app:downloadBook(book, primary)
    self:_waitUntil(self.alias .. " production download", function()
        return not self.app._downloading_id and self.app:getLocalPath(book, primary)
    end, function(path)
        self.download_path = path
        self:_assert(self.alias .. " downloaded exact staged EPUB bytes",
            sha256File(path) == descriptor.sourceSha256)
        local registry = LuaSettings:open(DataStorage:getSettingsDir()
            .. "/grimmory_downloads.lua")
        local registered = false
        for dummy, entry in pairs(registry.data or {}) do
            if type(entry) == "table" and entry.path == path
                    and tonumber(entry.server_id) == tonumber(book.id)
                    and tonumber(entry.file_id) == tonumber(primary.id)
                    and entry.server_url == self.runtime.baseUrl then
                registered = true
            end
        end
        self:_assert(self.alias .. " production download registry identity", registered)
        self.app:openBook(path, function(opened)
            self.reader = opened or require("apps/reader/readerui").instance
            self:_later(0.2, function() self:_waitForReaderSync() end)
        end)
    end, 90)
end


function Driver:_waitForReaderSync()
    local reader = self.reader
    local loader = reader and reader.pluginloader
    local sync = reader and reader.grimmory_sync
        or (loader and loader.getPluginInstance
            and loader:getPluginInstance("grimmory_sync"))
    if not sync or not sync.book_id or not sync.cfi then
        self:_later(0.2, function() self:_waitForReaderSync() end)
        return
    end
    self.sync = sync
    self:_assert(self.alias .. " production sync plugin attached",
        sync.ui == reader and tonumber(sync.book_id) == tonumber(self.book.id)
            and tonumber(sync.file_id) == tonumber(self.primary.id))
    if self.phase == "jump" then
        self:_waitForJumpConflict()
    else
        self:_prepareSyncHere()
    end
end

function Driver:_waitForJumpConflict()
    self:_waitUntil(self.alias .. " server-ahead conflict", function()
        local top = UIManager:getTopmostVisibleWidget()
        if self.sync.awaiting_decision and top
                and type(top.choice1_callback) == "function"
                and type(top.choice2_callback) == "function" then return top end
    end, function(dialog)
        self:_capture(self.alias .. "-web-progress-conflict", dialog)
        self.jump_events = {}
        local original_handle_event = self.reader.handleEvent
        self.reader.handleEvent = function(reader, event)
            self.jump_events[#self.jump_events + 1] = {
                handler = event.handler,
                first = event.args and event.args[1],
            }
            return original_handle_event(reader, event)
        end
        dialog.choice1_callback()
        self.reader.handleEvent = original_handle_event
        UIManager:close(dialog)
        self:_later(0.3, function() self:_afterJumpAhead() end)
    end, 30)
end

function Driver:_currentCFI()
    return self.sync and self.sync:getPositionData()
end

function Driver:_findAdoptedAnnotation()
    local wanted = tostring(self.checkpoint.annotation.id)
    for index, annotation in ipairs(self.reader.annotation.annotations or {}) do
        if tostring(annotation.grimmory_id) == wanted then
            return index, annotation
        end
    end
end

function Driver:_afterJumpAhead()
    self:_assert(self.alias .. " Jump Ahead released gate",
        self.sync.pulled == true and self.sync.awaiting_decision == false)
    local range_start = self.sync.cfi.splitRange(self.checkpoint.progress.cfi)
    local expected_anchor = range_start or self.checkpoint.progress.cfi
    local state_entry = self.sync.state:get(self.sync:_bookMeta())
    local actual_anchor = self:_currentCFI()
    local expected_xp, expected_xp_err = self.sync.cfi.cfiToXPointer(expected_anchor)
    local actual_xp = self.reader.document:getXPointer()
    self.observations = self.observations or {}
    self.observations.jumpAnchor = {
        expected = expected_anchor,
        actual = actual_anchor,
        expectedXPointer = expected_xp,
        actualXPointer = actual_xp,
    }
    self:_assert(self.alias .. " Jump Ahead retained exact browser CFI",
        state_entry and state_entry.server_position == self.checkpoint.progress.cfi)
    self:_assert(self.alias .. " Jump Ahead resolved browser range anchor",
        expected_xp ~= nil and expected_xp_err == nil)
    local exact_cfi_event, percentage_fallback = false, false
    for _, event in ipairs(self.jump_events or {}) do
        if event.handler == "onGotoXPointer" and event.first == expected_xp then
            exact_cfi_event = true
        elseif event.handler == "onGotoPercent" then
            percentage_fallback = true
        end
    end
    self.observations.jumpEvents = self.jump_events
    self:_assert(self.alias .. " Jump Ahead used exact CFI event",
        exact_cfi_event)
    self:_assert(self.alias .. " Jump Ahead did not use percentage fallback",
        not percentage_fallback)
    self:_assert(self.alias .. " Jump Ahead placed exact anchor in visible page",
        self.reader.document:isXPointerInCurrentPage(expected_xp) == true)
    self:_waitUntil(self.alias .. " browser annotation adoption", function()
        local index, annotation = self:_findAdoptedAnnotation()
        if not index then return nil end
        if annotation.grimmory_cfi == self.checkpoint.annotation.cfi
                and annotation.pos0 and annotation.pos1 then
            return { index = index, annotation = annotation }
        end
    end, function(adopted)
        self:_assert(self.alias .. " adopted exact browser annotation CFI", true)
        self:_capture(self.alias .. "-web-state-adopted", self.reader)
        -- Use KOReader's real Delete highlight action. It removes the local
        -- item and broadcasts AnnotationsModified, which the production sync
        -- plugin reconciles back to Grimmory.
        self.reader.highlight:deleteHighlight(adopted.index)
        self:_waitUntil(self.alias .. " browser annotation cleanup", function()
            local entry = self.sync.state:get(self.sync:_bookMeta())
            return entry and entry.annotations_dirty == false
                and not self:_findAdoptedAnnotation()
        end, function()
            self:_createDeviceHighlight()
        end, 30)
    end, 30)
end

function Driver:_createDeviceHighlight()
    -- Select actual text from two rendered positions, then run KOReader's real
    -- Save highlight action. This is the same action that a long-press release
    -- reaches, including ReaderAnnotation and AnnotationsModified hooks.
    local function hasNonAscii(value)
        for index = 1, #value do
            if string.byte(value, index) >= 128 then return true end
        end
        return false
    end
    local function features(value, start_pos, end_pos)
        local has_smart_quote = value:find("“", 1, true) ~= nil
            or value:find("”", 1, true) ~= nil
            or value:find("‘", 1, true) ~= nil
            or value:find("’", 1, true) ~= nil
        local topology = Exactness.selectionTopology(start_pos, end_pos)
        return {
            hasSmartQuote = has_smart_quote,
            hasAsciiApostrophe = value:find("'", 1, true) ~= nil,
            hasNonAscii = hasNonAscii(value),
            crossesTextNodeBoundary = topology.crossesTextNodeBoundary,
            crossesInlineBoundary = topology.crossesInlineBoundary,
            sameRenderedBlock = topology.sameRenderedBlock,
            acceptsSameBlockInlineSelection =
                topology.acceptsSameBlockInlineSelection,
            startBlockPath = topology.startBlockPath,
            endBlockPath = topology.endBlockPath,
            startInlinePath = topology.startInlinePath,
            endInlinePath = topology.endInlinePath,
        }
    end

    -- Search CREngine's live document for punctuation first, navigate to real
    -- result XPointers, then expand only within the rendered result page. This
    -- deliberately targets messy text instead of hoping a percentage sample
    -- happens to contain it. Only one-block, cross-inline candidates are
    -- eligible: CREngine and DOM Range serialize cross-block boundaries
    -- differently, so accepting those would make byte equality impossible.
    local hits, searched_mark = nil, nil
    for _, mark in ipairs({ "“", "”", "’", "‘", "'" }) do
        local found = self.reader.document:findAllText(
            mark, false, 0, 1000, false)
        if type(found) == "table" and #found > 0 then
            hits, searched_mark = found, mark
            break
        end
    end
    local best, candidates, scanned_hits = nil, 0, 0
    if hits then
        local stride = math.max(1, math.ceil(#hits / 60))
        for hit_index = 1, #hits, stride do
            if scanned_hits >= 60 then break end
            local hit = hits[hit_index]
            local hit_start = hit and hit.start
            local hit_end = hit and hit["end"]
            if type(hit_start) == "string" and type(hit_end) == "string" then
                scanned_hits = scanned_hits + 1
                self.reader:handleEvent(Event:new("GotoXPointer", hit_start))
                local starts = { hit_start }
                local previous = hit_start
                for dummy = 1, 10 do
                    previous = previous
                        and self.reader.document:getPrevVisibleWordStart(previous)
                    if not previous then break end
                    table.insert(starts, previous)
                end
                local candidate_end = hit_end
                for next_words = 1, 24 do
                    candidate_end = candidate_end
                        and self.reader.document:getNextVisibleWordEnd(candidate_end)
                    if not candidate_end then break end
                    for previous_words, candidate_start in ipairs(starts) do
                        local word_count = next_words + previous_words - 1
                        if word_count >= 6
                                and self.reader.document:isXPointerInCurrentPage(candidate_start)
                                and self.reader.document:isXPointerInCurrentPage(candidate_end) then
                            local extracted = self.reader.document:getTextFromXPointers(
                                candidate_start, candidate_end)
                            local candidate_text = type(extracted) == "table"
                                and extracted.text or extracted
                            if Exactness.isPlausibleSingleBlockSelectionText(
                                    candidate_text) then
                                local candidate_features = features(
                                    candidate_text, candidate_start, candidate_end)
                                if candidate_features.hasSmartQuote
                                        and candidate_features.hasNonAscii
                                        and candidate_features.acceptsSameBlockInlineSelection then
                                    candidates = candidates + 1
                                    local score = word_count
                                    if candidate_features.hasSmartQuote then score = score + 400 end
                                    if candidate_features.hasAsciiApostrophe then score = score + 250 end
                                    if candidate_features.hasNonAscii then score = score + 200 end
                                    if candidate_features.crossesTextNodeBoundary then score = score + 100 end
                                    if candidate_features.crossesInlineBoundary then score = score + 800 end
                                    if not best or score > best.score then
                                        best = {
                                            pos0 = candidate_start, pos1 = candidate_end,
                                            text = candidate_text, score = score,
                                            wordCount = word_count,
                                            hitIndex = hit_index,
                                            features = candidate_features,
                                        }
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    self:_assert(self.alias .. " device selection found rendered smart punctuation",
        best ~= nil)
    if not best then
        self:_finish(self.alias
            .. " has no bounded same-block cross-inline smart-punctuation selection")
        return
    end
    local pos0, pos1, text = best.pos0, best.pos1, best.text
    self.reader:handleEvent(Event:new("GotoXPointer", pos0))
    self:_assert(self.alias .. " device selection has distinct rendered positions",
        type(pos0) == "string" and pos0 ~= ""
            and type(pos1) == "string" and pos1 ~= "" and pos0 ~= pos1)
    self:_assert(self.alias .. " device selection extracts real rendered text",
        type(text) == "string" and text:match("%S") ~= nil)
    self:_assert(self.alias .. " device selection is plausible user length",
        type(text) == "string" and #text >= 5 and #text <= 500)
    self:_assert(self.alias .. " device selection has no control separators",
        Exactness.isPlausibleSingleBlockSelectionText(text))
    self:_assert(self.alias .. " device selection deliberately exercises smart punctuation",
        best.features.hasSmartQuote == true)
    self:_assert(self.alias .. " device selection preserves non-ASCII text",
        best.features.hasNonAscii == true)
    if self.alias == "real-1002" then
        self:_assert(self.alias .. " preserves known non-ASCII regression input",
            best.features.hasNonAscii == true)
    end
    self:_assert(self.alias .. " exercises a real EPUB inline-element boundary",
        best.features.crossesInlineBoundary == true)
    self:_assert(self.alias .. " selection remains within one exact rendered block",
        best.features.sameRenderedBlock == true
            and best.features.startBlockPath == best.features.endBlockPath)
    self.reader.highlight.selected_text = {
        pos0 = pos0, pos1 = pos1,
        text = text,
        datetime = os.date("!%Y-%m-%d %H:%M:%SZ"),
        drawer = "lighten", color = "yellow",
    }
    local index = self.reader.highlight:saveHighlight(false)
    self:_assert(self.alias .. " KOReader highlight action created item", index ~= nil)
    self.device_annotation = self.reader.annotation.annotations[index]
    self:_waitUntil(self.alias .. " KOReader annotation upload", function()
        local item = self.reader.annotation.annotations[index]
        local entry = self.sync.state:get(self.sync:_bookMeta())
        return item and item.grimmory_id
            and entry and entry.annotations_dirty == false
    end, function()
        local item = self.reader.annotation.annotations[index]
        local ok, generated_cfi = pcall(self.sync.cfi.xpointerRangeToCFI,
            item.pos0, item.pos1)
        local cfi = item.grimmory_cfi or generated_cfi
        self:_assert(self.alias .. " KOReader highlight upload keeps exact CFI",
            ok and type(cfi) == "string" and cfi:match("^epubcfi%(.+%)$") ~= nil)
        self:_assert(self.alias .. " KOReader highlight keeps complete rendered selection",
            item.text == text)
        self.device_annotation_id = item.grimmory_id
        self.device_annotation_cfi = cfi
        self.observations = self.observations or {}
        self.observations.deviceAnnotation = {
            id = item.grimmory_id,
            cfi = cfi,
            text = item.text,
            style = item.drawer,
            color = item.color,
            selection = {
                method = "live-rendered-xpointer-saveHighlight",
                pos0 = pos0,
                pos1 = pos1,
                candidateCount = candidates,
                searchedMark = searched_mark,
                scannedHits = scanned_hits,
                hitIndex = best.hitIndex,
                wordCount = best.wordCount,
                hasSmartQuote = best.features.hasSmartQuote,
                hasAsciiApostrophe = best.features.hasAsciiApostrophe,
                hasNonAscii = best.features.hasNonAscii,
                crossesTextNodeBoundary = best.features.crossesTextNodeBoundary,
                crossesInlineBoundary = best.features.crossesInlineBoundary,
                sameRenderedBlock = best.features.sameRenderedBlock,
                startBlockPath = best.features.startBlockPath,
                endBlockPath = best.features.endBlockPath,
                startInlinePath = best.features.startInlinePath,
                endInlinePath = best.features.endInlinePath,
            },
        }
        if os.getenv("GRIMMORY_ACCEPTANCE_SESSION") == "1" then
            self:_sessionJourney()
        else
            self:_finish()
        end
    end, 30)
end

function Driver:_prepareSyncHere()
    local prior = self.prior_result and self.prior_result.observations
        and self.prior_result.observations.deviceAnnotation
    self:_assert(self.alias .. " jump phase recorded device annotation",
        prior and prior.id ~= nil and type(prior.cfi) == "string")
    self.device_annotation_id = prior.id
    self.device_annotation_cfi = prior.cfi
    self.device_annotation_text = prior.text

    -- A fresh KO_HOME has no saved reading location. Move through ReaderUI
    -- before the plugin's scheduled initial pull, just as a user can navigate
    -- immediately after opening. The server remains well ahead at the browser
    -- checkpoint (or at a later position reached in the Jump phase).
    self.reader:handleEvent(Event:new("GotoPercent", 10))
    self.local_sync_here_cfi = self:_currentCFI()
    self.local_sync_here_percentage = math.floor(
        self.sync:getPercentage() * 10000) / 100
    self:_assert(self.alias .. " Sync Here starts at a real CFI",
        type(self.local_sync_here_cfi) == "string"
            and self.local_sync_here_cfi:match("^epubcfi%(.+%)$") ~= nil)
    self:_assert(self.alias .. " Sync Here starts behind browser checkpoint",
        tonumber(self.checkpoint.progress.percentage)
            > self.local_sync_here_percentage + 0.5)
    self:_waitUntil(self.alias .. " fresh-open production conflict", function()
        local top = UIManager:getTopmostVisibleWidget()
        if self.sync.awaiting_decision and top
                and type(top.choice2_callback) == "function" then return top end
    end, function(dialog)
        self:_capture(self.alias .. "-sync-here-conflict", dialog)
        dialog.choice2_callback()
        UIManager:close(dialog)
        self:_waitUntil(self.alias .. " Sync Here drain", function()
            local entry = self.sync.state:get(self.sync:_bookMeta())
            return self.sync.pulled and not self.sync.awaiting_decision
                and self.sync:pendingCount() == 0
                and entry and entry.server_position == self.local_sync_here_cfi
        end, function()
            self:_assert(self.alias .. " Sync Here production push completed", true)
            self.observations = self.observations or {}
            local pushed_entry = self.sync.state:get(self.sync:_bookMeta())
            self:_assert(self.alias .. " Sync Here production state keeps exact request percentage",
                pushed_entry
                    and tonumber(pushed_entry.server_percentage)
                        == tonumber(self.local_sync_here_percentage))
            self.observations.syncHere = {
                cfi = self.local_sync_here_cfi,
                percentage = pushed_entry and pushed_entry.server_percentage,
            }
            self:_waitForDeviceAnnotationForBrowser()
        end, 30)
    end, 30)
end

function Driver:_findDeviceAnnotation()
    for index, annotation in ipairs(self.reader.annotation.annotations or {}) do
        if tostring(annotation.grimmory_id) == tostring(self.device_annotation_id) then
            return index, annotation
        end
    end
end

function Driver:_waitForDeviceAnnotationForBrowser()
    self:_waitUntil(self.alias .. " device annotation adoption in fresh reader", function()
        local index, annotation = self:_findDeviceAnnotation()
        if not index then return nil end
        local ok = pcall(self.sync.cfi.xpointerRangeToCFI,
            annotation.pos0, annotation.pos1)
        if ok and annotation.grimmory_cfi == self.device_annotation_cfi then
            return { index = index, annotation = annotation }
        end
    end, function(adopted)
        self:_assert(self.alias .. " fresh reader adopted exact device CFI", true)
        self:_assert(self.alias .. " fresh reader adopted complete device text",
            adopted.annotation.text == self.device_annotation_text)
        self:_capture(self.alias .. "-device-annotation-adopted", self.reader)
        self.observations = self.observations or {}
        self.observations.deviceAnnotationAdopted = {
            id = adopted.annotation.grimmory_id,
            cfi = adopted.annotation.grimmory_cfi,
            text = adopted.annotation.text,
        }
        -- This isolated reader is not the cleanup owner. The next lane must
        -- first open this retained annotation through Grimmory's visible web
        -- UI and resolve its complete Foliate DOM Range.
        self:_finish()
    end, 30)
end

function Driver:_sessionJourney()
    local entry = self.sync.state:get(self.sync:_bookMeta())
    self:_assert(self.alias .. " session journey starts without a hidden active session",
        not entry or entry.active_session == nil)

    -- Establish the start through real ReaderUI navigation while session
    -- capture is still disabled.  These values come from the rendered
    -- document, not from the session record that will later be uploaded.
    self.reader:handleEvent(Event:new("GotoPercent", 42))
    local start_location = self:_currentCFI()
    local start_progress = math.floor(self.sync:getPercentage() * 10000) / 100
    self:_assert(self.alias .. " independently observed session start CFI",
        type(start_location) == "string"
            and start_location:match("^epubcfi%(.+%)$") ~= nil)

    -- Open the actual Connection & Sync screen owned by this ReaderUI.  The
    -- Grimmory instance retained from FileManager can save the shared setting,
    -- but its ui has no active document sync service, so using it would leave
    -- this reader's GrimmorySync instance disabled.  A user toggling this row
    -- while reading acts through reader.grimmory and its production callback.
    local reader_app = self.reader and self.reader.grimmory
    self:_assert(self.alias .. " ReaderUI owns the production session toggle",
        reader_app and reader_app.ui == self.reader
            and reader_app.ui.grimmory_sync == self.sync)
    self:_assert(self.alias .. " stale FileManager instance cannot own reader session state",
        self.app ~= reader_app
            and (not self.app.ui or self.app.ui.grimmory_sync ~= self.sync))
    self:_assert(self.alias .. " active ReaderUI session sync begins disabled",
        self.sync.sync_reading_sessions == false)
    reader_app:showConnectionSyncMenu()
    local connection_widget = reader_app.connection_sync_widget
    local connection_menu = connection_widget and connection_widget[1]
    local session_item
    for _, item in ipairs(connection_menu and connection_menu.item_table or {}) do
        if item.action == "toggle_sessions" then session_item = item; break end
    end
    self:_assert(self.alias .. " visible Connection & Sync session row exists",
        connection_widget ~= nil
            and UIManager:getTopmostVisibleWidget() == connection_widget
            and connection_menu ~= nil and session_item ~= nil
            and session_item.text == "Sync reading sessions"
            and session_item.mandatory == "off")
    connection_menu.onMenuChoice(connection_menu, session_item)
    local enabled_widget = reader_app.connection_sync_widget
    local enabled_menu = enabled_widget and enabled_widget[1]
    local enabled_item
    for _, item in ipairs(enabled_menu and enabled_menu.item_table or {}) do
        if item.action == "toggle_sessions" then enabled_item = item; break end
    end
    self:_assert(self.alias .. " visible session toggle enables active ReaderUI sync",
        self.sync.sync_reading_sessions == true
            and enabled_widget ~= nil
            and UIManager:getTopmostVisibleWidget() == enabled_widget
            and enabled_item ~= nil and enabled_item.mandatory == "on")
    self:_assert(self.alias .. " Connection & Sync screen exposes production close callback",
        enabled_menu and type(enabled_menu.close_callback) == "function")
    enabled_menu.close_callback()
    local started_at = os.time()
    local resume_event = Event:new("Resume")
    self:_assert(self.alias .. " uses KOReader's production Resume lifecycle event",
        resume_event.handler == "onResume")
    -- Device:_afterResume uses UIManager:broadcastEvent so every window-level
    -- widget receives Resume even when a normal child handler consumes it.
    -- ReaderUI:handleEvent is not equivalent: WidgetContainer propagation may
    -- stop before a document plugin, which is exactly what the retained v3
    -- artifact exposed.
    UIManager:broadcastEvent(resume_event)
    local started_after = os.time()
    self:_assert(self.alias .. " session start stayed within one exact clock second",
        started_at == started_after)
    entry = self.sync.state:get(self.sync:_bookMeta())
    self:_assert(self.alias .. " Resume began the production session",
        entry and entry.active_session ~= nil)

    -- Real elapsed time preserves the production 30-second accidental-open
    -- rule; no fake clock or state-file editing is used.
    self:_later(31, function()
        self.reader:handleEvent(Event:new("GotoPercent", 47))
        local end_location = self:_currentCFI()
        local end_progress = math.floor(self.sync:getPercentage() * 10000) / 100
        self:_assert(self.alias .. " independently observed session end CFI",
            type(end_location) == "string"
                and end_location:match("^epubcfi%(.+%)$") ~= nil)
        local ended_at = os.time()
        -- Device:_beforeSuspend uses the same broadcast boundary. The
        -- production plugin's onSuspend hook finalizes and uploads both
        -- progress and the session.
        local suspend_event = Event:new("Suspend")
        self:_assert(self.alias .. " uses KOReader's production Suspend lifecycle event",
            suspend_event.handler == "onSuspend")
        UIManager:broadcastEvent(suspend_event)
        local ended_after = os.time()
        self:_assert(self.alias .. " session end stayed within one exact clock second",
            ended_at == ended_after)

        -- This expected payload is deliberately constructed from the two
        -- ReaderUI observations and wall clock surrounding lifecycle events;
        -- it never reads the queued production session back as its oracle.
        local fingerprint = {
            bookId = tonumber(self.book.id),
            bookType = tostring(self.sync.file_type or "EPUB"):upper(),
            startEpochSeconds = started_at,
            endEpochSeconds = ended_at,
            durationSeconds = ended_at - started_at,
            startProgress = start_progress,
            endProgress = end_progress,
            progressDelta = math.max(0, end_progress - start_progress),
            startLocation = start_location,
            endLocation = end_location,
        }
        self:_assert(self.alias .. " lifecycle crossed the minimum duration",
            fingerprint.durationSeconds >= 30)
        self.observations = self.observations or {}
        self.observations.sessionFingerprint = fingerprint
        self:_waitUntil(self.alias .. " reading session upload", function()
            local current = self.sync.state:get(self.sync:_bookMeta())
            return current and current.active_session == nil
                and #self.sync.state:pendingSessions(
                    self.sync.username, self.sync.server_url) == 0
        end, function()
            self:_assert(self.alias .. " production reading hooks reached server", true)
            self.observations.sessionExpected = true
            self:_finish()
        end, 30)
    end)
end

function Driver:_finish(fatal)
    if self.finished then return end
    self.finished = true
    if self._network_originals then
        NetworkMgr.isWifiOn = self._network_originals.isWifiOn
        NetworkMgr.isConnected = self._network_originals.isConnected
    end
    local passed = fatal == nil
    if passed then
        for _, assertion in ipairs(self.assertions) do
            if not assertion.pass then passed = false break end
        end
    end
    local payload = {
        schemaVersion = 1,
        mode = self.mode,
        phase = self.phase,
        alias = self.alias,
        passed = passed,
        fatal = fatal and tostring(fatal) or nil,
        assertions = self.assertions,
        screenshots = self.screenshots,
        coverArtifacts = self.cover_artifacts,
        observations = self.observations,
        durationSeconds = os.time() - self.started_at,
        provenance = {
            serverImageDigest = self.runtime.serverImageDigest,
            sourceFingerprint = self.runtime.sourceFingerprint,
            koreaderVersion = os.getenv("GRIMMORY_ACCEPTANCE_KOREADER_VERSION"),
            koreaderCommit = os.getenv("GRIMMORY_ACCEPTANCE_KOREADER_COMMIT"),
            dataClass = "private-ignored-full-server",
        },
    }
    local artifact_key = self.alias
    if not artifact_key or artifact_key == "" then
        artifact_key = self.mode or "acceptance"
    end
    local path = join(self.output_dir, artifact_key .. ".json")
    local handle = io.open(path, "wb")
    if handle then
        handle:write(json.encode(payload))
        handle:close()
    end
    UIManager:quit((passed and handle) and 0 or 1)
end

return Driver
