local ffi_util = {}

function ffi_util.template(fmt, ...)
    local args = { ... }
    local i = 0
    return (fmt:gsub("%%(%d+)", function(n)
        local idx = tonumber(n)
        i = i + 1
        return tostring(args[idx] or "")
    end))
end

return ffi_util
