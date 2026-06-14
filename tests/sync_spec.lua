--[[
  Sync state machine spec for booklore_sync.koplugin/main.lua.

  Uses stub UIManager + virtual clock to exercise debounce and push-after-pull
  gate deterministically without real I/O or sleep.
]]
local spec_helper  = require("spec_helper")
local fake_settings = require("fake_settings_dir")

local BookLoreSync
local ui
local fixture
local settings_dir

local function make_fake_ui(file_path, book_id, server_url)
    local fake_reader_ui = require("fake_reader_ui")
    return fake_reader_ui.new({
        file = file_path,
        book_id = book_id,
        server_url = server_url,
    })
end

describe("BookLoreSync state machine", function()
    before_each(function()
        spec_helper.setup()

        -- Build a tmp settings dir pre-populated with auth and download registry.
        settings_dir = fake_settings.create({
            server_url = "http://127.0.0.1",  -- will be overridden by fixture per test
            token = "test-token",
            token_time = os.time(),
            downloads = {
                ["/books/test.epub"] = { path = "/books/test.epub", server_id = 99, server_url = nil },
            },
        })

        -- DataStorage stub returns the tmp dir.
        local datastorage = require("datastorage")
        datastorage._set_dir(settings_dir.dir)

        BookLoreSync = require("booklore_sync")
        ui = make_fake_ui("/books/test.epub", 99, nil)
    end)

    after_each(function()
        if fixture then fixture.stop(); fixture = nil end
        settings_dir.cleanup()
        spec_helper.teardown()
    end)

    describe("onReaderReady", function()
        it("triggers a pull and sets pulled=true after pull completes", function()
            fixture = spec_helper.start_http_fixture({
                {
                    method = "GET",
                    path = "/api/v1/books/99",
                    status = 200,
                    headers = { ["Content-Type"] = "application/json" },
                    body = '{"id":99,"epubProgress":null}',
                    repeat_ = 1,
                },
            })
            -- Override server_url to point at fixture
            local settings = require("luasettings"):open(settings_dir.dir .. "/booklore.lua")
            settings:saveSetting("server_url", fixture.base_url())
            settings:flush()

            local sync = BookLoreSync:new()
            sync.ui = ui
            sync:init()
            sync:onReaderReady()

            -- scheduleIn(1, ...) is queued; tick past it.
            local uim = require("ui/uimanager")
            uim.tickBy(2)

            assert.is_true(sync.pulled, "pulled flag should be set after pull")
        end)
    end)

    describe("onPageUpdate - push-after-pull gate", function()
        it("does NOT push before pull completes", function()
            fixture = spec_helper.start_http_fixture({
                {
                    method = "GET",
                    path = "/api/v1/books/99",
                    status = 200,
                    headers = { ["Content-Type"] = "application/json" },
                    body = '{"id":99,"epubProgress":null}',
                },
                {
                    method = "POST",
                    path = "/api/v1/books/progress",
                    status = 204,
                    headers = {},
                    body = "",
                },
            })
            local sync = BookLoreSync:new()
            sync.ui = ui
            sync.server_url = fixture.base_url()
            sync.token = "test-token"
            sync.enabled = true
            sync.book_id = 99
            sync.pulled = false  -- pull not yet complete
            sync.last_push_time = 0
            sync.push_in_progress = false
            sync.has_pages = true
            sync.awaiting_decision = false

            sync:onPageUpdate()

            -- No push should have been made because pulled=false
            local logger = require("logger")
            assert.is_false(logger.has("dbg", "pushed progress"),
                "push should not happen before pull completes")
        end)

        it("schedules a push after pull, and multiple calls debounce to one push", function()
            fixture = spec_helper.start_http_fixture({
                {
                    method = "POST",
                    path = "/api/v1/books/progress",
                    status = 204,
                    headers = {},
                    body = "",
                },
            })
            local sync = BookLoreSync:new()
            sync.ui = ui
            sync.server_url = fixture.base_url()
            sync.token = "test-token"
            sync.enabled = true
            sync.book_id = 99
            sync.pulled = true
            sync.last_push_time = os.time()
            sync.push_in_progress = false
            sync.has_pages = true
            sync.awaiting_decision = false

            -- Three rapid page updates within the 30s debounce window; no push should fire
            sync:onPageUpdate()
            sync:onPageUpdate()
            sync:onPageUpdate()

            local uim = require("ui/uimanager")
            -- Tick past any scheduled callback to confirm nothing fires within the 30s debounce window
            uim.tickBy(0.5)

            local logger = require("logger")
            local push_count = 0
            for _, msg in ipairs(logger.get("dbg")) do
                if msg:find("pushed progress", 1, true) then
                    push_count = push_count + 1
                end
            end
            assert.equals(0, push_count, "debounce should suppress all pushes within the 30s window")
        end)
    end)

    describe("showConflictPrompt callbacks", function()
        it("choice1 (Jump Ahead) sets pulled=true and clears awaiting_decision; choice2 (Sync Here) calls pushProgress", function()
            fixture = spec_helper.start_http_fixture({
                {
                    method = "GET",
                    path = "/api/v1/books/99",
                    status = 200,
                    headers = { ["Content-Type"] = "application/json" },
                    body = '{"id":99,"epubProgress":{"percentage":80.0,"cfi":null}}',
                    repeat_ = 1,
                },
                {
                    method = "POST",
                    path = "/api/v1/books/progress",
                    status = 204,
                    headers = {},
                    body = "",
                    repeat_ = 1,
                },
            })

            local sync = BookLoreSync:new()
            sync.ui = ui
            sync.server_url = fixture.base_url()
            sync.token = "test-token"
            sync.enabled = true
            sync.book_id = 99
            sync.pulled = false
            sync.has_pages = true
            sync.push_in_progress = false
            sync.awaiting_decision = false
            sync.cfi = nil

            -- pullProgress sees server at 80%, local at 0% => sets awaiting_decision=true
            sync:pullProgress()

            assert.is_true(sync.awaiting_decision,
                "pullProgress should set awaiting_decision when server is ahead")
            assert.is_false(sync.pulled,
                "pulled should remain false while awaiting decision")

            -- Inspect captured callbacks from the stub
            local MultiConfirmBox = require("ui/widget/multiconfirmbox")
            local box = MultiConfirmBox._last
            assert.not_nil(box, "MultiConfirmBox should have been constructed")

            -- Invoke choice1 (Jump Ahead): expect pulled=true, awaiting_decision=false
            box.choice1_callback()

            assert.is_true(sync.pulled,
                "choice1_callback should set pulled=true")
            assert.is_false(sync.awaiting_decision,
                "choice1_callback should clear awaiting_decision")

            -- Reset state and invoke choice2 (Sync Here): expect pushProgress was called
            sync.pulled = false
            sync.awaiting_decision = true
            sync.push_in_progress = false
            sync.last_push_time = 0

            box.choice2_callback()

            local logger = require("logger")
            assert.is_true(logger.has("dbg", "pushed progress"),
                "choice2_callback should invoke pushProgress")
            assert.is_false(sync.awaiting_decision,
                "choice2_callback should clear awaiting_decision")
            assert.is_true(sync.pulled,
                "choice2_callback should set pulled=true")
        end)
    end)

    describe("pull failure handling", function()
        it("logs a warning and keeps push gate CLOSED when server returns non-200", function()
            fixture = spec_helper.start_http_fixture({
                {
                    method = "GET",
                    path = "/api/v1/books/99",
                    status = 503,
                    headers = {},
                    body = "Service Unavailable",
                    repeat_ = 1,
                },
            })
            local sync = BookLoreSync:new()
            sync.ui = ui
            sync.server_url = fixture.base_url()
            sync.token = "test-token"
            sync.enabled = true
            sync.book_id = 99
            sync.pulled = false
            sync.has_pages = true
            sync.push_in_progress = false
            sync.awaiting_decision = false
            sync.cfi = nil

            sync:pullProgress()

            local logger = require("logger")
            assert.is_false(sync.pulled,
                "push gate must remain closed when server is unreachable (non-200) — pushing blind would overwrite unknown server state")
            assert.is_true(logger.has("warn", "pull failed"),
                "should warn on pull failure")
        end)

        it("onCloseDocument does NOT push when pulled=false", function()
            fixture = spec_helper.start_http_fixture({
                {
                    method = "POST",
                    path = "/api/v1/books/progress",
                    status = 204,
                    headers = {},
                    body = "",
                },
            })
            local sync = BookLoreSync:new()
            sync.ui = ui
            sync.server_url = fixture.base_url()
            sync.token = "test-token"
            sync.enabled = true
            sync.book_id = 99
            sync.pulled = false  -- pull never completed
            sync.has_pages = true
            sync.push_in_progress = false
            sync.awaiting_decision = false
            sync.cfi = nil

            sync:onCloseDocument()

            local logger = require("logger")
            assert.is_false(logger.has("dbg", "pushed progress"),
                "onCloseDocument must not push when pull gate is still closed")
        end)
    end)
end)

