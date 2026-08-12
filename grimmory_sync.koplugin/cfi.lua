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

    logger.dbg("GrimmorySync CFI: spine parsed, items =", #spine)
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

-- ── Internal: CREngine scalar offsets <-> EPUB CFI UTF-16 offsets ────────────

-- CREngine stores DOM text as lString32 (one lChar32 per Unicode scalar) and
-- serializes an ldomXPointer's `_offset` directly as `.N`. It is therefore a
-- Unicode scalar/code-point offset: neither a UTF-8 byte offset nor a grapheme
-- count. epub.js/DOM Range CFI offsets, on the other hand, are UTF-16 code
-- units. In particular, smart punctuation and combining marks each occupy one
-- unit in both domains, while an astral scalar occupies one CREngine position
-- and two CFI units.
local function utf8ScalarWidth(text, index)
    local b1 = text:byte(index)
    if not b1 then return nil, nil, "unexpected end of UTF-8 text" end
    if b1 < 0x80 then return 1, false end

    local b2, b3, b4 = text:byte(index + 1, index + 3)
    local function continuation(value)
        return value ~= nil and value >= 0x80 and value <= 0xBF
    end
    if b1 >= 0xC2 and b1 <= 0xDF and continuation(b2) then
        return 2, false
    end
    if b1 == 0xE0 and b2 and b2 >= 0xA0 and b2 <= 0xBF
            and continuation(b3) then
        return 3, false
    end
    if ((b1 >= 0xE1 and b1 <= 0xEC) or (b1 >= 0xEE and b1 <= 0xEF))
            and continuation(b2) and continuation(b3) then
        return 3, false
    end
    -- UTF-8 encodings of UTF-16 surrogate code points are invalid.
    if b1 == 0xED and b2 and b2 >= 0x80 and b2 <= 0x9F
            and continuation(b3) then
        return 3, false
    end
    if b1 == 0xF0 and b2 and b2 >= 0x90 and b2 <= 0xBF
            and continuation(b3) and continuation(b4) then
        return 4, true
    end
    if b1 >= 0xF1 and b1 <= 0xF3 and continuation(b2)
            and continuation(b3) and continuation(b4) then
        return 4, true
    end
    if b1 == 0xF4 and b2 and b2 >= 0x80 and b2 <= 0x8F
            and continuation(b3) and continuation(b4) then
        return 4, true
    end
    return nil, nil, string.format("invalid UTF-8 at byte %d", index)
end

local function utf8ScalarCount(text)
    local count, index = 0, 1
    while index <= #text do
        local width, _, err = utf8ScalarWidth(text, index)
        if not width then return nil, err end
        count = count + 1
        index = index + width
    end
    return count
end

-- Convert a CREngine Unicode-scalar offset to epub.js UTF-16 code units.
local function scalarOffsetToUtf16Units(text, scalar_offset)
    scalar_offset = tonumber(scalar_offset)
    if not scalar_offset or scalar_offset < 0
            or scalar_offset ~= math.floor(scalar_offset) then
        return nil, "CREngine text offset is not a non-negative integer"
    end
    local scalars, units, index = 0, 0, 1
    while scalars < scalar_offset do
        if index > #text then
            return nil, "CREngine text offset exceeds text length"
        end
        local width, astral, err = utf8ScalarWidth(text, index)
        if not width then return nil, err end
        scalars = scalars + 1
        units = units + (astral and 2 or 1)
        index = index + width
    end
    return units
end

-- Convert an epub.js UTF-16 offset back to CREngine Unicode scalars. Refuse a
-- location between the two halves of a surrogate pair: CREngine cannot express
-- it and silently snapping would move the annotation endpoint.
local function utf16UnitsToScalarOffset(text, utf16_units)
    utf16_units = tonumber(utf16_units)
    if not utf16_units or utf16_units < 0
            or utf16_units ~= math.floor(utf16_units) then
        return nil, "CFI text offset is not a non-negative integer"
    end
    local scalars, units, index = 0, 0, 1
    while units < utf16_units do
        if index > #text then return nil, "CFI text offset exceeds text length" end
        local width, astral, err = utf8ScalarWidth(text, index)
        if not width then return nil, err end
        local next_units = units + (astral and 2 or 1)
        if next_units > utf16_units then
            return nil, "CFI text offset splits an astral surrogate pair"
        end
        scalars = scalars + 1
        units = next_units
        index = index + width
    end
    return scalars
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
local function meaningfulText(node)
    return node.type == "text" and type(node.value) == "string"
        and node.value:find("%S") ~= nil
end

-- EPUB CFI child indices describe the normalized sequence
--
--     [character data, element, character data, element, character data]
--
-- rather than incrementing once for every DOM child. Element children are
-- therefore always 2, 4, 6, ... by element ordinal, even when meaningful text
-- precedes them. Character-data chunks use the odd index on the corresponding
-- side of those elements. Foliate's indexChildNodes() implements this rule.
local function elementCfiIndex(element_ordinal)
    return element_ordinal * 2
end

local function textChunkCfiIndex(preceding_elements)
    return preceding_elements * 2 + 1
end

local function walkDomForCFI(root_element, path_steps)
    local current = root_element
    local cfi_parts = {}

    for step_i, step in ipairs(path_steps) do
        local target_name = step.element_name
        local target_idx  = step.name_index

        local element_ordinal = 0
        local name_count    = 0
        local found_node    = nil
        local found_abs_idx = nil

        for _, kid in ipairs(current.kids) do
            if kid.type == "element" then
                element_ordinal = element_ordinal + 1
                if kid.name == target_name then
                    name_count = name_count + 1
                    if name_count == target_idx then
                        found_node    = kid
                        found_abs_idx = elementCfiIndex(element_ordinal)
                    end
                end
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
    if node.type == "text" then
        return meaningfulText(node) and node.value or ""
    end
    local parts = {}
    for _, kid in ipairs(node.kids or {}) do
        table.insert(parts, collectText(kid))
    end
    return table.concat(parts)
end

-- CREngine resolves a non-empty element anchor to its first concrete text
-- position. Emit that canonical XPointer up front so the exact target passed
-- to GotoXPointer is also what document:getXPointer reports after navigation.
local function firstTextXPointerSuffix(node)
    local name_counts, text_count = {}, 0
    for _, kid in ipairs(node.kids or {}) do
        if kid.type == "element" then
            name_counts[kid.name] = (name_counts[kid.name] or 0) + 1
            local nested = firstTextXPointerSuffix(kid)
            if nested then
                return string.format("/%s[%d]%s", kid.name,
                    name_counts[kid.name], nested)
            end
        elseif meaningfulText(kid) then
            text_count = text_count + 1
            return string.format("/text()[%d].0", text_count)
        end
    end
end

-- CREngine sometimes reports a character offset on a containing element
-- instead of appending /text()[N] to its XPointer. This is common in EPUBs
-- whose paragraphs are split by inline spans/emphasis. Resolve that flattened
-- Unicode-scalar offset to the concrete descendant text node required by CFI.
-- Returns descendant element CFI indices, text-node CFI index, text and the
-- scalar offset local to that text node.
local function locateFlattenedText(node, scalar_offset)
    local remaining = math.max(0, tonumber(scalar_offset) or 0)
    local element_ordinal = 0
    local chunk_prefix_utf16 = 0
    local last_text
    for _, kid in ipairs(node.kids or {}) do
        if kid.type == "element" then
            element_ordinal = element_ordinal + 1
            chunk_prefix_utf16 = 0
            local length, length_err = utf8ScalarCount(collectText(kid))
            if not length then return nil, nil, nil, nil, length_err end
            if remaining <= length then
                local steps, text_idx, text, local_offset, nested_err,
                    nested_prefix_utf16 =
                    locateFlattenedText(kid, remaining)
                if text then
                    table.insert(steps, 1, elementCfiIndex(element_ordinal))
                    return steps, text_idx, text, local_offset, nil,
                        nested_prefix_utf16
                end
                if nested_err then return nil, nil, nil, nil, nested_err end
            end
            remaining = remaining - length
        elseif meaningfulText(kid) then
            local length, length_err = utf8ScalarCount(kid.value)
            if not length then return nil, nil, nil, nil, length_err end
            local text_idx = textChunkCfiIndex(element_ordinal)
            last_text = {
                {}, text_idx, kid.value, length, nil, chunk_prefix_utf16,
            }
            if remaining <= length then
                return {}, text_idx, kid.value, remaining, nil,
                    chunk_prefix_utf16
            end
            remaining = remaining - length
            local full_units, units_err = scalarOffsetToUtf16Units(
                kid.value, length)
            if not full_units then return nil, nil, nil, nil, units_err end
            chunk_prefix_utf16 = chunk_prefix_utf16 + full_units
        end
    end
    if last_text then return unpack(last_text) end
    return nil, nil, nil, nil
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
        -- Preserve leading/trailing spaces inside meaningful inline text. The
        -- old stripWhitespace mode trimmed "Hello " to "Hello", shifting all
        -- flattened offsets after an inline boundary. Indexing helpers still
        -- ignore indentation-only nodes, preserving stable structural steps.
        return SLAXML:dom(xhtml, {stripWhitespace=false})
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
    local element_ordinal = 0
    for _, kid in ipairs(html_node.kids or {}) do
        if kid.type == "element" then
            element_ordinal = element_ordinal + 1
            if kid.name == "body" then
                body = kid
                body_cfi_idx = elementCfiIndex(element_ordinal)
                break
            end
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
        if text_node_index == nil then
            local descendant_steps, text_odd_idx, descendant_text,
                descendant_offset, descendant_err, chunk_prefix_utf16 =
                    locateFlattenedText(matched_node, char_offset)
            if not descendant_text then
                -- CREngine anchors image/SVG pages at the empty element with
                -- a synthetic `.0` suffix (for example `/p[313]/img.0`). An
                -- element CFI is the exact, reversible representation; there
                -- is no text assertion to add and nothing should be invented.
                if char_offset == 0 then return cfi_path, nil end
                return nil, descendant_err or "element has no descendant text node"
            end
            for _, step in ipairs(descendant_steps) do
                cfi_path = cfi_path .. "/" .. tostring(step)
            end
            local utf16_units, offset_err = scalarOffsetToUtf16Units(
                descendant_text, descendant_offset)
            if not utf16_units then return nil, offset_err end
            cfi_path = cfi_path .. "/" .. tostring(text_odd_idx) .. ":"
                .. tostring((chunk_prefix_utf16 or 0) + utf16_units)
            return cfi_path, nil
        end
        -- Find the target text node within matched_node.
        -- text_node_index (from XPointer text()[N]) identifies which text child.
        -- In CFI, text nodes get odd indices: 1st text=1, after 1st element=3, etc.
        local target_text_idx = text_node_index or 1
        local text_count = 0
        local element_ordinal = 0
        local chunk_prefix_utf16 = 0
        local text_content = nil
        local text_odd_idx = nil
        local text_prefix_utf16 = nil

        for _, kid in ipairs(matched_node.kids or {}) do
            if kid.type == "element" then
                element_ordinal = element_ordinal + 1
                chunk_prefix_utf16 = 0
            elseif meaningfulText(kid) then
                text_count = text_count + 1
                if text_count == target_text_idx then
                    text_content = kid.value
                    text_odd_idx = textChunkCfiIndex(element_ordinal)
                    text_prefix_utf16 = chunk_prefix_utf16
                    break
                end
                local length, length_err = utf8ScalarCount(kid.value)
                if not length then return nil, length_err end
                local full_units, units_err = scalarOffsetToUtf16Units(
                    kid.value, length)
                if not full_units then return nil, units_err end
                chunk_prefix_utf16 = chunk_prefix_utf16 + full_units
            end
        end

        if text_content then
            local utf16_units, offset_err = scalarOffsetToUtf16Units(
                text_content, char_offset)
            if not utf16_units then return nil, offset_err end
            cfi_path = cfi_path .. "/" .. tostring(text_odd_idx) .. ":"
                .. tostring((text_prefix_utf16 or 0) + utf16_units)
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

    -- epub.js reports a visible reflowable page as a CFI range. Grimmory may
    -- therefore store that real range as reading progress, not only for an
    -- annotation. Navigating to its first endpoint preserves the top of the
    -- web reader's viewport. Keep the original range untouched in server/state
    -- records; this conversion only chooses the concrete ReaderUI anchor.
    local range_start = cfi.splitRange and cfi.splitRange(cfi_string)
    if range_start then cfi_string = range_start end

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
        return SLAXML:dom(xhtml, {stripWhitespace=false})
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
        local element_ordinal = 0
        for _, kid in ipairs(html_node.kids or {}) do
            if kid.type == "element" then
                element_ordinal = element_ordinal + 1
                if kid.name == "body" then
                    body = kid
                    body_abs = elementCfiIndex(element_ordinal)
                    break
                end
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
        local element_ordinal = 0
        local found_node = nil
        local found_name = nil
        local found_name_idx = nil

        -- Count elements by name up to target_abs position
        local name_counts = {}

        for _, kid in ipairs(current.kids) do
            if kid.type == "element" then
                element_ordinal = element_ordinal + 1
                local child_abs = elementCfiIndex(element_ordinal)
                local n = kid.name
                name_counts[n] = (name_counts[n] or 0) + 1
                if child_abs == target_abs then
                    found_node     = kid
                    found_name     = n
                    found_name_idx = name_counts[n]
                end
            end
        end

        if not found_node then
            return nil, string.format("CFI step %d: absolute index %d not found in DOM", step_i, target_abs)
        end

        table.insert(xp_steps, string.format("%s[%d]", found_name, found_name_idx))
        current = found_node
    end

    -- Map CFI text-node absolute index to the Nth text child of `current`,
    -- then convert UTF-16 char offset to a CREngine scalar offset in that node.
    -- crengine requires an explicit /text()[N] selector before the offset.
    local text_suffix = ""
    if char_offset_utf16 then
        local target_text_n = nil
        local text_content = nil
        local local_utf16_offset = nil
        local element_ordinal = 0
        local text_count = 0
        local chunk_units = 0
        for _, kid in ipairs(current.kids or {}) do
            if kid.type == "element" then
                element_ordinal = element_ordinal + 1
                chunk_units = 0
            elseif meaningfulText(kid) then
                text_count = text_count + 1
                if not text_node_abs
                        or textChunkCfiIndex(element_ordinal) == text_node_abs then
                    local length, length_err = utf8ScalarCount(kid.value)
                    if not length then return nil, length_err end
                    local full_units, units_err = scalarOffsetToUtf16Units(
                        kid.value, length)
                    if not full_units then return nil, units_err end
                    if char_offset_utf16 <= chunk_units + full_units then
                        target_text_n = text_count
                        text_content = kid.value
                        local_utf16_offset = char_offset_utf16 - chunk_units
                        break
                    end
                    chunk_units = chunk_units + full_units
                end
            end
        end
        if not text_content or local_utf16_offset == nil then
            return nil, "CFI text node or offset not found in DOM"
        end

        local scalar_off, offset_err = utf16UnitsToScalarOffset(
            text_content, local_utf16_offset)
        if not scalar_off then return nil, offset_err end
        text_suffix = string.format("/text()[%d].%d", target_text_n, scalar_off)
    else
        text_suffix = firstTextXPointerSuffix(current) or ""
    end

    local xpointer = string.format(
        "/body/DocFragment[%d]/body/%s%s",
        frag_idx,
        table.concat(xp_steps, "/"),
        text_suffix
    )
    return xpointer, nil
end

-- Convert two point CFIs to the compact EPUB CFI range form used by Grimmory.
-- The common prefix is retained once and each endpoint stores only its suffix.
function cfi.asRange(cfi_a, cfi_b)
    local a = type(cfi_a) == "string" and cfi_a:match("^epubcfi%((.+)%)$")
    local b = type(cfi_b) == "string" and cfi_b:match("^epubcfi%((.+)%)$")
    if not a or not b then return nil, "invalid point CFI" end
    local common = ""
    for step in a:gmatch("([^/]+)") do
        local candidate = common .. "/" .. step
        if b:sub(1, #candidate + 1) ~= candidate .. "/" then break end
        common = candidate
    end
    if common == "" then return nil, "CFI endpoints have no common root" end
    return "epubcfi(" .. common .. "," .. a:sub(#common + 1)
        .. "," .. b:sub(#common + 1) .. ")", nil
end

function cfi.splitRange(range)
    if type(range) ~= "string" then return nil, nil, "invalid CFI range" end
    local root, suffix_a, suffix_b = range:match(
        "^epubcfi%(([^,]+),([^,]*),([^,]*)%)$")
    if not root then return nil, nil, "invalid CFI range" end
    return "epubcfi(" .. root .. suffix_a .. ")",
        "epubcfi(" .. root .. suffix_b .. ")", nil
end

function cfi.xpointerRangeToCFI(pos0, pos1)
    local first, err = cfi.xpointerToCFI(pos0)
    if not first then return nil, err end
    local last, last_err = cfi.xpointerToCFI(pos1)
    if not last then return nil, last_err end
    return cfi.asRange(first, last)
end

function cfi.cfiRangeToXPointers(range)
    local first, last, err = cfi.splitRange(range)
    if not first then return nil, nil, err end
    local pos0, first_err = cfi.cfiToXPointer(first)
    if not pos0 then return nil, nil, first_err end
    local pos1, last_err = cfi.cfiToXPointer(last)
    if not pos1 then return nil, nil, last_err end
    return pos0, pos1, nil
end

return cfi
