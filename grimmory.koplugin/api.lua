--[[
    Grimmory API client module.
    Handles authentication and REST API requests to a Grimmory server.
]]--

local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local socket = require("socket")

local GrimmoryApi = {}

local BOOK_PAGE_SIZE = 100
local KOREADER_BOOK_TYPES = {
    EPUB = true,
    PDF = true,
    CBX = true,
    FB2 = true,
    MOBI = true,
    AZW3 = true,
}

-- Per-socket-operation bound (connect, each read). Without this every
-- request inherits luasocket's 60s default, and an unreachable host (an
-- asleep tailnet peer drops packets rather than refusing) hangs for the
-- full minute. 10s is generous for a healthy LAN/tailnet hop yet lets a
-- dead-server subprocess give up promptly. Transfer DURATION is
-- deliberately unbounded: each read just has to make progress within the
-- window, and callers run requests in an async.lua subprocess, so a long
-- transfer never touches the UI thread.
local SOCKET_TIMEOUT_SECS = 10

local function timedTCP()
    local s = socket.tcp()
    s:settimeout(SOCKET_TIMEOUT_SECS)
    return s
end

local function redactToken(url)
    return (url:gsub("token=[^&]+", "token=REDACTED"))
end

--- Recursively create directories using LuaFileSystem.
-- Safe alternative to os.execute("mkdir -p ...") — no shell injection risk.
-- @param path string: directory path to create
local function mkdirs(path)
    path = path:gsub("\\", "/")
    local current = ""
    for segment in path:gmatch("[^/]+") do
        current = current .. "/" .. segment
        local attr = lfs.attributes(current)
        if not attr then
            lfs.mkdir(current)
        end
    end
end

--- Normalize a user-entered server URL: trim whitespace, prepend http:// when
-- no scheme is given, and drop any trailing slash. Returns "" for blank input
-- so callers can reject it before firing a doomed request. Pure (no IO), so it
-- is unit-testable and safe to call on the UI thread.
-- @param s string|nil: raw user input
-- @return string: normalized URL, or "" if blank
function GrimmoryApi.normalizeServerUrl(s)
    s = tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return "" end
    if not s:match("^%w[%w%+%.%-]*://") then
        s = "http://" .. s
    end
    return (s:gsub("/+$", ""))
end

--- Normalize Grimmory's current Book DTO into the flat convenience fields
-- consumed by the KOReader UI. Since Grimmory v3, file-specific properties
-- live under primaryFile while cover versioning lives under metadata.
-- Mutating the decoded table keeps cached snapshots and recommendation books
-- on the same shape as top-level library results.
function GrimmoryApi.normalizeBookFile(file, defaults)
    if type(file) ~= "table" then return file end
    defaults = defaults or {}

    -- Jackson serializes Java's `isBook` bean property as `book` in the
    -- current OpenAPI shape. Accept both spellings so older snapshots remain
    -- usable, but expose one canonical field to the rest of the plugin.
    if file.isBook == nil then file.isBook = file.book end
    if file.isBook == nil then file.isBook = defaults.isBook end
    if file.bookId == nil then file.bookId = defaults.bookId end
    if file.isPrimary == nil then file.isPrimary = defaults.isPrimary == true end

    if file.extension == nil and type(file.fileName) == "string" then
        file.extension = file.fileName:match("%.([^%.]+)$")
    end
    if type(file.extension) == "string" then
        file.extension = file.extension:lower()
    end

    file.downloadEligible = file.isBook ~= false
        and type(file.fileName) == "string"
        and file.fileName ~= ""
        and KOREADER_BOOK_TYPES[tostring(file.bookType or ""):upper()] == true
        and (file.isPrimary or file.id ~= nil)

    return file
end

function GrimmoryApi.isDownloadEligible(file)
    return type(file) == "table" and file.downloadEligible == true
end

