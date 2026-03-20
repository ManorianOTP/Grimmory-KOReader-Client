--[[
    BookLore API client module.
    Handles authentication and REST API requests to a BookLore server.
]]--

local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local logger = require("logger")

local BookLoreApi = {}

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
    logger.dbg("BookLore POST", url, "→", code)
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
    logger.dbg("BookLore GET", url, "→", code)
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

    -- BookLore returns accessToken (confirmed from external clients)
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
-- @param server_url string: base URL
-- @param token string: JWT
-- @return table|nil: libraries array, or nil on error
-- @return string|nil: error message, or nil on success
function BookLoreApi:getLibraries(server_url, token)
    local url = server_url .. "/api/v1/libraries"
    return self:get(url, token)
end

--- Fetch all books.
-- @param server_url string: base URL
-- @param token string: JWT
-- @return table|nil: books array, or nil on error
-- @return string|nil: error message, or nil on success
function BookLoreApi:getBooks(server_url, token)
    local url = server_url .. "/api/v1/books"
    return self:get(url, token)
end

--- Download a book's cover thumbnail to a file.
-- Media endpoints use ?token= query param, NOT the Authorization header.
-- Note: BookLore may return Content-Type: application/json despite
-- serving image data — this is a known server bug. Treat as binary.
-- The image format is detected from magic bytes and saved with the
-- correct extension so KOReader's ImageWidget can load it.
-- @param server_url string: base URL
-- @param book_id number: book ID
-- @param token string: JWT
-- @param cache_dir string: directory to save the image in
-- @return string|nil: file path on success, or nil on error
-- @return string|nil: error message on failure
function BookLoreApi:downloadCover(server_url, book_id, token, cache_dir)
    local url = server_url .. "/api/v1/media/book/" .. tostring(book_id)
        .. "/thumbnail?token=" .. token

    -- Download to a temp file first
    local tmp_path = cache_dir .. "/cover_" .. tostring(book_id) .. ".tmp"
    local f, open_err = io.open(tmp_path, "wb")
    if not f then
        return nil, "Cannot write: " .. tostring(open_err)
    end

    local _, code = http.request{
        url = url,
        sink = ltn12.sink.file(f),  -- ltn12 closes f automatically
    }

    if code ~= 200 then
        os.remove(tmp_path)
        return nil, "HTTP " .. tostring(code)
    end

    -- Read magic bytes to detect format
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

    -- Detect image type from magic bytes
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
        -- Log the bytes for debugging
        local hex = {}
        for i = 1, math.min(#header, 8) do
            table.insert(hex, string.format("%02X", header:byte(i)))
        end
        os.remove(tmp_path)
        return nil, "Unknown image format. Header: " .. table.concat(hex, " ")
    end

    -- Rename to final path with correct extension
    local final_path = cache_dir .. "/cover_" .. tostring(book_id) .. "." .. ext
    os.remove(final_path)  -- remove old cached version if any
    os.rename(tmp_path, final_path)

    return final_path, nil
end

return BookLoreApi