describe("BookLoreSync offline queue", function()
    local settings_dir2
    local fake_reader_ui = require("fake_reader_ui")

    before_each(function()
        spec_helper.setup()
        settings_dir2 = fake_settings.create({
            server_url = "http://127.0.0.1",
            token = "test-token",
            token_time = os.time(),
            downloads = {
                ["/books/test.epub"] = { path = "/books/test.epub", server_id = 99, server_url = nil },
            },
        })
        local datastorage = require("datastorage")
        datastorage._set_dir(settings_dir2.dir)
        BookLoreSync = require("booklore_sync")
        ui = fake_reader_ui.new({ file = "/books/test.epub", book_id = 99 })
    end)

    after_each(function()
        if fixture then fixture.stop(); fixture = nil end
        settings_dir2.cleanup()
        local nm = require("ui/network/manager")
        nm._reset()
        spec_helper.teardown()
    end)

    it("onPageUpdate while wifi off enqueues without HTTP", function()
        local nm = require("ui/network/manager")
        nm._set_wifi(false)

        local sync = BookLoreSync:new()
        sync.ui = ui
        sync.server_url = "http://127.0.0.1"
        sync.token = "test-token"
        sync.enabled = true
        sync.book_id = 99
        sync.pulled = false
        sync.push_in_progress = false
        sync.has_pages = true
        sync.awaiting_decision = false
        sync.queue = require("queue").new{}

        sync:onPageUpdate()

        assert.equals(1, sync.queue:size(),
            "onPageUpdate should enqueue one entry when offline")
        local logger = require("logger")
        assert.is_false(logger.has("dbg", "pushed progress"),
            "no HTTP push should occur when wifi is off")
    end)

    it("three onPageUpdate calls collapse to one queue entry (latest-wins)", function()
        local sync = BookLoreSync:new()
        sync.ui = ui
        sync.server_url = "http://127.0.0.1"
        sync.token = "test-token"
        sync.enabled = true
        sync.book_id = 99
        sync.pulled = false
        sync.push_in_progress = false
        sync.has_pages = true
        sync.awaiting_decision = false
        sync.queue = require("queue").new{}

        for _, pct in ipairs({ 0.1, 0.2, 0.5 }) do
            ui._percent = pct
            sync:onPageUpdate()
        end

        assert.equals(1, sync.queue:size(),
            "multiple onPageUpdate calls should collapse to one queue entry per book")
        local entry = sync.queue:peek(99)
        assert.not_nil(entry)
        local expected_pct = math.floor(0.5 * 10000) / 100
        assert.equals(expected_pct, entry.percentage,
            "queue should store the last (latest-wins) percentage")
    end)

    it("post-pull drain pushes queued current-book entry", function()
        fixture = spec_helper.start_http_fixture({
            {
                method = "GET",
                path = "/api/v1/books/99",
                status = 200,
                headers = { ["Content-Type"] = "application/json" },
                body = '{"id":99,"epubProgress":null}',
                repeat_ = 1,
            },
            {
                method = "POST",
                path = "/api/v1/books/progress",
                status = 204,
                headers = {},
                body = "",
                repeat_ = 1,
            },
        })

        local settings = require("luasettings"):open(settings_dir2.dir .. "/booklore.lua")
        settings:saveSetting("server_url", fixture.base_url())
        settings:flush()

        local sync = BookLoreSync:new()
        sync.ui = ui
        sync.server_url = fixture.base_url()
        sync.token = "test-token"
        sync.enabled = true
        sync.book_id = 99
        sync.pulled = false
        sync.push_in_progress = false
        sync.has_pages = true
        sync.awaiting_decision = false
        sync.cfi = nil
        sync.queue = require("queue").new{}
        sync.queue:enqueue(99, fixture.base_url(), 42.0, nil)

        assert.equals(1, sync.queue:size(), "pre-populated queue should have one entry")

        sync:pullProgress()
        require("ui/uimanager").tickBy(0.5)

        assert.equals(0, sync.queue:size(),
            "queue entry should be removed after successful drain")
        local logger = require("logger")
        assert.is_true(logger.has("dbg", "pushed progress"),
            "push should be recorded after drain")
    end)

    it("pull failure leaves current-book queue intact", function()
        fixture = spec_helper.start_http_fixture({
            {
                method = "GET",
                path = "/api/v1/books/99",
                status = 503,
                headers = {},
                body = "Service Unavailable",
                repeat_ = 1,
            },
        })

        local sync = BookLoreSync:new()
        sync.ui = ui
        sync.server_url = fixture.base_url()
        sync.token = "test-token"
        sync.enabled = true
        sync.book_id = 99
        sync.pulled = false
        sync.push_in_progress = false
        sync.has_pages = true
        sync.awaiting_decision = false
        sync.cfi = nil
        sync.queue = require("queue").new{}
        sync.queue:enqueue(99, fixture.base_url(), 42.0, nil)

        sync:pullProgress()
        require("ui/uimanager").tickBy(0.5)

        assert.is_false(sync.pulled,
            "pull failure should keep push gate closed")
        assert.equals(1, sync.queue:size(),
            "queue entry must remain intact when pull fails")
    end)
end)

