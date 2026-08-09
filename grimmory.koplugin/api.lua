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
function GrimmoryApi.normalizeBook(book)
    if type(book) ~= "table" then return book end

    local primary = type(book.primaryFile) == "table" and book.primaryFile or {}
    local metadata = type(book.metadata) == "table" and book.metadata or {}

    if book.fileName == nil then book.fileName = primary.fileName end
    if book.fileSizeKb == nil then book.fileSizeKb = primary.fileSizeKb end
    if book.bookType == nil then book.bookType = primary.bookType end
    if book.coverUpdatedOn == nil then
        book.coverUpdatedOn = metadata.coverUpdatedOn
    end
    if book.title == nil then
        book.title = metadata.title or primary.fileName
    end

    return book
end

local function normalizeBookList(data)
    if type(data) ~= "table" then return data end
    local books = type(data.content) == "table" and data.content or data
    for i, book in ipairs(books) do
        books[i] = GrimmoryApi.normalizeBook(book)
    end
    return data
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

--- Fetch all books.
function GrimmoryApi:getBooks(server_url, token)
    local url = server_url .. "/api/v1/books"
    local data, err = self:get(url, token)
    if not data then return nil, err end
    return normalizeBookList(data), nil
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
function GrimmoryApi:downloadBook(server_url, book_id, token, dest_path, expected_size_kb)
    local url = server_url .. "/api/v1/books/" .. tostring(book_id) .. "/download"

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

return GrimmoryApi