function GrimmoryApi.normalizeBook(book)
    if type(book) ~= "table" then return book end

    local primary = type(book.primaryFile) == "table"
        and GrimmoryApi.normalizeBookFile(book.primaryFile, {
            bookId = book.id,
            isBook = true,
            isPrimary = true,
        }) or {}
    if not next(primary) and type(book.fileName) == "string" then
        primary = GrimmoryApi.normalizeBookFile({
            bookId = book.id,
            fileName = book.fileName,
            fileSizeKb = book.fileSizeKb,
            bookType = book.bookType,
        }, {
            bookId = book.id,
            isBook = true,
            isPrimary = true,
        })
    end
    local metadata = type(book.metadata) == "table" and book.metadata or {}

    book.primaryFile = next(primary) and primary or nil

    local alternatives = type(book.alternativeFormats) == "table"
        and book.alternativeFormats or {}
    for i, file in ipairs(alternatives) do
        alternatives[i] = GrimmoryApi.normalizeBookFile(file, {
            bookId = book.id,
            isBook = true,
            isPrimary = false,
        })
    end
    book.alternativeFormats = alternatives

    local supplementary = type(book.supplementaryFiles) == "table"
        and book.supplementaryFiles or {}
    for i, file in ipairs(supplementary) do
        supplementary[i] = GrimmoryApi.normalizeBookFile(file, {
            bookId = book.id,
            isBook = false,
            isPrimary = false,
        })
    end
    book.supplementaryFiles = supplementary

    -- The flattened fields are a compatibility surface for the existing UI,
    -- while primaryFile/alternativeFormats retain Grimmory's native identity.
    -- Always refresh them from canonical fields when present so a merged book
    -- detail cannot leave stale list-view values behind.
    if primary.fileName ~= nil then book.fileName = primary.fileName end
    if primary.fileSizeKb ~= nil then book.fileSizeKb = primary.fileSizeKb end
    if primary.bookType ~= nil then book.bookType = primary.bookType end
    if book.lastReadTime == nil then book.lastReadTime = book.lastReadAt end
    if book.addedOn == nil then book.addedOn = book.createdAt end
    if book.locked == nil then book.locked = metadata.allMetadataLocked end

    if book.coverUpdatedOn == nil then
        book.coverUpdatedOn = metadata.coverUpdatedOn
    end
    if book.title == nil then
        book.title = metadata.title or primary.fileName
    end

    book.bookFiles = {}
    book.downloadFiles = {}
    if next(primary) then
        table.insert(book.bookFiles, primary)
        if primary.downloadEligible then table.insert(book.downloadFiles, primary) end
    end
    for _, file in ipairs(alternatives) do
        table.insert(book.bookFiles, file)
        if file.downloadEligible then table.insert(book.downloadFiles, file) end
    end
    book.downloadEligible = #book.downloadFiles > 0

    return book
end

local function normalizeBookList(data)
    if type(data) ~= "table" then return data end
    local books = type(data.content) == "table" and data.content or data
    for i, book in ipairs(books) do
        books[i] = GrimmoryApi.normalizeBook(book)
    end
    return books
end

local function httpStatus(err)
    if type(err) ~= "string" then return nil end
    return tonumber(err:match("^HTTP (%d%d%d)"))
end

local function paginationMetadata(data)
    if type(data) ~= "table" then return nil end
    if type(data.page) == "table" then return data.page end
    if data.totalPages ~= nil or data.number ~= nil then return data end
    return nil
end

local function pagedUrl(server_url, endpoint, page)
    return server_url .. endpoint .. "?page=" .. tostring(page)
        .. "&size=" .. tostring(BOOK_PAGE_SIZE)
end