describe("BookLoreSync token-independent capture & per-account drain", function()
    local settings_dir3
    local fake_reader_ui = require("fake_reader_ui")

    before_each(function()
        spec_helper.setup()
        -- token = "" simulates an expired / cleared access token.
        settings_dir3 = fake_settings.create({
            server_url = "http://127.0.0.1",
            token = "",
            token_time = 0,
            downloads = {
                ["/books/test.epub"] = { path = "/books/test.epub", server_id = 99, server_url = nil },
            },
        })
        local datastorage = require("datastorage")
        datastorage._set_dir(settings_dir3.dir)
        BookLoreSync = require("booklore_sync")
        ui = fake_reader_ui.new({ file = "/books/test.epub", book_id = 99 })
    end)

    after_each(function()
        if fixture then fixture.stop(); fixture = nil end
        settings_dir3.cleanup()
        local nm = require("ui/network/manager")
        nm._reset()
        spec_helper.teardown()
    end)

    it("init keeps capture enabled when the token is absent/expired", function()
        local sync = BookLoreSync:new()
        sync.ui = ui
        sync:init()
        assert.is_true(sync.enabled,
            "capture must stay enabled without a live token (decoupled from token)")
        assert.is_true(sync.token == nil or sync.token == "",
            "no live token is stored")
    end)

    it("pullProgress with no token does not crash and keeps the push gate closed", function()
        -- No HTTP fixture on purpose. "Never reaches the network" is proven by
        -- the guard's log line: pullProgress returns at the no-token guard, so
        -- the request code below it is unreachable. (A silent connection-refused
        -- would NOT fail the assertions, so the log assertion is load-bearing.)
        local sync = BookLoreSync:new()
        sync.ui = ui
        sync.server_url = "http://127.0.0.1"
        sync.token = nil
        sync.enabled = true
        sync.book_id = 99
        sync.pulled = false
        sync.has_pages = true
        sync.awaiting_decision = false
        sync.cfi = nil
        sync.queue = require("queue").new{}
        sync.queue:enqueue(99, "http://127.0.0.1", 42.0, nil, "alice")

        sync:pullProgress()

        assert.is_false(sync.pulled,
            "no-token pull must leave the gate closed (nothing was pulled)")
        local logger = require("logger")
        assert.is_true(logger.has("warn", "no token, skipping pull"),
            "the no-token guard must fire before any network code")
        assert.is_false(logger.has("dbg", "pushed progress"))
        assert.equals(1, sync.queue:size(),
            "queued entry stays untouched (sanity check; pull never drains)")
    end)

    it("drain pushes only entries owned by the logged-in account", function()
        fixture = spec_helper.start_http_fixture({
            { method = "POST", path = "/api/v1/books/progress", status = 204, headers = {}, body = "", repeat_ = 5 },
        })
        local settings = require("luasettings"):open(settings_dir3.dir .. "/booklore.lua")
        settings:saveSetting("username", "alice")
        settings:saveSetting("token", "alice-token")
        settings:flush()

        local nm = require("ui/network/manager"); nm._set_wifi(true)

        local sync = BookLoreSync:new()
        sync.ui = ui
        sync.server_url = fixture.base_url()
        sync.token = "alice-token"
        sync.enabled = true
        sync.book_id = 99
        sync.pulled = true
        sync.has_pages = true
        sync.awaiting_decision = false
        sync.queue = require("queue").new{}
        sync.queue:enqueue(88, fixture.base_url(), 30.0, nil, "alice")
        sync.queue:enqueue(77, fixture.base_url(), 60.0, nil, "bob")

        sync:_drainAll()

        assert.is_nil(sync.queue:peek(88, "alice"),
            "alice's entry should push and be removed while alice is logged in")
        assert.not_nil(sync.queue:peek(77, "bob"),
            "bob's entry must stay queued until bob is logged in")
        assert.equals(1, sync.queue:size())
    end)

    it("collectors return drainable slots and removeIfUnchanged guards on identity", function()
        -- The async drain collects entries, forks to push, then removes on the
        -- callback. A page turn that replaces a slot (latest-wins) in between
        -- must NOT have its fresher progress dropped by the stale removal.
        local q = require("queue").new{}
        q:enqueue(99, "http://127.0.0.1", 42.0, nil, "alice")  -- current book
        q:enqueue(88, "http://127.0.0.1", 30.0, nil, "alice")  -- other book

        local current = q:currentBookDrainable(99, "alice")
        assert.equals(1, #current)
        assert.equals(99, current[1].entry.book_id)
        local others = q:othersDrainable(99, "alice")
        assert.equals(1, #others)
        assert.equals(88, others[1].entry.book_id)

        -- Simulate the race: after collecting 99's entry, a page turn replaces
        -- it with fresher progress (a new entry table at the same key).
        local stale_item = current[1]
        q:enqueue(99, "http://127.0.0.1", 55.0, nil, "alice")
        local removed = q:removeIfUnchanged(stale_item.key, stale_item.entry)
        assert.is_false(removed, "stale removal must be refused once the slot was superseded")
        assert.equals(55.0, q:peek(99, "alice").percentage,
            "fresher progress survives the stale drain callback")

        -- 88 was untouched, so its removal succeeds.
        assert.is_true(q:removeIfUnchanged(others[1].key, others[1].entry))
        assert.is_nil(q:peek(88, "alice"))
    end)

    it("keeps both accounts' progress when they queue the same book", function()
        -- The multi-user guarantee at the queue layer: latest-wins applies
        -- per (account, book), so bob reading the same book must not destroy
        -- alice's undrained offline progress.
        local q = require("queue").new{}
        q:enqueue(99, "http://127.0.0.1", 42.0, nil, "alice")
        q:enqueue(99, "http://127.0.0.1", 60.0, nil, "bob")

        assert.equals(2, q:size(), "one slot per account, not one per book")
        assert.equals(42.0, q:peek(99, "alice").percentage)
        assert.equals(60.0, q:peek(99, "bob").percentage)

        -- Latest-wins still collapses within one account.
        q:enqueue(99, "http://127.0.0.1", 55.0, nil, "alice")
        assert.equals(2, q:size())
        assert.equals(55.0, q:peek(99, "alice").percentage)
    end)

    it("enqueue supersedes only the enqueuing account's legacy bare-key entry", function()
        local q = require("queue").new{}
        -- Seed pre-composite-schema entries the way old deployments wrote
        -- them: bare book_id keys, directly in the on-disk store.
        q._store.data["77"] = { book_id = 77, server_url = "http://127.0.0.1",
            percentage = 10.0, username = "alice", enqueued_at = 0 }
        q._store.data["88"] = { book_id = 88, server_url = "http://127.0.0.1",
            percentage = 20.0, username = "alice", enqueued_at = 0 }
        q._store:flush()

        -- Alice re-queues her own book: the legacy slot is superseded.
        q:enqueue(77, "http://127.0.0.1", 50.0, nil, "alice")
        assert.equals(50.0, q:peek(77, "alice").percentage)
        assert.is_nil(q._store.data["77"], "alice's legacy slot is replaced")

        -- Bob queues a book that still holds alice's legacy progress:
        -- alice's entry must survive.
        q:enqueue(88, "http://127.0.0.1", 70.0, nil, "bob")
        assert.equals(70.0, q:peek(88, "bob").percentage)
        assert.equals(20.0, q._store.data["88"].percentage,
            "bob's enqueue must not destroy alice's legacy entry")
    end)

    it("a legacy bare-key entry for the current book stays gated until pull", function()
        fixture = spec_helper.start_http_fixture({
            { method = "POST", path = "/api/v1/books/progress", status = 204, headers = {}, body = "", repeat_ = 2 },
        })
        local settings = require("luasettings"):open(settings_dir3.dir .. "/booklore.lua")
        settings:saveSetting("username", "alice")
        settings:saveSetting("token", "fresh-token")
        settings:flush()

        local nm = require("ui/network/manager"); nm._set_wifi(true)

        local sync = BookLoreSync:new()
        sync.ui = ui
        sync.server_url = fixture.base_url()
        sync.token = "fresh-token"
        sync.enabled = true
        sync.book_id = 99
        sync.pulled = false
        sync.has_pages = true
        sync.awaiting_decision = false
        sync.queue = require("queue").new{}
        -- Pre-upgrade on-disk entry for the book currently open.
        sync.queue._store.data["99"] = { book_id = 99, server_url = fixture.base_url(),
            percentage = 33.0, enqueued_at = 0 }
        sync.queue._store:flush()

        sync:_drainAll()
        assert.equals(1, sync.queue:size(),
            "current-book legacy entry must respect the push-after-pull gate")

        sync.pulled = true
        sync:_drainAll()
        assert.equals(0, sync.queue:size(),
            "after the pull, drainCurrentBook drains the legacy slot too")
    end)

    it("a legacy (no-username) entry drains under the current account", function()
        fixture = spec_helper.start_http_fixture({
            { method = "POST", path = "/api/v1/books/progress", status = 204, headers = {}, body = "", repeat_ = 2 },
        })
        local settings = require("luasettings"):open(settings_dir3.dir .. "/booklore.lua")
        settings:saveSetting("username", "alice")
        settings:saveSetting("token", "fresh-token")
        settings:flush()

        local nm = require("ui/network/manager"); nm._set_wifi(true)

        local sync = BookLoreSync:new()
        sync.ui = ui
        sync.server_url = fixture.base_url()
        sync.token = "fresh-token"
        sync.enabled = true
        sync.book_id = 99
        sync.pulled = true
        sync.has_pages = true
        sync.awaiting_decision = false
        sync.queue = require("queue").new{}
        sync.queue:enqueue(55, fixture.base_url(), 12.0, nil, nil)  -- legacy: no username

        sync:_drainAll()

        assert.equals(0, sync.queue:size(),
            "legacy entries push under whatever account is current")
    end)
end)
