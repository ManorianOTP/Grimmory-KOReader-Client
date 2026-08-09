--[[
  Sync state machine spec for grimmory_sync.koplugin/main.lua.

  Uses stub UIManager + virtual clock to exercise debounce and push-after-pull
  gate deterministically without real I/O or sleep.
]]
local spec_helper  = require("spec_helper")
local fake_settings = require("fake_settings_dir")

local GrimmorySync
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

describe("Grimmory App progress wire contract", function()
    local contract_settings

    before_each(function()
        spec_helper.setup()
        contract_settings = fake_settings.create({
            server_url = "http://127.0.0.1",
            token = "wire-token",
            token_time = os.time(),
            username = "alice",
        })
        require("datastorage")._set_dir(contract_settings.dir)
        GrimmorySync = require("grimmory_sync")
    end)

    after_each(function()
        if fixture then fixture.stop(); fixture = nil end
        contract_settings.cleanup()
        spec_helper.teardown()
    end)

    local function make_contract_sync(file, has_pages, percent, page)
        local sync = GrimmorySync:new()
        sync.ui = make_fake_ui(file, 99, nil)
        sync.ui.document.info.has_pages = has_pages
        sync.ui._percent = percent or 0.42
        if page then
            sync.ui.paging.getLastProgress = function() return page end
        end
        sync.server_url = fixture.base_url()
        sync.token = "wire-token"
        sync.username = "alice"
        sync.enabled = true
        sync.book_id = 99
        sync.pulled = true
        sync.awaiting_decision = false
        sync.has_pages = has_pages
        sync.queue = require("queue").new{}
        local settings = require("luasettings"):open(contract_settings.dir .. "/grimmory.lua")
        settings:saveSetting("server_url", fixture.base_url())
        settings:saveSetting("username", "alice")
        settings:saveSetting("active_account", {
            server_url = fixture.base_url(), username = "alice",
        })
        settings:saveSetting("accounts", {{
            server_url = fixture.base_url(), username = "alice",
            token = "wire-token", token_time = os.time(),
        }})
        settings:flush()
        return sync
    end

    it("reads canonical file identity and keeps the pre-v2 path fallback", function()
        local registry = require("luasettings"):open(
            contract_settings.dir .. "/grimmory_downloads.lua")
        registry:saveSetting("canonical", {
            path = "/books/selected.cbz",
            server_id = 99,
            server_url = "http://grimmory.example",
            file_id = 701,
            book_type = "CBX",
        })
        registry:saveSetting("pre-v2", {
            path = "/books/older.pdf",
            server_id = 100,
            server_url = "http://grimmory.example",
        })
        registry:flush()

        local sync = GrimmorySync:new()
        local book_id, server_url, file_id, file_type =
            sync:lookupBookId("/books/selected.cbz")
        assert.equals(99, book_id)
        assert.equals("http://grimmory.example", server_url)
        assert.equals(701, file_id)
        assert.equals("CBX", file_type)

        local old_book_id, _, old_file_id, old_file_type =
            sync:lookupBookId("/books/older.pdf")
        assert.equals(100, old_book_id)
        assert.is_nil(old_file_id)
        assert.equals("PDF", old_file_type,
            "pre-v2 entries infer type only from their exact registered path")
    end)

    it("does not present another server account's token while pulling", function()
        fixture = spec_helper.start_http_fixture({})
        local sync = make_contract_sync("/books/test.epub", false, 0.10)
        sync.file_type = "EPUB"
        sync.pulled = false
        local settings = require("luasettings"):open(
            contract_settings.dir .. "/grimmory.lua")
        settings:saveSetting("active_account", {
            server_url = "http://other-grimmory.example",
            username = "alice",
        })
        settings:saveSetting("server_url", "http://other-grimmory.example")
        settings:flush()

        sync:pullProgress()

        assert.is_false(sync.pulled)
        assert.is_true(require("logger").has("warn", "active account does not own"),
            "the server-scoping guard must run before any HTTP request")
    end)

    it("PUTs exact selected-file EPUB CFI progress with Bearer auth", function()
        local cfi_value = "epubcfi(/6/4[chapter]!/4/2/1:7)"
        fixture = spec_helper.start_http_fixture({{
            method = "PUT",
            path = "/api/v1/app/books/99/progress",
            status = 200,
            headers = {},
            body = "",
            expect_headers = { Authorization = "Bearer wire-token" },
            expect_json = {
                fileProgress = {
                    bookFileId = 501,
                    positionData = cfi_value,
                    progressPercent = 42,
                },
            },
        }})
        local sync = make_contract_sync("/books/test.epub", false, 0.42)
        sync.file_id, sync.file_type = 501, "EPUB"
        sync.queue:enqueue(99, fixture.base_url(), 42, cfi_value,
            "alice", 501, "EPUB")

        sync:_drainAll()

        assert.equals(0, sync.queue:size(),
            "a contract-valid 200 removes the exact queued entry")
    end)

    it("reads the cross-populated web EPUB field and routes it through our converter", function()
        local cfi_value = "epubcfi(/6/4[chapter]!/4/2/1:7)"
        local expected_xpointer = "/body/DocFragment[1]/body/p[1]/text()[1].7"
        fixture = spec_helper.start_http_fixture({{
            method = "GET",
            path = "/api/v1/app/books/99/progress",
            status = 200,
            headers = { ["Content-Type"] = "application/json" },
            body = '{"readProgress":55,"epubProgress":{"cfi":"' .. cfi_value
                .. '","percentage":55}}',
            expect_headers = { Authorization = "Bearer wire-token" },
        }})
        local sync = make_contract_sync("/books/test.epub", false, 0.10)
        sync.file_id, sync.file_type = 501, "EPUB"
        local converter_input
        sync.cfi = {
            cfiToXPointer = function(value)
                converter_input = value
                return expected_xpointer
            end,
        }

        sync:pullProgress()
        local box = require("ui/widget/multiconfirmbox")._last
        assert.not_nil(box, "the newer web-reader position must trigger conflict handling")
        box.choice1_callback()

        assert.equals(cfi_value, converter_input,
            "the App API's epubProgress.cfi enters our protected converter unchanged")
        assert.equals("GotoXPointer", sync.ui._events[#sync.ui._events].name)
        assert.equals(expected_xpointer, sync.ui._events[#sync.ui._events].args[1])
    end)

    for _, case in ipairs({
        { name = "PDF", file_type = "PDF", file_id = 601, page = 17 },
        { name = "CBX", file_type = "CBX", file_id = 701, page = 23 },
    }) do
        it("PUTs exact selected-file " .. case.name .. " page progress", function()
            fixture = spec_helper.start_http_fixture({{
                method = "PUT",
                path = "/api/v1/app/books/99/progress",
                status = 200,
                headers = {},
                body = "",
                expect_headers = { Authorization = "Bearer wire-token" },
                expect_json = {
                    fileProgress = {
                        bookFileId = case.file_id,
                        positionData = tostring(case.page),
                        progressPercent = 42,
                    },
                },
            }})
            local ext = case.file_type == "PDF" and "pdf" or "cbz"
            local sync = make_contract_sync("/books/test." .. ext, true, 0.42, case.page)
            sync.file_id, sync.file_type = case.file_id, case.file_type
            sync.queue:enqueue(99, fixture.base_url(), 42, tostring(case.page),
                "alice", case.file_id, case.file_type)
            sync:_drainAll()
            assert.equals(0, sync.queue:size())
        end)
    end

    it("keeps and drains two formats of one book to their exact file identities", function()
        local cfi_value = "epubcfi(/6/4[chapter]!/4/2/1:7)"
        fixture = spec_helper.start_http_fixture({
            {
                method = "PUT",
                path = "/api/v1/app/books/99/progress",
                status = 200,
                headers = {},
                body = "",
                repeat_ = 1,
                expect_headers = { Authorization = "Bearer wire-token" },
                expect_json = {
                    fileProgress = {
                        bookFileId = 501,
                        positionData = cfi_value,
                        progressPercent = 42,
                    },
                },
            },
            {
                method = "PUT",
                path = "/api/v1/app/books/99/progress",
                status = 200,
                headers = {},
                body = "",
                repeat_ = 1,
                expect_headers = { Authorization = "Bearer wire-token" },
                expect_json = {
                    fileProgress = {
                        bookFileId = 601,
                        positionData = "17",
                        progressPercent = 55,
                    },
                },
            },
        })
        local sync = make_contract_sync("/books/test.epub", false, 0.42)
        sync.file_id, sync.file_type = 501, "EPUB"
        local server = fixture.base_url()
        sync.queue:enqueue(99, server, 42, cfi_value, "alice", 501, "EPUB")
        sync.queue:enqueue(99, server, 55, "17", "alice", 601, "PDF")

        assert.equals(2, sync.queue:size(),
            "same account/server/book retains one durable slot per selected file")
        assert.equals(cfi_value,
            sync.queue:peek(99, "alice", server, 501, "EPUB").position_data)
        assert.equals("17",
            sync.queue:peek(99, "alice", server, 601, "PDF").position_data)
        local gated = sync.queue:currentBookDrainable(
            99, "alice", server, 501, "EPUB")
        local independently_drainable = sync.queue:othersDrainable(
            99, "alice", server, 501, "EPUB")
        assert.equals(1, #gated)
        assert.equals(501, gated[1].entry.file_id,
            "pull-before-push gates only the exact open file")
        assert.equals(1, #independently_drainable)
        assert.equals(601, independently_drainable[1].entry.file_id,
            "another format of the same book remains independently drainable")

        sync:_drainAll()

        assert.equals(0, sync.queue:size(),
            "both exact per-file 200 responses acknowledge their own slots")
    end)

    it("keeps identical account/book/file identities separate by server", function()
        local queue = require("queue").new{}
        queue:enqueue(99, "http://grimmory-a.example", 20, "cfi-a",
            "alice", 501, "EPUB")
        queue:enqueue(99, "http://grimmory-b.example", 80, "cfi-b",
            "alice", 501, "EPUB")

        assert.equals(2, queue:size())
        assert.equals("cfi-a", queue:peek(99, "alice",
            "http://grimmory-a.example", 501, "EPUB").position_data)
        assert.equals("cfi-b", queue:peek(99, "alice",
            "http://grimmory-b.example", 501, "EPUB").position_data)
    end)

    for _, case in ipairs({
        { name = "PDF", file_type = "PDF", field = "pdfProgress", page = 17 },
        { name = "CBX", file_type = "CBX", field = "cbxProgress", page = 23 },
    }) do
        it("pulls exact " .. case.name .. " web-reader page progress", function()
            fixture = spec_helper.start_http_fixture({{
                method = "GET",
                path = "/api/v1/app/books/99/progress",
                status = 200,
                headers = { ["Content-Type"] = "application/json" },
                body = '{"' .. case.field .. '":{"page":' .. tostring(case.page)
                    .. ',"percentage":55}}',
                expect_headers = { Authorization = "Bearer wire-token" },
            }})
            local ext = case.file_type == "PDF" and "pdf" or "cbz"
            local sync = make_contract_sync("/books/test." .. ext, true, 0.10, 2)
            sync.file_type = case.file_type

            sync:pullProgress()
            local box = require("ui/widget/multiconfirmbox")._last
            assert.not_nil(box)
            box.choice1_callback()

            assert.equals("GotoPage", sync.ui._events[#sync.ui._events].name)
            assert.equals(case.page, sync.ui._events[#sync.ui._events].args[1])
        end)
    end

    it("does not discard queued progress on a 204 response", function()
        fixture = spec_helper.start_http_fixture({{
            method = "PUT",
            path = "/api/v1/app/books/99/progress",
            status = 204,
            headers = {},
            body = "",
            expect_headers = { Authorization = "Bearer wire-token" },
            expect_json = {
                fileProgress = {
                    bookFileId = 601,
                    positionData = "17",
                    progressPercent = 42,
                },
            },
        }})
        local sync = make_contract_sync("/books/test.pdf", true, 0.42, 17)
        sync.file_id, sync.file_type = 601, "PDF"
        sync.queue:enqueue(99, fixture.base_url(), 42, "17", "alice", 601, "PDF")

        sync:_drainAll()

        assert.equals(1, sync.queue:size(),
            "only the App endpoint's documented 200 acknowledges selected-file progress")
    end)

    it("builds type-correct primary-file fallbacks for existing Grimmory entries", function()
        local cfi_value = "epubcfi(/6/4[chapter]!/4/2/1:7)"
        assert.same({ epubProgress = { cfi = cfi_value, percentage = 10 } },
            GrimmorySync._buildProgressPayload(nil, "EPUB", 10, cfi_value))
        assert.same({ pdfProgress = { page = 7, percentage = 20 } },
            GrimmorySync._buildProgressPayload(nil, "PDF", 20, "7"))
        assert.same({ cbxProgress = { page = 9, percentage = 30 } },
            GrimmorySync._buildProgressPayload(nil, "CBX", 30, "9"))
    end)

    it("fails closed on invalid selected-file EPUB/PDF/CBX positions", function()
        for _, case in ipairs({
            { file_id = 501, file_type = "EPUB" },
            { file_id = 502, file_type = "EPUB", position = "   " },
            { file_id = 503, file_type = "EPUB", position = "not-a-cfi" },
            { file_id = 601, file_type = "PDF", position = "page-17" },
            { file_id = 602, file_type = "PDF", position = "1.5" },
            { file_id = 701, file_type = "CBX" },
            { file_id = 702, file_type = "CBX", position = "-1" },
        }) do
            assert.is_nil(GrimmorySync._buildProgressPayload(
                case.file_id, case.file_type, 42, case.position),
                case.file_type .. " must not erase its exact web-reader position")
        end

        assert.same({
            fileProgress = { bookFileId = 801, progressPercent = 42 },
        }, GrimmorySync._buildProgressPayload(801, "FB2", 42, nil))
    end)

    it("fails closed on invalid primary-file EPUB/PDF/CBX fallbacks", function()
        assert.is_nil(GrimmorySync._buildProgressPayload(nil, "EPUB", 42, nil))
        assert.is_nil(GrimmorySync._buildProgressPayload(nil, "PDF", 42, "unknown"))
        assert.is_nil(GrimmorySync._buildProgressPayload(nil, "CBX", 42, "2.5"))
        assert.same({ epubProgress = { percentage = 42 } },
            GrimmorySync._buildProgressPayload(nil, "MOBI", 42, nil))
    end)

    it("retains selected-file and fallback queue slots when exact capture fails", function()
        fixture = spec_helper.start_http_fixture({})
        local sync = make_contract_sync("/books/test.epub", false, 0.42)
        sync.file_id, sync.file_type = 501, "EPUB"
        local server = fixture.base_url()
        sync.queue:enqueue(99, server, 42, "   ", "alice", 501, "EPUB")
        sync.queue:enqueue(99, server, 55, "not-a-page", "alice", nil, "PDF")

        sync:_drainAll()

        assert.equals(2, sync.queue:size(),
            "invalid position capture must not make a destructive progress request")
        assert.not_nil(sync.queue:peek(99, "alice", server, 501, "EPUB"))
        assert.not_nil(sync.queue:peek(99, "alice", server, nil, "PDF"))
    end)

    local function set_credentials(token, refresh_token, token_time)
        local settings = require("luasettings"):open(contract_settings.dir .. "/grimmory.lua")
        settings:saveSetting("token", token)
        settings:saveSetting("refresh_token", refresh_token)
        settings:saveSetting("token_time", token_time)
        local accounts = settings:readSetting("accounts") or {}
        for _, account in ipairs(accounts) do
            if account.server_url == fixture.base_url() and account.username == "alice" then
                account.token = token
                account.refresh_token = refresh_token
                account.token_time = token_time
            end
        end
        settings:saveSetting("accounts", accounts)
        settings:flush()
        return settings
    end

    local function persisted_credential(key)
        return require("luasettings"):open(
            contract_settings.dir .. "/grimmory.lua"):readSetting(key)
    end

    it("does not overwrite a newly active account from an old async callback", function()
        local settings = require("luasettings"):open(
            contract_settings.dir .. "/grimmory.lua")
        settings:saveSetting("token", "bob-live")
        settings:saveSetting("refresh_token", "bob-refresh")
        settings:saveSetting("token_time", 222)
        settings:saveSetting("active_account", {
            server_url = "http://server-b.example", username = "bob",
        })
        settings:saveSetting("accounts", {
            {
                server_url = "http://server-a.example", username = "alice",
                token = "alice-old", refresh_token = "alice-old-refresh", token_time = 111,
            },
            {
                server_url = "http://server-b.example", username = "bob",
                token = "bob-live", refresh_token = "bob-refresh", token_time = 222,
            },
        })
        settings:flush()
        local sync = GrimmorySync:new()
        sync.token = "bob-live"

        -- Simulate Alice's refresh child returning after Bob became active.
        sync:_applyCredentials({
            rotated = true,
            token = "alice-rotated",
            refresh_token = "alice-rotated-refresh",
            token_time = 333,
        }, "http://server-a.example", "alice")

        local persisted = require("luasettings"):open(
            contract_settings.dir .. "/grimmory.lua")
        assert.equals("bob-live", persisted:readSetting("token"))
        assert.equals("bob-refresh", persisted:readSetting("refresh_token"))
        assert.equals("bob-live", sync.token)
        local accounts = persisted:readSetting("accounts")
        assert.equals("alice-rotated", accounts[1].token,
            "the completed child still updates its own saved account")
        assert.equals("alice-rotated-refresh", accounts[1].refresh_token)
        assert.equals("bob-live", accounts[2].token,
            "the newly active account remains untouched")
    end)

    it("refreshes an expired access token in the background before pull", function()
        fixture = spec_helper.start_http_fixture({
            {
                method = "POST",
                path = "/api/v1/auth/refresh",
                status = 200,
                headers = { ["Content-Type"] = "application/json" },
                body = '{"accessToken":"fresh-token","refreshToken":"rotated-refresh"}',
                expect_json = { refreshToken = "refresh-1" },
            },
            {
                method = "GET",
                path = "/api/v1/app/books/99/progress",
                status = 200,
                headers = { ["Content-Type"] = "application/json" },
                body = '{"epubProgress":null}',
                expect_headers = { Authorization = "Bearer fresh-token" },
            },
        })
        local sync = make_contract_sync("/books/test.epub", false, 0.10)
        sync.file_type = "EPUB"
        local settings = set_credentials("expired-token", "refresh-1", 0)

        sync:pullProgress()

        assert.is_true(sync.pulled)
        assert.equals("fresh-token", persisted_credential("token"))
        assert.equals("rotated-refresh", persisted_credential("refresh_token"))
    end)

    it("reactively refreshes once after an access-token 401", function()
        fixture = spec_helper.start_http_fixture({
            {
                method = "GET",
                path = "/api/v1/app/books/99/progress",
                status = 401,
                headers = {},
                body = "expired",
                repeat_ = 1,
                expect_headers = { Authorization = "Bearer old-token" },
            },
            {
                method = "POST",
                path = "/api/v1/auth/refresh",
                status = 200,
                headers = { ["Content-Type"] = "application/json" },
                body = '{"accessToken":"fresh-token","refreshToken":"rotated-refresh"}',
                expect_json = { refreshToken = "refresh-1" },
            },
            {
                method = "GET",
                path = "/api/v1/app/books/99/progress",
                status = 200,
                headers = { ["Content-Type"] = "application/json" },
                body = '{"epubProgress":null}',
                expect_headers = { Authorization = "Bearer fresh-token" },
            },
        })
        local sync = make_contract_sync("/books/test.epub", false, 0.10)
        sync.file_type = "EPUB"
        local settings = set_credentials("old-token", "refresh-1", os.time())

        sync:pullProgress()

        assert.is_true(sync.pulled)
        assert.equals("fresh-token", persisted_credential("token"))
        assert.equals("rotated-refresh", persisted_credential("refresh_token"))
    end)

    it("preserves credentials and queued progress on transient refresh failure", function()
        fixture = spec_helper.start_http_fixture({{
            method = "POST",
            path = "/api/v1/auth/refresh",
            status = 503,
            headers = {},
            body = "unavailable",
            expect_json = { refreshToken = "refresh-1" },
        }})
        local sync = make_contract_sync("/books/test.epub", false, 0.10)
        sync.file_type = "EPUB"
        sync.pulled = false
        sync.queue:enqueue(99, fixture.base_url(), 42, "cfi", "alice", 501, "EPUB")
        local settings = set_credentials("expired-token", "refresh-1", 0)

        sync:pullProgress()

        assert.is_false(sync.pulled)
        assert.equals(1, sync.queue:size())
        assert.equals("expired-token", persisted_credential("token"))
        assert.equals("refresh-1", persisted_credential("refresh_token"))
    end)

    it("clears credentials only when Grimmory definitively rejects refresh", function()
        fixture = spec_helper.start_http_fixture({{
            method = "POST",
            path = "/api/v1/auth/refresh",
            status = 401,
            headers = {},
            body = "revoked",
            expect_json = { refreshToken = "refresh-1" },
        }})
        local sync = make_contract_sync("/books/test.epub", false, 0.10)
        sync.file_type = "EPUB"
        sync.pulled = false
        sync.queue:enqueue(99, fixture.base_url(), 42, "cfi", "alice", 501, "EPUB")
        local settings = set_credentials("expired-token", "refresh-1", 0)

        sync:pullProgress()

        assert.is_false(sync.pulled)
        assert.equals(1, sync.queue:size(), "revocation must not discard captured progress")
        assert.is_nil(persisted_credential("token"))
        assert.is_nil(persisted_credential("refresh_token"))
    end)
end)

describe("GrimmorySync state machine", function()
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

        GrimmorySync = require("grimmory_sync")
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
                    path = "/api/v1/app/books/99/progress",
                    status = 200,
                    headers = { ["Content-Type"] = "application/json" },
                    body = '{"id":99,"epubProgress":null}',
                    repeat_ = 1,
                },
            })
            -- Override server_url to point at fixture
            local settings = require("luasettings"):open(settings_dir.dir .. "/grimmory.lua")
            settings:saveSetting("server_url", fixture.base_url())
            settings:flush()

            local sync = GrimmorySync:new()
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
                    path = "/api/v1/app/books/99/progress",
                    status = 200,
                    headers = { ["Content-Type"] = "application/json" },
                    body = '{"id":99,"epubProgress":null}',
                },
                {
                    method = "PUT",
                    path = "/api/v1/app/books/99/progress",
                    status = 200,
                    headers = {},
                    body = "",
                },
            })
            local sync = GrimmorySync:new()
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
                    method = "PUT",
                    path = "/api/v1/app/books/99/progress",
                    status = 200,
                    headers = {},
                    body = "",
                },
            })
            local sync = GrimmorySync:new()
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
                    path = "/api/v1/app/books/99/progress",
                    status = 200,
                    headers = { ["Content-Type"] = "application/json" },
                    body = '{"id":99,"epubProgress":{"percentage":80.0,"cfi":null}}',
                    repeat_ = 1,
                },
                {
                    method = "PUT",
                    path = "/api/v1/app/books/99/progress",
                    status = 200,
                    headers = {},
                    body = "",
                    repeat_ = 1,
                },
            })

            local sync = GrimmorySync:new()
            sync.ui = ui
            sync.server_url = fixture.base_url()
            sync.token = "test-token"
            sync.enabled = true
            sync.book_id = 99
            sync.pulled = false
            sync.has_pages = false
            sync.file_type = "EPUB"
            sync.push_in_progress = false
            sync.awaiting_decision = false
            sync.cfi = {
                xpointerToCFI = function()
                    return "epubcfi(/6/4[chapter]!/4/2/1:7)"
                end,
            }

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
                    path = "/api/v1/app/books/99/progress",
                    status = 503,
                    headers = {},
                    body = "Service Unavailable",
                    repeat_ = 1,
                },
            })
            local sync = GrimmorySync:new()
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
                    method = "PUT",
                    path = "/api/v1/app/books/99/progress",
                    status = 200,
                    headers = {},
                    body = "",
                },
            })
            local sync = GrimmorySync:new()
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

