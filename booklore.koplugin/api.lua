--[[
    BookLore API client module.
    Handles authentication and REST API requests to a BookLore server.
]]--

local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

local BookLoreApi = {}

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

--- Perform a POST request with a JSON body.
-- @param url string: full URL
-- @param body table: request body (will be JSON-encoded)
-- @param token string|nil: optional JWT for Authorization header
-- @return table|nil: decoded JSON response, or nil on error
-- @return string|nil: error message, or nil on success
function BookLoreApi:post(url, body, token)
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
    }

    local raw = table.concat(response_body)
    logger.dbg("BookLore POST", redactToken(url), "→", code)
    logger.dbg("BookLore response body:", raw)

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
function BookLoreApi:get(url, token)
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
    }

    local raw = table.concat(response_body)
    logger.dbg("BookLore GET", redactToken(url), "→", code)
    logger.dbg("BookLore response body:", raw)

    if code ~= 200 then
        return nil, "HTTP " .. tostring(code) .. ": " .. raw
    end

    local ok, decoded = pcall(json.decode, raw)
    if not ok then
        return nil, "JSON decode failed: " .. tostring(decoded)
    end

    return decoded, nil
end

--- Authenticate with BookLore and obtain a JWT.
-- @param server_url string: base URL, e.g. "http://192.168.1.144:6060"
-- @param username string
-- @param password string
-- @return string|nil: JWT token, or nil on error
-- @return string|nil: error message, or nil on success
function BookLoreApi:login(server_url, username, password)
    local url = server_url .. "/api/v1/auth/login"
    local data, err = self:post(url, {
        username = username,
        password = password,
    })

    if not data then
        return nil, err
    end

    local token = data.accessToken
    if not token then
        local keys = {}
        for k, _ in pairs(data) do
            table.insert(keys, k)
        end
        return nil, "No accessToken in response. Keys: " .. table.concat(keys, ", ")
    end

    return token, nil
end

--- Fetch the list of libraries.
function BookLoreApi:getLibraries(server_url, token)
    local url = server_url .. "/api/v1/libraries"
    return self:get(url, token)
end

--- Fetch all books.
function BookLoreApi:getBooks(server_url, token)
    local url = server_url .. "/api/v1/books"
    return self:get(url, token)
end

--- Download a book's cover thumbnail to a file.
-- Media endpoints use ?token= query param, NOT the Authorization header.
-- Note: BookLore may return Content-Type: application/json despite
-- serving image data — this is a known server bug. Treat as binary.
function BookLoreApi:downloadCover(server_url, book_id, cover_updated_on, token, cache_dir)
    local stamp = tostring(cover_updated_on or "0"):gsub("[^%w]", "")
    local basename = "cover_" .. tostring(book_id) .. "_" .. stamp
    for _, ext in ipairs({ "jpg", "png", "gif", "webp" }) do
        if lfs.attributes(cache_dir .. "/" .. basename .. "." .. ext, "mode") == "file" then
            return cache_dir .. "/" .. basename .. "." .. ext, nil
        end
    end

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
function BookLoreApi:downloadBook(server_url, book_id, token, dest_path, expected_size_kb)
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

    logger.dbg("BookLore: downloading book", book_id, "to", dest_path)

    local _, code = http.request{
        url = url,
        method = "GET",
        headers = {
            ["Authorization"] = "Bearer " .. token,
        },
        sink = ltn12.sink.file(f),
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
            logger.warn("BookLore: download may be truncated.",
                "Expected ~" .. tostring(expected_size_kb) .. "KB,",
                "got " .. tostring(math.floor(actual_size / 1024)) .. "KB")
        end
    end

    logger.info("BookLore: downloaded book", book_id, "→", dest_path,
        string.format("(%.1f KB)", actual_size / 1024))

    return true, nil
end

return BookLoreApi