local logger = require("logger")
local SLAXML = require("slaxml")

local cfi = {}

-- crengine synthetic elements that do not exist in real EPUB XHTML
local SYNTHETIC = {
    DocFragment = true,
    styleSheet  = true,
    autoBoxing  = true,
    floatBox    = true,
    inlineBox   = true,
    tabularBox  = true,
    rubyBox     = true,
    pseudoElem  = true,
}

-- Session-scoped state cleared by clearCache()
local _reader   = nil   -- ffi.archiver Reader handle
local _spine    = nil   -- array of {idref, href}
local _opf_dir  = ""    -- directory prefix for OPF-relative hrefs

-- ── EPUB parsing ──────────────────────────────────────────────────────────────

local function parseContainerXml(xml)
    local opf_path = nil
    local parser = SLAXML:parser{
        startElement = function(name)
            -- handled in attribute callback via closure
        end,
        attribute = function(name, value)
            if name == "full-path" then
                opf_path = value
            end
        end,
    }
    local ok, err = pcall(function() parser:parse(xml, {stripWhitespace=true}) end)
    if not ok then return nil, "container.xml parse error: " .. tostring(err) end
    if not opf_path then return nil, "container.xml: no rootfile full-path" end
    return opf_path, nil
end

local function parseOpf(xml)
    local manifest = {}   -- id -> href
    local spine    = {}   -- ordered {idref, href}
    local in_manifest = false
    local in_spine    = false

    local parser = SLAXML:parser{
        startElement = function(name)
            if name == "manifest" then in_manifest = true; in_spine = false
            elseif name == "spine" then in_spine = true; in_manifest = false
            elseif name == "item" then
                -- attributes follow; stash in progress table
                manifest._cur = {}
            elseif name == "itemref" then
                spine._cur_idref = nil
            end
        end,
        attribute = function(name, value)
            if in_manifest and manifest._cur then
                if name == "id"   then manifest._cur.id   = value end
                if name == "href" then manifest._cur.href = value end
            elseif in_spine then
                if name == "idref" then spine._cur_idref = value end
            end
        end,
        closeElement = function(name)
            if name == "manifest" then in_manifest = false
            elseif name == "spine" then in_spine = false
            elseif name == "item" and manifest._cur then
                local cur = manifest._cur
                if cur.id and cur.href then
                    manifest[cur.id] = cur.href
                end
                manifest._cur = nil
            elseif name == "itemref" and spine._cur_idref then
                local idref = spine._cur_idref
                local href  = manifest[idref]
                if href then
                    table.insert(spine, {idref = idref, href = href})
                end
                spine._cur_idref = nil
            end
        end,
    }

    local ok, err = pcall(function() parser:parse(xml, {stripWhitespace=true}) end)
    if not ok then return nil, "OPF parse error: " .. tostring(err) end
    if #spine == 0 then return nil, "OPF: empty spine" end

    -- strip internal cursor fields before returning
    manifest._cur = nil
    spine._cur_idref = nil
    return spine, nil
end

-- ── Public: initBook / clearCache ─────────────────────────────────────────────

