--[[
  Minimal KOReader `util` surface used by plugin modules under test
  (downloads.lua). Only the behavior the call sites rely on is mirrored;
  the real implementation also handles reserved characters and filename
  length limits.
]]
local util = {}

-- Real getSafeFilename strips path separators and control characters so the
-- result is a single safe path component.
function util.getSafeFilename(str, path, limit, limit_ext)
    return (str:gsub("[/\\]", "_"):gsub("%c", ""))
end

-- Real fixUtf8 replaces invalid UTF-8 sequences with `replacement`; specs
-- feed valid UTF-8, so pass-through preserves the contract.
function util.fixUtf8(str, replacement)
    return str
end

function util.htmlToPlainTextIfHtml(text)
    return text
end

return util
