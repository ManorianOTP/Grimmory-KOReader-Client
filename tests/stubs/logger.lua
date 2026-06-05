local logger = {}

local _buffer = { dbg = {}, info = {}, warn = {}, err = {} }

local function capture(level, ...)
    local parts = {}
    for i = 1, select("#", ...) do
        table.insert(parts, tostring(select(i, ...)))
    end
    table.insert(_buffer[level], table.concat(parts, " "))
end

function logger.dbg(...)  capture("dbg",  ...) end
function logger.info(...) capture("info", ...) end
function logger.warn(...) capture("warn", ...) end
function logger.err(...)  capture("err",  ...) end

function logger.reset()
    _buffer = { dbg = {}, info = {}, warn = {}, err = {} }
end

function logger.get(level)
    return _buffer[level] or {}
end

function logger.last(level)
    local buf = _buffer[level] or {}
    return buf[#buf]
end

function logger.has(level, substring)
    for _, msg in ipairs(_buffer[level] or {}) do
        if msg:find(substring, 1, true) then return true end
    end
    return false
end

return logger