-- initBook accepts an optional reader argument for testability.
-- When reader is provided the ffi/archiver require is skipped.
function cfi.initBook(file_path, reader)
    cfi.clearCache()

    if not reader then
        local ok, Ar = pcall(require, "ffi/archiver")
        if not ok then
            return nil, "ffi/archiver not available: " .. tostring(Ar)
        end
        reader = Ar.Reader:new()
    end

    local opened, open_err = pcall(function() reader:open(file_path) end)
    if not opened then
        return nil, "archiver open failed: " .. tostring(open_err)
    end

    -- iterate-then-seek pattern: must iterate before extractToMemory works
    for dummy in reader:iterate() do end

    local container_xml = reader:extractToMemory("META-INF/container.xml")
    if not container_xml or #container_xml == 0 then
        reader:close()
        return nil, "META-INF/container.xml not found in EPUB"
    end

    local opf_path, cerr = parseContainerXml(container_xml)
    if not opf_path then
        reader:close()
        return nil, cerr
    end

    local opf_dir = opf_path:match("^(.*)/[^/]+$") or ""

    local opf_xml = reader:extractToMemory(opf_path)
    if not opf_xml or #opf_xml == 0 then
        reader:close()
        return nil, "OPF not found at: " .. opf_path
    end

    local spine, serr = parseOpf(opf_xml)
    if not spine then
        reader:close()
        return nil, serr
    end

    _reader  = reader
    _spine   = spine
    _opf_dir = opf_dir

    logger.dbg("BookLoreSync CFI: spine parsed, items =", #spine)
    return true, nil
end

function cfi.clearCache()
    if _reader then
        pcall(function() _reader:close() end)
        _reader = nil
    end
    _spine   = nil
    _opf_dir = ""
end

-- ── Internal: XPointer parsing ────────────────────────────────────────────────

local function parseXPointer(xp)
    -- Expected format: /body/DocFragment[N]/body/elem[i]/elem[j].charoffset
    -- or without char offset: /body/DocFragment[N]/body/elem[i]/elem[j]
    local frag_idx = xp:match("^/body/DocFragment%[(%d+)%]")
    if not frag_idx then
        return nil, "XPointer does not match /body/DocFragment[N]/... pattern"
    end
    frag_idx = tonumber(frag_idx)

    -- Extract the path after /body/DocFragment[N]/body
    -- The second /body corresponds to the XHTML <body> element which is our walk root
    local rest = xp:match("^/body/DocFragment%[%d+%]/body(.*)")
    if not rest then
        return nil, "XPointer: cannot extract path after DocFragment"
    end

    -- Split char offset from the last step (format: .offset at end)
    local char_offset = nil
    local path_str = rest
    local dot_pos = path_str:match("(.*)%.(%d+)$")
    if dot_pos then
        -- last component is .N (char offset)
        local offset_str
        path_str, offset_str = path_str:match("^(.*)%.(%d+)$")
        char_offset = tonumber(offset_str)
    end

    -- Parse path steps: /elem[idx]/elem[idx]...
    -- text() or text()[N] is a text node selector, not an element — handle specially
    local path_steps = {}
    local text_node_index = nil  -- which text child (1-based) holds the char offset
    for seg in path_str:gmatch("/([^/]+)") do
        -- Check for text() or text()[N]
        local text_idx = seg:match("^text%(%)%[(%d+)%]$")
        if text_idx then
            text_node_index = tonumber(text_idx)
        elseif seg == "text()" then
            text_node_index = 1
        else
            local elem_name, idx = seg:match("^([^%[]+)%[(%d+)%]$")
            if not elem_name then
                elem_name = seg
                idx = 1
            else
                idx = tonumber(idx)
            end
            if not SYNTHETIC[elem_name] then
                table.insert(path_steps, {element_name = elem_name, name_index = idx})
            end
        end
    end

    return {
        doc_fragment_index = frag_idx,
        path_steps         = path_steps,
        char_offset        = char_offset,
        text_node_index    = text_node_index,
    }, nil
end

-- ── Internal: UTF-16 code unit counting ──────────────────────────────────────

-- Convert a byte offset in a UTF-8 string to UTF-16 code unit count.
-- epub.js CFI char offsets are UTF-16 code units.
local function byteOffsetToUtf16Units(text, byte_offset)
    local units = 0
    local i = 1
    local limit = math.min(byte_offset, #text)
    while i <= limit do
        local b = text:byte(i)
        local char_bytes
        if b < 0x80 then
            char_bytes = 1
        elseif b < 0xC0 then
            -- continuation byte (malformed lead): treat as 1 unit
            char_bytes = 1
        elseif b < 0xE0 then
            char_bytes = 2
        elseif b < 0xF0 then
            char_bytes = 3
        else
            -- 4-byte sequence = supplementary plane = 2 UTF-16 units (surrogate pair)
            char_bytes = 4
            units = units + 1  -- extra unit for surrogate pair
        end
        units = units + 1
        i = i + char_bytes
    end
    return units
end

-- Convert a UTF-16 code unit count back to a byte offset in a UTF-8 string.
local function utf16UnitsToByteOffset(text, utf16_units)
    local units = 0
    local i = 1
    while i <= #text and units < utf16_units do
        local b = text:byte(i)
        local char_bytes
        if b < 0x80 then
            char_bytes = 1
        elseif b < 0xC0 then
            char_bytes = 1
        elseif b < 0xE0 then
            char_bytes = 2
        elseif b < 0xF0 then
            char_bytes = 3
        else
            char_bytes = 4
            units = units + 1  -- surrogate pair: consume 2 units
            if units >= utf16_units then break end
        end
        units = units + 1
        i = i + char_bytes
    end
    return i - 1
end

-- ── Internal: DOM walking for CFI path ───────────────────────────────────────

-- Resolve OPF-relative href to full archive path.
local function resolveHref(href)
    if _opf_dir == "" then return href end
    return _opf_dir .. "/" .. href
end

-- Walk a SLAXML DOM element tree following path_steps.
-- path_steps: array of {element_name, name_index} using crengine per-name indexing.
-- Returns the matched node (element or nil) plus its absolute CFI child index,
-- plus text content and accumulated CFI path string.
local function walkDomForCFI(root_element, path_steps)
    local current = root_element
    local cfi_parts = {}

    for step_i, step in ipairs(path_steps) do
        local target_name = step.element_name
        local target_idx  = step.name_index

        local abs_child_idx = 0
        local name_count    = 0
        local found_node    = nil
        local found_abs_idx = nil

        for _, kid in ipairs(current.kids) do
            if kid.type == "element" then
                -- Next even index after current position
                if abs_child_idx % 2 == 1 then
                    abs_child_idx = abs_child_idx + 1
                end
                abs_child_idx = abs_child_idx + 2
                if kid.name == target_name then
                    name_count = name_count + 1
                    if name_count == target_idx then
                        found_node    = kid
                        found_abs_idx = abs_child_idx
                    end
                end
            elseif kid.type == "text" then
                abs_child_idx = abs_child_idx + 1
            end
        end

        if not found_node then
            return nil, nil, nil, string.format(
                "path step %d: element '%s'[%d] not found in DOM",
                step_i, target_name, target_idx
            )
        end

        table.insert(cfi_parts, tostring(found_abs_idx))
        current = found_node
    end

    return current, cfi_parts, nil
end

-- Collect all text content of a DOM node (depth-first).
local function collectText(node)
    if node.type == "text" then return node.value end
    local parts = {}
    for _, kid in ipairs(node.kids or {}) do
        table.insert(parts, collectText(kid))
    end
    return table.concat(parts)
end

-- ── Internal: computeCFIPath ──────────────────────────────────────────────────

local function computeCFIPath(spine_href, path_steps, char_offset, text_node_index)
    local archive_path = resolveHref(spine_href)
    local xhtml = _reader:extractToMemory(archive_path)
    if not xhtml or #xhtml == 0 then
        return nil, "XHTML not found in archive: " .. archive_path
    end
    -- SLAXML v0.8 rejects DOCTYPE as non-whitespace root text; strip before parse.
    xhtml = xhtml:gsub("<!DOCTYPE[^>]*>", "", 1)

    local ok, doc = pcall(function()
        return SLAXML:dom(xhtml, {stripWhitespace=true})
    end)
    if not ok or not doc then
        return nil, "XHTML DOM parse failed: " .. tostring(doc)
    end

    -- Find <html> root and <body>, computing body's CFI index within <html>
    local html_node = nil
    for _, kid in ipairs(doc.kids or {}) do
        if kid.type == "element" and kid.name == "html" then
            html_node = kid
            break
        end
    end
    if not html_node then
        return nil, "XHTML: no <html> element found"
    end

    local body = nil
    local body_cfi_idx = 0
    local abs_idx = 0
    for _, kid in ipairs(html_node.kids or {}) do
        if kid.type == "element" then
            if abs_idx % 2 == 1 then abs_idx = abs_idx + 1 end
            abs_idx = abs_idx + 2
            if kid.name == "body" then
                body = kid
                body_cfi_idx = abs_idx
                break
            end
        elseif kid.type == "text" then
            abs_idx = abs_idx + 1
        end
    end

    if not body then
        return nil, "XHTML: no <body> element found"
    end

    -- Walk from body's children (path_steps already exclude /body)
    local matched_node, cfi_parts, walk_err = walkDomForCFI(body, path_steps)
    if not matched_node then
        return nil, walk_err or "DOM walk failed"
    end

    -- CFI content path: /body_idx/child_steps...
    local cfi_path = "/" .. tostring(body_cfi_idx) .. "/" .. table.concat(cfi_parts, "/")

    if char_offset then
        -- Find the target text node within matched_node.
        -- text_node_index (from XPointer text()[N]) identifies which text child.
        -- In CFI, text nodes get odd indices: 1st text=1, after 1st element=3, etc.
        local target_text_idx = text_node_index or 1
        local text_count = 0
        local text_content = nil

        for _, kid in ipairs(matched_node.kids or {}) do
            if kid.type == "text" then
                text_count = text_count + 1
                if text_count == target_text_idx then
                    text_content = kid.value
                    break
                end
            end
        end

        if text_content then
            local utf16_units = byteOffsetToUtf16Units(text_content, char_offset)
            -- CFI text node step: odd index for the Nth text node
            local text_odd_idx = 1
            local count2 = 0
            local abs_idx = 0
            for _, kid in ipairs(matched_node.kids or {}) do
                if kid.type == "element" then
                    if abs_idx % 2 == 1 then abs_idx = abs_idx + 1 end
                    abs_idx = abs_idx + 2
                elseif kid.type == "text" then
                    abs_idx = abs_idx + 1
                    count2 = count2 + 1
                    if count2 == target_text_idx then
                        text_odd_idx = abs_idx
                        break
                    end
                end
            end
            cfi_path = cfi_path .. "/" .. tostring(text_odd_idx) .. ":" .. tostring(utf16_units)
        else
            return nil, "text node " .. tostring(text_node_index) .. " not found"
        end
    end

    return cfi_path, nil
end

-- ── Public: xpointerToCFI ────────────────────────────────────────────────────

function cfi.xpointerToCFI(xp)
    if not _spine or not _reader then
        return nil, "cfi module not initialized (call initBook first)"
    end

    local parsed, perr = parseXPointer(xp)
    if not parsed then
        return nil, perr
    end

    local frag_idx = parsed.doc_fragment_index
    local spine_entry = _spine[frag_idx]
    if not spine_entry then
        return nil, string.format("DocFragment[%d] out of spine bounds (spine has %d items)", frag_idx, #_spine)
    end

    local dom_path, derr = computeCFIPath(spine_entry.href, parsed.path_steps, parsed.char_offset, parsed.text_node_index)
    if not dom_path then
        return nil, derr
    end

    local spine_even_idx = frag_idx * 2
    local idref = spine_entry.idref
    -- Assemble epub.js-compatible CFI
    local cfi_str = string.format("epubcfi(/6/%d[%s]!%s)", spine_even_idx, idref, dom_path)
    return cfi_str, nil
end

-- ── Public: cfiToXPointer ────────────────────────────────────────────────────

function cfi.cfiToXPointer(cfi_string)
    if not _spine or not _reader then
        return nil, "cfi module not initialized (call initBook first)"
    end

    -- Parse: epubcfi(/6/{spine_even}[{idref}]!/{steps}:{offset})
    local spine_even_str, idref, inner = cfi_string:match(
        "^epubcfi%(/6/(%d+)%[([^%]]+)%]!/(.+)%)$"
    )
    if not spine_even_str then
        -- Try without idref
        spine_even_str, inner = cfi_string:match(
            "^epubcfi%(/6/(%d+)!/(.+)%)$"
        )
        idref = nil
    end
    if not spine_even_str then
        return nil, "CFI does not match expected epubcfi(/6/N[id]!/...) format"
    end

    local spine_even = tonumber(spine_even_str)
    local frag_idx   = spine_even / 2
    if frag_idx ~= math.floor(frag_idx) or frag_idx < 1 then
        return nil, "CFI spine index is not a valid even number: " .. spine_even_str
    end

    local spine_entry = _spine[frag_idx]
    if not spine_entry then
        return nil, string.format("CFI spine index %d out of bounds (spine has %d items)", frag_idx, #_spine)
    end

    -- Parse char offset from end of inner (e.g. "4/2/6:42" -> offset=42).
    -- If the last path segment before ':' is an odd index, it identifies the
    -- Nth text child of the containing element (needed for crengine text()[N]).
    local char_offset_utf16 = nil
    local text_node_abs = nil
    local path_str = inner
    local steps_str, offset_str = inner:match("^(.*):(%d+)$")
    if steps_str then
        path_str = steps_str
        char_offset_utf16 = tonumber(offset_str)
        local pre, last = steps_str:match("^(.-)/(%d+)$")
        if last and tonumber(last) % 2 == 1 then
            text_node_abs = tonumber(last)
        end
    end

    -- Ensure path has leading '/' so gmatch picks up the first segment
    if not path_str:match("^/") then path_str = "/" .. path_str end

    -- Parse absolute CFI child indices (even numbers for elements).
    -- Pattern tolerates id-assertion brackets (e.g. "/2[filepos729410]").
    local abs_indices = {}
    for seg in path_str:gmatch("/(%d+)") do
        local idx = tonumber(seg)
        if idx % 2 == 0 then  -- even = element
            table.insert(abs_indices, idx)
        end
        -- odd indices (text nodes) are not navigated to as elements
    end

    -- Load XHTML and walk DOM to convert absolute indices to per-name indices
    local archive_path = resolveHref(spine_entry.href)
    local xhtml = _reader:extractToMemory(archive_path)
    if not xhtml or #xhtml == 0 then
        return nil, "XHTML not found: " .. archive_path
    end
    xhtml = xhtml:gsub("<!DOCTYPE[^>]*>", "", 1)

    local ok, doc = pcall(function()
        return SLAXML:dom(xhtml, {stripWhitespace=true})
    end)
    if not ok or not doc then
        return nil, "XHTML DOM parse failed: " .. tostring(doc)
    end

    -- Find <html>, then locate <body> within it and consume the first abs index
    -- (which is body's CFI index within <html>, not a step inside body).
    local html_node = nil
    for _, kid in ipairs(doc.kids or {}) do
        if kid.type == "element" and kid.name == "html" then
            html_node = kid
            break
        end
    end
    if not html_node then
        return nil, "XHTML: no <html> element"
    end

    local body = nil
    local body_abs = 0
    do
        local abs_idx = 0
        for _, kid in ipairs(html_node.kids or {}) do
            if kid.type == "element" then
                if abs_idx % 2 == 1 then abs_idx = abs_idx + 1 end
                abs_idx = abs_idx + 2
                if kid.name == "body" then
                    body = kid
                    body_abs = abs_idx
                    break
                end
            elseif kid.type == "text" then
                abs_idx = abs_idx + 1
            end
        end
    end
    if not body then
        return nil, "XHTML: no <body> element"
    end

    -- First abs index should be body's position within <html>; drop it.
    if #abs_indices == 0 or abs_indices[1] ~= body_abs then
        return nil, string.format(
            "CFI leading index %s does not match body index %d",
            tostring(abs_indices[1]), body_abs
        )
    end
    table.remove(abs_indices, 1)

    -- Walk DOM following absolute CFI indices, collecting per-name crengine steps
    local current = body
    local xp_steps = {}

    for step_i, target_abs in ipairs(abs_indices) do
        local child_abs = 0
        local found_node = nil
        local found_name = nil
        local found_name_idx = nil

        -- Count elements by name up to target_abs position
        local name_counts = {}

        for _, kid in ipairs(current.kids) do
            if kid.type == "element" then
                if child_abs % 2 == 1 then child_abs = child_abs + 1 end
                child_abs = child_abs + 2
                local n = kid.name
                name_counts[n] = (name_counts[n] or 0) + 1
                if child_abs == target_abs then
                    found_node     = kid
                    found_name     = n
                    found_name_idx = name_counts[n]
                end
            elseif kid.type == "text" then
                child_abs = child_abs + 1
            end
        end

        if not found_node then
            return nil, string.format("CFI step %d: absolute index %d not found in DOM", step_i, target_abs)
        end

        table.insert(xp_steps, string.format("%s[%d]", found_name, found_name_idx))
        current = found_node
    end

    -- Map CFI text-node absolute index to the Nth text child of `current`,
    -- then convert UTF-16 char offset to a byte offset within that text node.
    -- crengine requires an explicit /text()[N] selector before the offset.
    local text_suffix = ""
    if char_offset_utf16 then
        local target_text_n = 1
        if text_node_abs then
            local abs_idx = 0
            local text_count = 0
            for _, kid in ipairs(current.kids or {}) do
                if kid.type == "element" then
                    if abs_idx % 2 == 1 then abs_idx = abs_idx + 1 end
                    abs_idx = abs_idx + 2
                elseif kid.type == "text" then
                    abs_idx = abs_idx + 1
                    text_count = text_count + 1
                    if abs_idx == text_node_abs then
                        target_text_n = text_count
                        break
                    end
                end
            end
        end

        local text_content = nil
        local tc = 0
        for _, kid in ipairs(current.kids or {}) do
            if kid.type == "text" then
                tc = tc + 1
                if tc == target_text_n then
                    text_content = kid.value
                    break
                end
            end
        end
        if not text_content then
            text_content = collectText(current)
        end

        local byte_off = utf16UnitsToByteOffset(text_content, char_offset_utf16)
        text_suffix = string.format("/text()[%d].%d", target_text_n, byte_off)
    end

    local xpointer = string.format(
        "/body/DocFragment[%d]/body/%s%s",
        frag_idx,
        table.concat(xp_steps, "/"),
        text_suffix
    )
    return xpointer, nil
end

return cfi