local function collectPagedBooks(api, server_url, token, endpoint, first)
    if type(first) ~= "table" or type(first.content) ~= "table" then
        return nil, "invalid paginated books response"
    end
    local meta = paginationMetadata(first)
    local total_pages = meta and tonumber(meta.totalPages)
    local first_number = meta and tonumber(meta.number) or 0
    if not total_pages then
        return nil, "paginated books response omitted totalPages; refusing partial library"
    end

    local books = normalizeBookList(first)
    for page = first_number + 1, total_pages - 1 do
        local data, err = api:get(pagedUrl(server_url, endpoint, page), token)
        if not data then return nil, err end
        if type(data) ~= "table" or type(data.content) ~= "table" then
            return nil, "invalid books page " .. tostring(page)
        end
        local page_meta = paginationMetadata(data)
        if page_meta and tonumber(page_meta.number)
                and tonumber(page_meta.number) ~= page then
            return nil, "books page number mismatch: expected " .. tostring(page)
        end
        local page_books = normalizeBookList(data)
        for _, book in ipairs(page_books) do table.insert(books, book) end
    end
    return books, nil
end

--- Perform a POST request with a JSON body.
-- @param url string: full URL
-- @param body table: request body (will be JSON-encoded)
-- @param token string|nil: optional JWT for Authorization header
-- @return table|nil: decoded JSON response, or nil on error
-- @return string|nil: error message, or nil on success
function GrimmoryApi:post(url, body, token)
    local request_body = json.encode(body)
    local response_body = {}

    local headers = {
        ["Content-Type"] = "application/json",
        ["Content-Length"] = tostring(#request_body),
    }
    if token then
        headers["Authorization"] = "Bearer " .. token
    end

    local _, code, response_headers = http.request{
        url = url,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(request_body),
        sink = ltn12.sink.table(response_body),
        redirect = false,
        create = timedTCP,
    }

    local raw = table.concat(response_body)
    logger.dbg("Grimmory POST", redactToken(url), "→", code)
    logger.dbg("Grimmory response body:", raw)

    if code ~= 200 then
        return nil, "HTTP " .. tostring(code) .. ": " .. raw
    end

    local ok, decoded = pcall(json.decode, raw)
    if not ok then
        return nil, "JSON decode failed: " .. tostring(decoded)
    end

    return decoded, nil
end

--- Perform a GET request.
-- @param url string: full URL
-- @param token string|nil: optional JWT for Authorization header
-- @return table|nil: decoded JSON response, or nil on error
-- @return string|nil: error message, or nil on success
function GrimmoryApi:get(url, token)
    local response_body = {}

    local headers = {}
    if token then
        headers["Authorization"] = "Bearer " .. token
    end

    local _, code, response_headers = http.request{
        url = url,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.table(response_body),
        redirect = false,
        create = timedTCP,
    }

    local raw = table.concat(response_body)
    logger.dbg("Grimmory GET", redactToken(url), "→", code)
    logger.dbg("Grimmory response body:", raw)

    if code ~= 200 then
        return nil, "HTTP " .. tostring(code) .. ": " .. raw
    end

    local ok, decoded = pcall(json.decode, raw)
    if not ok then
        return nil, "JSON decode failed: " .. tostring(decoded)
    end

    return decoded, nil
end

--- Authenticate with Grimmory and obtain access + refresh tokens. (ref: DL-007)
-- @param server_url string: base URL, e.g. "http://192.168.1.144:6060"
-- @param username string
-- @param password string
-- @return string|nil: access token, or nil on error
-- @return string|nil: refresh token, or nil on error
-- @return string|nil: error message, or nil on success
function GrimmoryApi:login(server_url, username, password)
    local url = server_url .. "/api/v1/auth/login"
    local data, err = self:post(url, {
        username = username,
        password = password,
    })

    if not data then
        return nil, nil, err
    end

    local token = data.accessToken
    if not token then
        local keys = {}
        for k, _ in pairs(data) do
            table.insert(keys, k)
        end
        return nil, nil, "No accessToken in response. Keys: " .. table.concat(keys, ", ")
    end

    local refresh_token = data.refreshToken
    if not refresh_token then
        local keys = {}
        for k, _ in pairs(data) do
            table.insert(keys, k)
        end
        return nil, nil, "No refreshToken in response. Keys: " .. table.concat(keys, ", ")
    end

    return token, refresh_token, nil
end

--- Exchange a refresh token for a new access+refresh pair. (ref: DL-005, DL-007)
-- Endpoint shape is an M-confidence assumption: POST /api/v1/auth/refresh
-- with JSON body {refreshToken}; response mirrors login (rotating refresh).
function GrimmoryApi:refreshToken(server_url, refresh_token)
    local url = server_url .. "/api/v1/auth/refresh"
    local data, err = self:post(url, {
        refreshToken = refresh_token,
    })

    if not data then
        return nil, nil, err
    end

    local new_access = data.accessToken
    if not new_access then
        local keys = {}
        for k, _ in pairs(data) do table.insert(keys, k) end
        return nil, nil, "No accessToken in refresh response. Keys: " .. table.concat(keys, ", ")
    end

    local new_refresh = data.refreshToken
    if not new_refresh then
        local keys = {}
        for k, _ in pairs(data) do table.insert(keys, k) end
        return nil, nil, "No refreshToken in refresh response. Keys: " .. table.concat(keys, ", ")
    end

    return new_access, new_refresh, nil
end

--- Fetch the list of libraries. (ref: DL-001)
function GrimmoryApi:getLibraries(server_url, token)
    local url = server_url .. "/api/v1/libraries"
    return self:get(url, token)
end

--- Fetch all shelves. (ref: DL-001)
function GrimmoryApi:getShelves(server_url, token)
    local url = server_url .. "/api/v1/shelves"
    return self:get(url, token)
end

--- Discover the Grimmory server version and the native API surfaces that
-- accompany it. The version controller is absent on BookLore-era servers;
-- 404/405 is therefore a supported result rather than a failed library load.
function GrimmoryApi:getVersion(server_url, token)
    local data, err = self:get(server_url .. "/api/v1/version", token)
    if not data then
        local status = httpStatus(err)
        if status == 404 or status == 405 then
            return {
                available = false,
                current = nil,
                latest = nil,
                capabilities = {
                    version = false,
                    paginatedBooks = false,
                    bookFiles = false,
                    multiFormat = false,
                    physicalBooks = false,
                },
            }, nil
        end
        return nil, err
    end

    local current = data.current or data.version
    local major = tonumber(tostring(current or ""):match("^v?(%d+)"))
    local native_v3 = major ~= nil and major >= 3
    return {
        available = true,
        current = current,
        latest = data.latest,
        capabilities = {
            version = true,
            paginatedBooks = native_v3,
            bookFiles = native_v3,
            multiFormat = native_v3,
            physicalBooks = native_v3,
        },
    }, nil
end

--- Fetch every accessible book without ever treating one page as the full
-- library. Grimmory v3's native page endpoint is preferred. BookLore-era
-- servers that do not expose it fall back to the current raw-list endpoint.
-- A paginated fallback response without totalPages is rejected explicitly.
function GrimmoryApi:getBooks(server_url, token)
    local page_endpoint = "/api/v1/books/page"
    local data, err = self:get(pagedUrl(server_url, page_endpoint, 0), token)
    if data then
        return collectPagedBooks(self, server_url, token, page_endpoint, data)
    end

    local status = httpStatus(err)
    if status ~= 404 and status ~= 405 then return nil, err end

    local raw_endpoint = "/api/v1/books"
    local raw_url = server_url .. raw_endpoint
        .. "?withDescription=false&stripForListView=true"
    local raw, raw_err = self:get(raw_url, token)
    if not raw then return nil, raw_err end
    if type(raw) == "table" and type(raw.content) == "table" then
        -- Some older servers paginate `/books` itself. Continue on that same
        -- endpoint with explicit page/size rather than unwrapping page one.
        return collectPagedBooks(self, server_url, token, raw_endpoint, raw)
    end
    if type(raw) ~= "table" then return nil, "invalid books response" end
    return normalizeBookList(raw), nil
end

--- Fetch a single book with full metadata.
-- The list endpoint (getBooks) omits description unless withDescription=true,
-- so the detail page fetches the individual record to get the blurb (and any
-- other heavy fields the list view drops). Arg order matches "token-second".
function GrimmoryApi:getBook(server_url, token, book_id)
    local url = server_url .. "/api/v1/books/" .. tostring(book_id)
        .. "?withDescription=true"
    local data, err = self:get(url, token)
    if not data then return nil, err end
    return self.normalizeBook(data), nil
end

--- List every reader-format file attached to a book. `isBook=true` is
-- required by Grimmory's overloaded files endpoint and excludes covers and
-- other supplementary assets.
function GrimmoryApi:getBookFiles(server_url, token, book_id)
    local url = server_url .. "/api/v1/books/" .. tostring(book_id)
        .. "/files?isBook=true"
    local data, err = self:get(url, token)
    if not data then return nil, err end
    if type(data) ~= "table" then return nil, "invalid book files response" end
    for i, file in ipairs(data) do
        data[i] = self.normalizeBookFile(file, {
            bookId = book_id,
            isBook = true,
            isPrimary = false,
        })
    end
    return data, nil
end

--- Fetch recommended ("Similar Books") for a book.
-- Returns a list of { book = <Book>, similarityScore = <number> }.
-- Arg order matches "token-second".
function GrimmoryApi:getRecommendations(server_url, token, book_id)
    local url = server_url .. "/api/v1/books/" .. tostring(book_id)
        .. "/recommendations"
    local data, err = self:get(url, token)
    if not data then return nil, err end
    for _, recommendation in ipairs(data) do
        if type(recommendation) == "table" then
            recommendation.book = self.normalizeBook(recommendation.book)
        end
    end
    return data, nil
end

--- Probe the cover cache for an already-downloaded cover. No network, no auth.
-- Owns the cover filename scheme (cover_<id>_<stamp>.<ext>): downloadCover's
-- cache-hit fast path and the offline-mode render path both resolve through
-- here, so the scheme lives in exactly one place.
-- Returns the cached path or nil, plus the basename a cover for these
-- arguments is stored under (used by downloadCover after a fetch).
function GrimmoryApi:findCachedCover(book_id, cover_updated_on, cache_dir)
    local stamp = tostring(cover_updated_on or "0"):gsub("[^%w]", "")
    local basename = "cover_" .. tostring(book_id) .. "_" .. stamp
    for _, ext in ipairs({ "jpg", "png", "gif", "webp" }) do
        local path = cache_dir .. "/" .. basename .. "." .. ext
        if lfs.attributes(path, "mode") == "file" then
            return path, basename
        end
    end
    return nil, basename
end

--- Download a book's cover thumbnail to a file.
-- Media endpoints use ?token= query param, NOT the Authorization header.
-- Note: Grimmory may return Content-Type: application/json despite
-- serving image data — this is a known server bug. Treat as binary.
function GrimmoryApi:downloadCover(server_url, book_id, cover_updated_on, token, cache_dir)
    local cached, basename = self:findCachedCover(book_id, cover_updated_on, cache_dir)
    if cached then return cached, nil end

    local url = server_url .. "/api/v1/media/book/" .. tostring(book_id)
        .. "/thumbnail?token=" .. token

    local tmp_path = cache_dir .. "/cover_" .. tostring(book_id) .. ".tmp"
    local f, open_err = io.open(tmp_path, "wb")
    if not f then
        return nil, "Cannot write: " .. tostring(open_err)
    end

    local _, code = http.request{
        url = url,
        sink = ltn12.sink.file(f),
        redirect = false,
        create = timedTCP,
    }

    if code ~= 200 then
        os.remove(tmp_path)
        return nil, "HTTP " .. tostring(code)
    end

    local check = io.open(tmp_path, "rb")
    if not check then
        os.remove(tmp_path)
        return nil, "Cannot reopen temp file"
    end

    local header = check:read(12)
    local size = check:seek("end")
    check:close()

    if not header or not size or size == 0 then
        os.remove(tmp_path)
        return nil, "Empty response"
    end

    local ext = nil
    if header:sub(1, 2) == "\xFF\xD8" then
        ext = "jpg"
    elseif header:sub(1, 4) == "\x89PNG" then
        ext = "png"
    elseif header:sub(1, 4) == "GIF8" then
        ext = "gif"
    elseif header:sub(1, 4) == "RIFF" and header:sub(9, 12) == "WEBP" then
        ext = "webp"
    end

    if not ext then
        local hex = {}
        for i = 1, math.min(#header, 8) do
            table.insert(hex, string.format("%02X", header:byte(i)))
        end
        os.remove(tmp_path)
        return nil, "Unknown image format. Header: " .. table.concat(hex, " ")
    end

    local final_path = cache_dir .. "/" .. basename .. "." .. ext
    os.remove(final_path)
    os.rename(tmp_path, final_path)

    return final_path, nil
end

--- Download a book file to a local path.
-- Uses the /api/v1/books/{id}/download endpoint with Bearer auth.
-- Streams directly to disk via ltn12 sink.
-- @param server_url string: base URL
-- @param book_id number: book ID
-- @param token string: JWT
-- @param dest_path string: full destination file path
-- @param expected_size_kb number|nil: expected size from API for truncation check
-- @return boolean: true on success
-- @return string|nil: error or warning message
function GrimmoryApi:downloadBook(server_url, book_id, token, dest_path,
        expected_size_kb, exact_file_id)
    local url
    if exact_file_id ~= nil then
        url = server_url .. "/api/v1/books/" .. tostring(book_id)
            .. "/files/" .. tostring(exact_file_id) .. "/download"
    else
        url = server_url .. "/api/v1/books/" .. tostring(book_id) .. "/download"
    end

    -- Ensure parent directory exists (safe, no shell)
    local dir = dest_path:match("(.+)/[^/]+$")
    if dir then
        mkdirs(dir)
    end

    local f, open_err = io.open(dest_path, "wb")
    if not f then
        return false, "Cannot open for writing: " .. tostring(open_err)
    end

    logger.dbg("Grimmory: downloading book", book_id, "to", dest_path)

    local _, code = http.request{
        url = url,
        method = "GET",
        headers = {
            ["Authorization"] = "Bearer " .. token,
        },
        sink = ltn12.sink.file(f),
        redirect = false,
        create = timedTCP,
    }

    if code ~= 200 then
        os.remove(dest_path)
        return false, "HTTP " .. tostring(code)
    end

    -- Verify file was written
    local attr = lfs.attributes(dest_path)
    if not attr then
        return false, "File not found after download"
    end
    local actual_size = attr.size

    if not actual_size or actual_size == 0 then
        os.remove(dest_path)
        return false, "Downloaded file is empty"
    end

    -- Truncation check against server-reported size.
    -- fileSizeKb is rounded, so allow 10% tolerance.
    if expected_size_kb and expected_size_kb > 0 then
        local expected_bytes = expected_size_kb * 1024
        if actual_size < expected_bytes * 0.90 then
            logger.warn("Grimmory: download may be truncated.",
                "Expected ~" .. tostring(expected_size_kb) .. "KB,",
                "got " .. tostring(math.floor(actual_size / 1024)) .. "KB")
        end
    end

    logger.info("Grimmory: downloaded book", book_id, "→", dest_path,
        string.format("(%.1f KB)", actual_size / 1024))

    return true, nil
end

--- Download one exact alternative book format using Grimmory's Book Files
-- endpoint. `file_id` is mandatory so a duplicate name/type cannot select the
-- wrong binary.
function GrimmoryApi:downloadBookFile(server_url, book_id, file_id, token,
        dest_path, expected_size_kb)
    if file_id == nil then return false, "book file id is required" end
    return self:downloadBook(server_url, book_id, token, dest_path,
        expected_size_kb, file_id)
end

return GrimmoryApi
