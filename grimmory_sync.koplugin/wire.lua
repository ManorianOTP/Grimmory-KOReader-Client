-- Auth-aware Grimmory sync transport. All functions are free of UI/settings
-- state so they are safe inside async.lua's subprocess executor.

local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")

local Wire = {}
local TIMEOUT_SECS = 3
local REFRESH_AFTER_SECS = 50 * 60

local function timedTCP()
    local socket = require("socket").tcp()
    socket:settimeout(TIMEOUT_SECS)
    return socket
end

local function requestFunction(server_url)
    if server_url:match("^https://") then
        local ok, https = pcall(require, "ssl.https")
        if ok then return https.request end
    end
    return http.request
end

local function request(server_url, path, method, token, body)
    local sink, headers = {}, {}
    if token and token ~= "" then headers.Authorization = "Bearer " .. token end
    if body ~= nil then
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#body)
    end
    local ok, code = pcall(function()
        local _, status = requestFunction(server_url){
            url = server_url .. path,
            method = method,
            headers = headers,
            source = body and ltn12.source.string(body) or nil,
            sink = ltn12.sink.table(sink),
            create = timedTCP,
        }
        return status
    end)
    if not ok then
        return { code = nil, body = "", transport_error = tostring(code) }
    end
    return { code = tonumber(code), body = table.concat(sink) }
end

local function refresh(server_url, credentials)
    if not credentials.refresh_token or credentials.refresh_token == "" then
        return false, "no-refresh-token"
    end
    local response = request(server_url, "/api/v1/auth/refresh", "POST", nil,
        json.encode({ refreshToken = credentials.refresh_token }))
    if response.code ~= 200 then
        if response.code == 400 or response.code == 401 or response.code == 403 then
            credentials.token = nil
            credentials.refresh_token = nil
            credentials.token_time = nil
            credentials.clear_tokens = true
            return false, "refresh-rejected"
        end
        return false, response.transport_error or ("HTTP " .. tostring(response.code))
    end
    local ok, decoded = pcall(json.decode, response.body)
    if not ok or type(decoded) ~= "table"
            or type(decoded.accessToken) ~= "string"
            or type(decoded.refreshToken) ~= "string" then
        return false, "invalid-refresh-response"
    end
    credentials.token = decoded.accessToken
    credentials.refresh_token = decoded.refreshToken
    credentials.token_time = os.time()
    credentials.rotated = true
    return true
end

function Wire.requestWithAuth(server_url, credentials, path, method, body)
    local stale = not credentials.token or credentials.token == ""
        or not credentials.token_time
        or os.time() - credentials.token_time > REFRESH_AFTER_SECS
    if stale and credentials.refresh_token and credentials.refresh_token ~= "" then
        local ok, err = refresh(server_url, credentials)
        if not ok then return { code = nil, body = "", auth_error = err, auth = credentials } end
    elseif stale and (not credentials.token or credentials.token == "") then
        return { code = nil, body = "", auth_error = "no-token", auth = credentials }
    end

    local response = request(server_url, path, method, credentials.token, body)
    if response.code == 401 and credentials.refresh_token then
        local ok, err = refresh(server_url, credentials)
        if not ok then
            return { code = 401, body = response.body, auth_error = err, auth = credentials }
        end
        response = request(server_url, path, method, credentials.token, body)
    end
    response.auth = credentials
    return response
end

function Wire.getAnnotations(server_url, book_id, credentials)
    return Wire.requestWithAuth(server_url, credentials,
        "/api/v1/annotations/book/" .. tostring(book_id), "GET")
end

function Wire.createAnnotation(server_url, body, credentials)
    return Wire.requestWithAuth(server_url, credentials,
        "/api/v1/annotations", "POST", json.encode(body))
end

function Wire.updateAnnotation(server_url, annotation_id, body, credentials)
    return Wire.requestWithAuth(server_url, credentials,
        "/api/v1/annotations/" .. tostring(annotation_id), "PUT", json.encode(body))
end

function Wire.deleteAnnotation(server_url, annotation_id, credentials)
    return Wire.requestWithAuth(server_url, credentials,
        "/api/v1/annotations/" .. tostring(annotation_id), "DELETE")
end

function Wire.recordSession(server_url, body, credentials)
    return Wire.requestWithAuth(server_url, credentials,
        "/api/v1/reading-sessions", "POST", json.encode(body))
end

function Wire.getSessions(server_url, book_id, page, credentials)
    local path = "/api/v1/reading-sessions/book/" .. tostring(book_id)
        .. "?page=" .. tostring(page or 0) .. "&size=100"
    return Wire.requestWithAuth(server_url, credentials, path, "GET")
end

return Wire
