--[[
  API client spec for booklore.koplugin/api.lua.

  Each scenario starts a local http_fixture and tears it down after_each
  so port assignment and request log are isolated between tests.
]]
local spec_helper = require("spec_helper")

local BookLoreApi
local fixture

describe("BookLoreApi", function()
    before_each(function()
        spec_helper.setup()
        BookLoreApi = require("api")
    end)

    after_each(function()
        if fixture then
            fixture.stop()
            fixture = nil
        end
        spec_helper.teardown()
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
                    repeat_ = 1,
                },
            })
            local token, refresh, err = BookLoreApi:login(fixture.base_url(), "user", "pass")
            assert.is_nil(err, tostring(err))
            assert.is_string(token)
            assert.is_string(refresh)
            assert.truthy(token:match("^eyJ"))  -- JWT prefix
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
            local token, refresh, err = BookLoreApi:login(fixture.base_url(), "user", "wrong")
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
                    repeat_ = 1,
                },
            })
            local token, refresh, err = BookLoreApi:refreshToken(fixture.base_url(), "old-refresh-token")
            assert.is_nil(err, tostring(err))
            assert.is_string(token)
            assert.is_string(refresh)
        end)
    end)

    describe("getBooks (paginated)", function()
        it("parses content array and pagination metadata", function()
            fixture = spec_helper.start_http_fixture({
                {
                    method = "GET",
                    path = "/api/v1/books",
                    status = 200,
                    headers = { ["Content-Type"] = "application/json" },
                    body_file = "library_books_page1.json",
                },
            })
            local data, err = BookLoreApi:getBooks(fixture.base_url(), "test-token")
            assert.is_nil(err, tostring(err))
            assert.is_table(data)
            assert.is_table(data.content)
            assert.is_number(data.totalPages)
            assert.is_number(data.number)
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
                },
            })
            -- Arg order is (server_url, token, book_id) to match "token-second".
            local data, err = BookLoreApi:getBook(fixture.base_url(), "test-token", 1)
            assert.is_nil(err, tostring(err))
            assert.is_table(data)
            assert.equals(1, data.id)
            assert.is_table(data.metadata)
        end)
    end)

    describe("progress GET", function()
        it("parses cfi, percentage, lastReadAt fields", function()
            fixture = spec_helper.start_http_fixture({
                {
                    method = "GET",
                    path = "/api/v1/books/42",
                    status = 200,
                    headers = { ["Content-Type"] = "application/json" },
                    body_file = "progress_get.json",
                },
            })
            local data, err = BookLoreApi:get(fixture.base_url() .. "/api/v1/books/42", "test-token")
            assert.is_nil(err, tostring(err))
            assert.is_table(data)
            local prog = data.epubProgress
            assert.is_table(prog)
            assert.is_string(prog.cfi)
            assert.is_number(prog.percentage)
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
            local data, err = BookLoreApi:get(fixture.base_url() .. "/api/v1/books/1", "test-token")
            assert.is_nil(err, tostring(err))
            assert.is_table(data)
            assert.is_number(data.id)
            assert.is_string(data.title)
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
                    body_file = "download_book.bin",
                    repeat_ = 1,
                },
            })

            local tmpdir = os.getenv("TMPDIR") or "/tmp"
            local dest = tmpdir .. "/booklore_dl_" .. tostring(os.time()) ..
                         "_" .. tostring(math.random(99999)) .. ".epub"
            local ok, err = BookLoreApi:downloadBook(fixture.base_url(), 7, "test-token", dest, nil)
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
            local data, err = BookLoreApi:get(fixture.url("/redirect/start"), "test-token")
            assert.is_nil(data)
            assert.is_string(err)
            assert.truthy(err:match("302"), "error should mention 302, got: " .. tostring(err))
        end)
    end)
end)
