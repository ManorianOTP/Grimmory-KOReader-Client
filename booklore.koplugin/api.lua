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

return BookLoreApi