describe("GrimmorySync offline queue", function()
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
        GrimmorySync = require("grimmory_sync")
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

        local sync = GrimmorySync:new()
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
        local sync = GrimmorySync:new()
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
                path = "/api/v1/app/books/99/progress",
                status = 200,
                headers = { ["Content-Type"] = "application/json" },
                body = '{"id":99,"epubProgress":null}',
                repeat_ = 1,
            },
            {
                method = "PUT",
                path = "/api/v1/app/books/99/progress",
                status = 200,
                headers = {},
                body = "",
                repeat_ = 1,
            },
        })

        local settings = require("luasettings"):open(settings_dir2.dir .. "/grimmory.lua")
        settings:saveSetting("server_url", fixture.base_url())
        settings:flush()

        local sync = GrimmorySync:new()
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
        sync.queue:enqueue(99, fixture.base_url(), 42.0,
            "epubcfi(/6/4[chapter]!/4/2/1:7)", nil, nil, "EPUB")

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
                path = "/api/v1/app/books/99/progress",
                status = 503,
                headers = {},
                body = "Service Unavailable",
                repeat_ = 1,
            },
        })

        local sync = GrimmorySync:new()
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

describe("GrimmorySync token-independent capture & per-account drain", function()
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
        GrimmorySync = require("grimmory_sync")
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
        local sync = GrimmorySync:new()
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
        local sync = GrimmorySync:new()
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
        assert.is_true(logger.has("warn", "no credentials, skipping pull"),
            "the no-token guard must fire before any network code")
        assert.is_false(logger.has("dbg", "pushed progress"))
        assert.equals(1, sync.queue:size(),
            "queued entry stays untouched (sanity check; pull never drains)")
    end)

    it("drain pushes only entries owned by the logged-in account", function()
        fixture = spec_helper.start_http_fixture({
            { method = "PUT", path = "/api/v1/app/books/88/progress", status = 200, headers = {}, body = "", repeat_ = 5 },
        })
        local settings = require("luasettings"):open(settings_dir3.dir .. "/grimmory.lua")
        settings:saveSetting("username", "alice")
        settings:saveSetting("token", "alice-token")
        settings:flush()

        local nm = require("ui/network/manager"); nm._set_wifi(true)

        local sync = GrimmorySync:new()
        sync.ui = ui
        sync.server_url = fixture.base_url()
        sync.token = "alice-token"
        sync.enabled = true
        sync.book_id = 99
        sync.pulled = true
        sync.has_pages = true
        sync.awaiting_decision = false
        sync.queue = require("queue").new{}
        sync.queue:enqueue(88, fixture.base_url(), 30.0,
            "epubcfi(/6/4[chapter]!/4/2/1:7)", "alice", nil, "EPUB")
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
            { method = "PUT", path = "/api/v1/app/books/99/progress", status = 200, headers = {}, body = "", repeat_ = 2 },
        })
        local settings = require("luasettings"):open(settings_dir3.dir .. "/grimmory.lua")
        settings:saveSetting("username", "alice")
        settings:saveSetting("token", "fresh-token")
        settings:flush()

        local nm = require("ui/network/manager"); nm._set_wifi(true)

        local sync = GrimmorySync:new()
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
            percentage = 33.0, cfi = "epubcfi(/6/4[chapter]!/4/2/1:7)",
            enqueued_at = 0 }
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
            { method = "PUT", path = "/api/v1/app/books/55/progress", status = 200, headers = {}, body = "", repeat_ = 2 },
        })
        local settings = require("luasettings"):open(settings_dir3.dir .. "/grimmory.lua")
        settings:saveSetting("username", "alice")
        settings:saveSetting("token", "fresh-token")
        settings:flush()

        local nm = require("ui/network/manager"); nm._set_wifi(true)

        local sync = GrimmorySync:new()
        sync.ui = ui
        sync.server_url = fixture.base_url()
        sync.token = "fresh-token"
        sync.enabled = true
        sync.book_id = 99
        sync.pulled = true
        sync.has_pages = true
        sync.awaiting_decision = false
        sync.queue = require("queue").new{}
        sync.queue:enqueue(55, fixture.base_url(), 12.0,
            "epubcfi(/6/4[chapter]!/4/2/1:7)", nil, nil, "EPUB")

        sync:_drainAll()

        assert.equals(0, sync.queue:size(),
            "legacy entries push under whatever account is current")
    end)
end)
