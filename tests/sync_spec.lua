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
