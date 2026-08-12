--[[
  API client spec for grimmory.koplugin/api.lua.

  Each scenario starts a local http_fixture and tears it down after_each
  so port assignment and request log are isolated between tests.
]]
local spec_helper = require("spec_helper")

local GrimmoryApi
local fixture

describe("GrimmoryApi", function()
    before_each(function()
        spec_helper.setup()
        GrimmoryApi = require("api")
    end)

    after_each(function()
        if fixture then
            fixture.stop()
            fixture = nil
        end
        spec_helper.teardown()
    end)

    describe("normalizeServerUrl", function()
        it("prepends http:// when no scheme is given", function()
            assert.are.equal("http://192.168.1.50:6060",
                GrimmoryApi.normalizeServerUrl("192.168.1.50:6060"))
        end)
        it("preserves an explicit https scheme", function()
            assert.are.equal("https://books.example.com",
                GrimmoryApi.normalizeServerUrl("https://books.example.com"))
        end)
        it("trims whitespace and drops a trailing slash", function()
            assert.are.equal("http://host:6060",
                GrimmoryApi.normalizeServerUrl("  http://host:6060/  "))
        end)
        it("returns empty string for blank or nil input", function()
            assert.are.equal("", GrimmoryApi.normalizeServerUrl(""))
            assert.are.equal("", GrimmoryApi.normalizeServerUrl("   "))
            assert.are.equal("", GrimmoryApi.normalizeServerUrl(nil))
        end)
    end)

    describe("login", function()
        it("returns access and refresh tokens on success", function()
            fixture = spec_helper.start_http_fixture({
                {
                    method = "POST",
                    path = "/api/v1/auth/login",
                    status = 200,
                    headers = { ["Content-Type"] = "application/json" },
                    body_file = "login_ok.json",
                    expect_headers = { ["Content-Type"] = "application/json" },
                    expect_json = { username = "user", password = "pass" },
                    repeat_ = 1,
                },
            })
            local token, refresh, err = GrimmoryApi:login(fixture.base_url(), "user", "pass")
            assert.is_nil(err, tostring(err))
            assert.equals("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0dXNlciJ9.stub", token)
            assert.equals("refresh-stub-token-abc123", refresh)
        end)

        it("surfaces a typed error on 401", function()
            fixture = spec_helper.start_http_fixture({
                {
                    method = "POST",
                    path = "/api/v1/auth/login",
                    status = 401,
                    headers = { ["Content-Type"] = "application/json" },
                    body_file = "login_unauthorized.json",
                    repeat_ = 1,
                },
            })
            local token, refresh, err = GrimmoryApi:login(fixture.base_url(), "user", "wrong")
            assert.is_nil(token)
            assert.is_string(err)
            assert.truthy(err:match("401"), "error should mention 401, got: " .. tostring(err))
        end)
    end)

    describe("refreshToken", function()
        it("returns new access and refresh tokens", function()
            fixture = spec_helper.start_http_fixture({
                {
                    method = "POST",
                    path = "/api/v1/auth/refresh",
                    status = 200,
                    headers = { ["Content-Type"] = "application/json" },
                    body_file = "refresh_ok.json",
                    expect_headers = { ["Content-Type"] = "application/json" },
                    expect_json = { refreshToken = "old-refresh-token" },
                    repeat_ = 1,
                },
            })
            local token, refresh, err = GrimmoryApi:refreshToken(fixture.base_url(), "old-refresh-token")
            assert.is_nil(err, tostring(err))
            assert.equals("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0dXNlciIsImV4cCI6OTk5OTk5OTk5OX0.new", token)
            assert.equals("new-refresh-token-xyz789", refresh)
        end)
    end)

    describe("getBooks (Grimmory v3 list)", function()
        it("normalizes primaryFile fields used by the KOReader UI", function()
            fixture = spec_helper.start_http_fixture({
                {
                    method = "GET",
                    path = "/api/v1/books/page",
                    status = 404,
                    expect_query = { page = "0", size = "100" },
                    expect_headers = { Authorization = "Bearer test-token" },
                    body = "not supported",
                    repeat_ = 1,
                },
                {
                    method = "GET",
                    path = "/api/v1/books",
                    status = 200,
                    headers = { ["Content-Type"] = "application/json" },
                    body_file = "library_books_page1.json",
                    expect_query = {
                        withDescription = "false",
                        stripForListView = "true",
                    },
                    expect_headers = { Authorization = "Bearer test-token" },
                },
            })
            local data, err = GrimmoryApi:getBooks(fixture.base_url(), "test-token")
            assert.is_nil(err, tostring(err))
            assert.is_table(data)
            assert.equals(2, #data)
            assert.equals("test_book_one.epub", data[1].fileName)
            assert.equals(1024, data[1].fileSizeKb)
            assert.equals("EPUB", data[1].bookType)
            assert.equals("2026-08-01T10:00:00Z", data[1].coverUpdatedOn)
            assert.equals("2026-08-03T09:00:00Z", data[1].lastReadTime)
            assert.equals("2026-07-01T08:00:00Z", data[1].addedOn)
            assert.is_true(data[1].locked)
            assert.equals(101, data[1].primaryFile.id)
            assert.equals(2, #data[1].bookFiles)
            assert.equals(2, #data[1].downloadFiles)
            assert.equals(201, data[1].downloadFiles[2].id)
            assert.equals("PDF", data[1].downloadFiles[2].bookType)
            assert.is_true(data[1].downloadEligible)
            assert.same({ 101, 201 }, {
                data[1].bookFiles[1].id, data[1].bookFiles[2].id,
            })
            assert.same({ 101, 201 }, {
                data[1].downloadFiles[1].id, data[1].downloadFiles[2].id,
            })
            assert.same({ 2 }, { data[2].downloadFiles[1].bookId })
        end)

        it("traverses every native Grimmory page", function()
            fixture = spec_helper.start_http_fixture({
                {
                    method = "GET",
                    path = "/api/v1/books/page",
                    status = 200,
                    headers = { ["Content-Type"] = "application/json" },
                    expect_query = { page = "0", size = "100" },
                    expect_headers = { Authorization = "Bearer page-token" },
                    body = [[{"content":[{"id":1,"primaryFile":{"id":101,"bookId":1,"fileName":"one.epub","fileSizeKb":10,"bookType":"EPUB","book":true},"metadata":{"title":"One"},"alternativeFormats":[],"supplementaryFiles":[],"isPhysical":false}],"page":{"number":0,"size":100,"totalElements":2,"totalPages":2}}]],
                    repeat_ = 1,
                },
                {
                    method = "GET",
                    path = "/api/v1/books/page",
                    status = 200,
                    headers = { ["Content-Type"] = "application/json" },
                    expect_query = { page = "1", size = "100" },
                    expect_headers = { Authorization = "Bearer page-token" },
                    body = [[{"content":[{"id":2,"primaryFile":{"id":102,"bookId":2,"fileName":"two.pdf","fileSizeKb":20,"bookType":"PDF","book":true},"metadata":{"title":"Two"},"alternativeFormats":[],"supplementaryFiles":[],"isPhysical":false}],"page":{"number":1,"size":100,"totalElements":2,"totalPages":2}}]],
                    repeat_ = 1,
                },
            })
            local data, err = GrimmoryApi:getBooks(fixture.base_url(), "page-token")
            assert.is_nil(err, tostring(err))
            assert.equals(2, #data)
            assert.equals(1, data[1].id)
            assert.equals(2, data[2].id)
            assert.equals("PDF", data[2].primaryFile.bookType)
        end)

        it("rejects a content wrapper with no totalPages instead of truncating", function()
            fixture = spec_helper.start_http_fixture({
                {
                    method = "GET",
                    path = "/api/v1/books/page",
                    status = 200,
                    headers = { ["Content-Type"] = "application/json" },
                    expect_query = { page = "0", size = "100" },
                    body = [[{"content":[{"id":1}]}]],
                    repeat_ = 1,
                },
            })
            local data, err = GrimmoryApi:getBooks(fixture.base_url(), "test-token")
            assert.is_nil(data)
            assert.matches("omitted totalPages", err)
        end)

        it("rejects a first page whose response number is not zero", function()
            fixture = spec_helper.start_http_fixture({
                {
                    method = "GET",
                    path = "/api/v1/books/page",
                    status = 200,
                    headers = { ["Content-Type"] = "application/json" },
                    expect_query = { page = "0", size = "100" },
                    body = [[{"content":[{"id":2}],"page":{"number":1,"size":100,"totalElements":2,"totalPages":2}}]],
                    repeat_ = 1,
                },
            })
            local data, err = GrimmoryApi:getBooks(fixture.base_url(), "test-token")
            assert.is_nil(data)
            assert.matches("first page number mismatch", err)
        end)

        it("rejects a duplicate book identity across pages", function()
            fixture = spec_helper.start_http_fixture({
                {
                    method = "GET", path = "/api/v1/books/page", status = 200,
                    expect_query = { page = "0", size = "100" },
                    body = [[{"content":[{"id":1}],"page":{"number":0,"size":100,"totalElements":2,"totalPages":2}}]],
                    repeat_ = 1,
                },
                {
                    method = "GET", path = "/api/v1/books/page", status = 200,
                    expect_query = { page = "1", size = "100" },
                    body = [[{"content":[{"id":1}],"page":{"number":1,"size":100,"totalElements":2,"totalPages":2}}]],
                },
            })
            local data, err = GrimmoryApi:getBooks(fixture.base_url(), "test-token")
            assert.is_nil(data)
            assert.equals("books pagination repeated book id 1", err)
        end)

        it("rejects missing or extra records against totalElements", function()
            fixture = spec_helper.start_http_fixture({{
                method = "GET", path = "/api/v1/books/page", status = 200,
                expect_query = { page = "0", size = "100" },
                body = [[{"content":[{"id":1},{"id":2}],"page":{"number":0,"size":100,"totalElements":1,"totalPages":1}}]],
            }})
            local data, err = GrimmoryApi:getBooks(fixture.base_url(), "test-token")
            assert.is_nil(data)
            assert.equals("books pagination count mismatch: expected 1, got 2", err)
        end)

        it("rejects totals that change on a later page", function()
            fixture = spec_helper.start_http_fixture({
                {
                    method = "GET", path = "/api/v1/books/page", status = 200,
                    expect_query = { page = "0", size = "100" },
                    body = [[{"content":[{"id":1}],"page":{"number":0,"size":100,"totalElements":2,"totalPages":2}}]],
                    repeat_ = 1,
                },
                {
                    method = "GET", path = "/api/v1/books/page", status = 200,
                    expect_query = { page = "1", size = "100" },
                    body = [[{"content":[{"id":2}],"page":{"number":1,"size":100,"totalElements":3,"totalPages":2}}]],
                },
            })
            local data, err = GrimmoryApi:getBooks(fixture.base_url(), "test-token")
            assert.is_nil(data)
            assert.equals("books pagination totals changed on page 1", err)
        end)

        it("keeps a BookLore-era flat primary file downloadable", function()
            local book = GrimmoryApi.normalizeBook({
                id = 77,
                fileName = "legacy.epub",
                fileSizeKb = 123,
                bookType = "EPUB",
                createdAt = "2024-01-01T00:00:00Z",
                lastReadAt = "2024-02-01T00:00:00Z",
                metadata = { title = "Legacy" },
            })
            assert.equals("legacy.epub", book.primaryFile.fileName)
            assert.is_true(book.primaryFile.isPrimary)
            assert.is_true(book.downloadEligible)
            assert.equals("2024-01-01T00:00:00Z", book.addedOn)
            assert.equals("2024-02-01T00:00:00Z", book.lastReadTime)
        end)

        it("treats decoded JSON null sentinels as absent optional fields", function()
            local json_null = function() end
            local book = GrimmoryApi.normalizeBook({
                id = 78,
                lastReadTime = json_null,
                addedOn = json_null,
                metadata = {
                    title = "Nullable",
                    subtitle = json_null,
                },
                primaryFile = {
                    id = 7801,
                    fileName = "nullable.epub",
                    bookType = "EPUB",
                    book = true,
                    folderBased = json_null,
                },
            })

            assert.is_nil(book.lastReadTime)
            assert.is_nil(book.addedOn)
            assert.is_nil(book.metadata.subtitle)
            assert.is_nil(book.primaryFile.folderBased)
            assert.equals("Nullable", book.title)
            assert.is_true(book.primaryFile.downloadEligible)
        end)
    end)

    describe("getVersion", function()
        it("discovers Grimmory v3 capabilities", function()
            fixture = spec_helper.start_http_fixture({{
                method = "GET",
                path = "/api/v1/version",
                status = 200,
                headers = { ["Content-Type"] = "application/json" },
                expect_headers = { Authorization = "Bearer test-token" },
                body = [[{"current":"3.3.1","latest":"3.3.1"}]],
            }})
            local info, err = GrimmoryApi:getVersion(fixture.base_url(), "test-token")
            assert.is_nil(err, tostring(err))
            assert.same({
                available = true,
                current = "3.3.1",
                latest = "3.3.1",
                capabilities = {
                    version = true,
                    paginatedBooks = true,
                    bookFiles = true,
                    multiFormat = true,
                    physicalBooks = true,
                },
            }, info)
        end)

        it("gracefully reports an absent BookLore-era version endpoint", function()
            fixture = spec_helper.start_http_fixture({{
                method = "GET",
                path = "/api/v1/version",
                status = 404,
                body = "not found",
            }})
            local info, err = GrimmoryApi:getVersion(fixture.base_url(), "test-token")
            assert.is_nil(err, tostring(err))
            assert.same({
                available = false,
                capabilities = {
                    version = false,
                    paginatedBooks = false,
                    bookFiles = false,
                    multiFormat = false,
                    physicalBooks = false,
                },
            }, info)
        end)
    end)

    describe("getBook (single, with description)", function()
        it("fetches /books/{id} and returns the full record", function()
            fixture = spec_helper.start_http_fixture({
                {
                    method = "GET",
                    path = "/api/v1/books/1",
                    status = 200,
                    headers = { ["Content-Type"] = "application/json" },
                    body_file = "book_metadata.json",
                    expect_query = { withDescription = "true" },
                    expect_headers = { Authorization = "Bearer test-token" },
                },
            })
            -- Arg order is (server_url, token, book_id) to match "token-second".
            local data, err = GrimmoryApi:getBook(fixture.base_url(), "test-token", 1)
            assert.is_nil(err, tostring(err))
            assert.is_table(data)
            assert.equals(1, data.id)
            assert.is_table(data.metadata)
            assert.equals("test_book_one.epub", data.fileName)
            assert.equals(1024, data.fileSizeKb)
            assert.equals("EPUB", data.bookType)
            assert.equals("2026-08-01T10:00:00Z", data.coverUpdatedOn)
            assert.equals(201, data.alternativeFormats[1].id)
            assert.equals("test_book_one.pdf", data.alternativeFormats[1].fileName)
            assert.equals(2, #data.downloadFiles)
        end)
    end)

    describe("mergeBookDetail", function()
        it("replaces stripped list placeholders with authoritative detail metadata", function()
            local list_book = {
                id = 7,
                metadata = {
                    title = "List title",
                    categories = {},
                    bookReviews = {},
                    _enriched = false,
                },
                alternativeFormats = {},
            }
            local full = {
                id = 7,
                primaryFile = {
                    id = 8, fileName = "book.epub", bookType = "EPUB", book = true,
                },
                metadata = {
                    title = "Provider title",
                    categories = { "Fantasy", "Adventure" },
                    bookReviews = { { reviewerName = "Reader" } },
                },
                alternativeFormats = {
                    { id = 9, fileName = "book.pdf", bookType = "PDF", book = true },
                },
            }

            local merged = GrimmoryApi.mergeBookDetail(list_book, full)

            assert.are.same({ "Fantasy", "Adventure" }, merged.metadata.categories)
            assert.are.equal(1, #merged.metadata.bookReviews)
            assert.are.equal("Provider title", merged.metadata.title)
            assert.is_false(merged.metadata._enriched)
            assert.are.equal(2, #merged.downloadFiles)
        end)
    end)

    describe("Book Files", function()
        it("lists only book files and preserves exact file identity", function()
            fixture = spec_helper.start_http_fixture({{
                method = "GET",
                path = "/api/v1/books/9/files",
                status = 200,
                headers = { ["Content-Type"] = "application/json" },
                expect_query = { isBook = "true" },
                expect_headers = { Authorization = "Bearer files-token" },
                body = [=[[{"id":901,"bookId":9,"fileName":"nine.pdf","fileSizeKb":55,"bookType":"PDF","extension":"pdf","book":true,"folderBased":false}]]=],
            }})
            local files, err = GrimmoryApi:getBookFiles(
                fixture.base_url(), "files-token", 9)
            assert.is_nil(err, tostring(err))
            assert.same({{
                id = 901, bookId = 9, fileName = "nine.pdf", fileSizeKb = 55,
                bookType = "PDF", extension = "pdf", book = true,
                folderBased = false, isBook = true, isPrimary = false,
                downloadEligible = true,
            }}, files)
        end)

        it("marks physical and audiobook-only records ineligible", function()
            local physical = GrimmoryApi.normalizeBook({
                id = 10,
                metadata = { title = "On paper" },
                isPhysical = true,
                alternativeFormats = {},
                supplementaryFiles = {},
            })
            assert.is_false(physical.downloadEligible)

            local audio = GrimmoryApi.normalizeBook({
                id = 11,
                primaryFile = {
                    id = 1101,
                    bookId = 11,
                    fileName = "audio.m4b",
                    bookType = "AUDIOBOOK",
                    book = true,
                },
                metadata = { title = "Audio" },
            })
            assert.is_false(audio.downloadEligible)
        end)
    end)

    describe("getRecommendations (similar books)", function()
        it("fetches /books/{id}/recommendations and parses the list", function()
            fixture = spec_helper.start_http_fixture({
                {
                    method = "GET",
                    path = "/api/v1/books/1/recommendations",
                    status = 200,
                    headers = { ["Content-Type"] = "application/json" },
                    body_file = "recommendations.json",
                    expect_headers = { Authorization = "Bearer test-token" },
                },
            })
            local data, err = GrimmoryApi:getRecommendations(fixture.base_url(), "test-token", 1)
            assert.is_nil(err, tostring(err))
            assert.is_table(data)
            assert.is_table(data[1])
            assert.is_table(data[1].book)
            assert.equals("similar_book_two.epub", data[1].book.fileName)
            assert.equals(512, data[1].book.fileSizeKb)
        end)
    end)

    describe("progress GET", function()
        it("parses native cfi, percentage, href, and lastReadTime fields", function()
            fixture = spec_helper.start_http_fixture({
                {
                    method = "GET",
                    path = "/api/v1/books/42",
                    status = 200,
                    headers = { ["Content-Type"] = "application/json" },
                    body_file = "progress_get.json",
                },
            })
            local data, err = GrimmoryApi:get(fixture.base_url() .. "/api/v1/books/42", "test-token")
            assert.is_nil(err, tostring(err))
            assert.is_table(data)
            local prog = data.epubProgress
            assert.same({
                cfi = "epubcfi(/6/2[chapter1]!/4/2/6:21)",
                href = "OEBPS/chapter1.xhtml",
                percentage = 34.5,
            }, prog)
            assert.equals(42, data.id)
            assert.equals("2026-04-26T20:00:00Z", data.lastReadTime)
        end)
    end)

    describe("book metadata", function()
        it("round-trips book metadata fields", function()
            fixture = spec_helper.start_http_fixture({
                {
                    method = "GET",
                    path = "/api/v1/books/1",
                    status = 200,
                    headers = { ["Content-Type"] = "application/json" },
                    body_file = "book_metadata.json",
                },
            })
            local data, err = GrimmoryApi:get(fixture.base_url() .. "/api/v1/books/1", "test-token")
            assert.is_nil(err, tostring(err))
            assert.equals(1, data.id)
            assert.equals("Test Book One", data.title)
            assert.same({ "Author A" }, data.metadata.authors)
            assert.equals("Test Publisher", data.metadata.publisher)
            assert.equals("2024-01-01", data.metadata.publishedDate)
        end)
    end)

    describe("downloadBook", function()
        it("streams binary body to disk and file matches expected bytes", function()
            fixture = spec_helper.start_http_fixture({
                {
                    method = "GET",
                    path = "/api/v1/books/7/download",
                    status = 200,
                    headers = {
                        ["Content-Type"] = "application/epub+zip",
                    },
                    expect_headers = { Authorization = "Bearer test-token" },
                    body_file = "download_book.bin",
                    repeat_ = 1,
                },
            })

            local tmpdir = os.getenv("TMPDIR") or "/tmp"
            local dest = tmpdir .. "/grimmory_dl_" .. tostring(os.time()) ..
                         "_" .. tostring(math.random(99999)) .. ".epub"
            local ok, err = GrimmoryApi:downloadBook(fixture.base_url(), 7, "test-token", dest, nil)
            assert.is_truthy(ok, tostring(err))

            -- Verify on-disk file matches the canned binary blob.
            local canned_path = REPO_ROOT .. "/tests/support/canned_responses/download_book.bin"
            local f1 = io.open(dest, "rb")
            local f2 = io.open(canned_path, "rb")
            assert.is_truthy(f1, "dest file not readable")
            assert.is_truthy(f2, "canned file not readable")
            local got = f1:read("*a")
            local expected = f2:read("*a")
            f1:close()
            f2:close()
            os.remove(dest)
            assert.equals(expected, got)
        end)

        it("downloads an exact alternative file ID with Bearer auth", function()
            fixture = spec_helper.start_http_fixture({{
                method = "GET",
                path = "/api/v1/books/7/files/701/download",
                status = 200,
                headers = { ["Content-Type"] = "application/pdf" },
                expect_headers = { Authorization = "Bearer file-token" },
                body_file = "download_book.bin",
                repeat_ = 1,
            }})
            local tmpdir = os.getenv("TMPDIR") or "/tmp"
            local dest = tmpdir .. "/grimmory_file_dl_" .. tostring(os.time()) ..
                "_" .. tostring(math.random(99999)) .. ".pdf"
            local ok, err = GrimmoryApi:downloadBookFile(
                fixture.base_url(), 7, 701, "file-token", dest, nil)
            assert.is_truthy(ok, tostring(err))
            local f = assert(io.open(dest, "rb"))
            local got = f:read("*a")
            f:close()
            local canned = assert(io.open(
                REPO_ROOT .. "/tests/support/canned_responses/download_book.bin", "rb"))
            local expected = canned:read("*a")
            canned:close()
            os.remove(dest)
            assert.equals(expected, got)
        end)
    end)

    describe("findCachedCover (offline cover probe)", function()
        local lfs = require("lfs")
        local cache_dir

        before_each(function()
            local base = os.getenv("TMPDIR") or "/tmp"
            cache_dir = base .. "/grimmory_covers_" .. tostring(os.time()) ..
                        "_" .. tostring(math.random(99999))
            lfs.mkdir(cache_dir)
        end)

        after_each(function()
            for entry in lfs.dir(cache_dir) do
                if entry ~= "." and entry ~= ".." then
                    os.remove(cache_dir .. "/" .. entry)
                end
            end
            lfs.rmdir(cache_dir)
        end)

        it("returns nil when no cover is cached", function()
            assert.is_nil((GrimmoryApi:findCachedCover(7, "2024-01-01", cache_dir)))
        end)

        it("agrees with downloadCover on the filename scheme", function()
            -- Regression lock: offline mode resolves covers through this probe,
            -- so it must find the exact file downloadCover writes. GIF magic is
            -- ASCII ("GIF8"), so the body survives the fixture's JSON transport
            -- (jpg/png magic bytes would not) and is sniffed/stored as .gif.
            fixture = spec_helper.start_http_fixture({
                {
                    method = "GET",
                    path = "/api/v1/media/book/7/thumbnail",
                    status = 200,
                    headers = { ["Content-Type"] = "image/gif" },
                    body = "GIF89a-fake-gif-bytes",
                    expect_query = { token = "test-token" },
                    repeat_ = 1,
                },
            })
            local dl_path, err = GrimmoryApi:downloadCover(
                fixture.base_url(), 7, "2024-01-01T00:00:00Z", "test-token", cache_dir)
            assert.is_truthy(dl_path, tostring(err))

            local cached = GrimmoryApi:findCachedCover(7, "2024-01-01T00:00:00Z", cache_dir)
            assert.equals(dl_path, cached,
                "offline probe must resolve the exact file downloadCover wrote")
        end)

        it("does not match a cover cached under a different coverUpdatedOn stamp", function()
            local f = assert(io.open(cache_dir .. "/cover_7_old.jpg", "wb"))
            f:write("\xFF\xD8")
            f:close()
            assert.is_nil((GrimmoryApi:findCachedCover(7, "new", cache_dir)))
        end)
    end)

    describe("HTTP redirect handling", function()
        it("returns a typed error for 302 responses (socket.http does not follow redirects)", function()
            -- api.lua:get() does not follow redirects; 302 is treated as a non-200 error.
            fixture = spec_helper.start_http_fixture({
                {
                    method = "GET",
                    path = "/redirect/start",
                    status = 302,
                    headers = { ["Location"] = "/redirect/middle" },
                    body = "{}",
                    repeat_ = 1,
                },
            })
            local data, err = GrimmoryApi:get(fixture.url("/redirect/start"), "test-token")
            assert.is_nil(data)
            assert.is_string(err)
            assert.truthy(err:match("302"), "error should mention 302, got: " .. tostring(err))
        end)
    end)
end)
