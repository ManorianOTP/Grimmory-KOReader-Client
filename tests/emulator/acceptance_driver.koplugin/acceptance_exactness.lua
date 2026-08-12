local Exactness = {}

local function sameScalar(left, right)
    if left == nil or right == nil then return left == nil and right == nil end
    if type(left) == "number" or type(right) == "number" then
        return tonumber(left) ~= nil and tonumber(right) ~= nil
            and tonumber(left) == tonumber(right)
    end
    return tostring(left) == tostring(right)
end

local function cleanServerIds(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local output = {}
    seen[value] = output
    for key, child in pairs(value) do
        if key ~= "id" then output[key] = cleanServerIds(child, seen) end
    end
    return output
end

local function deepEqual(left, right, seen)
    if type(left) ~= type(right) then
        return sameScalar(left, right)
    end
    if type(left) ~= "table" then return sameScalar(left, right) end
    seen = seen or {}
    if seen[left] == right then return true end
    seen[left] = right
    for key, value in pairs(left) do
        if right[key] == nil and value ~= nil then return false end
        if not deepEqual(value, right[key], seen) then return false end
    end
    for key, value in pairs(right) do
        if left[key] == nil and value ~= nil then return false end
    end
    return true
end

function Exactness.sameScalar(left, right)
    return sameScalar(left, right)
end

function Exactness.equalRecords(left, right)
    return deepEqual(cleanServerIds(left or {}), cleanServerIds(right or {}))
end

function Exactness.equalExactRecords(left, right)
    return deepEqual(left or {}, right or {})
end

function Exactness.displayedDescription(value, htmlToPlainText, fixUtf8)
    if type(value) ~= "string" or value == "" then return nil end
    local plain = htmlToPlainText(value)
    if #plain <= 400 then return plain end
    local shortened = plain:sub(1, 400):gsub("%s+%S*$", "")
    return fixUtf8(shortened) .. "…"
end

function Exactness.expectedSearchIds(descriptors, query)
    local needle = tostring(query or ""):lower()
    local output = {}
    for _, descriptor in ipairs(descriptors or {}) do
        local metadata = descriptor.expectedKoreaderMetadata or {}
        local authors = type(metadata.authors) == "table"
            and table.concat(metadata.authors, " "):lower() or ""
        if tostring(metadata.title or ""):lower():find(needle, 1, true)
                or authors:find(needle, 1, true)
                or tostring(metadata.seriesName or ""):lower():find(needle, 1, true) then
            output[#output + 1] = tostring(descriptor.serverBookId)
        end
    end
    return output
end

function Exactness.resultIds(itemTable)
    local output = {}
    for _, item in ipairs(itemTable or {}) do
        if item.book_data and item.book_data.id ~= nil then
            output[#output + 1] = tostring(item.book_data.id)
        end
    end
    return output
end

function Exactness.detailGenreSequence(categories, tags)
    local output, seen = { "Genres" }, {}
    local function collect(values)
        for _, value in ipairs(values or {}) do
            if type(value) == "string" and value ~= "" then
                local key = value:lower()
                if not seen[key] and #output <= 12 then
                    seen[key] = true
                    output[#output + 1] = value
                end
            end
        end
    end
    collect(categories)
    collect(tags)
    if #output == 1 then return {} end
    return output
end

function Exactness.recommendationProjection(book)
    local metadata = book and book.metadata or {}
    return {
        id = book and book.id and tostring(book.id) or nil,
        title = metadata.title,
        authors = metadata.authors or {},
        seriesName = metadata.seriesName,
    }
end

function Exactness.expectedRecommendationProjection(recommendation, descriptors)
    local matching
    for _, descriptor in ipairs(descriptors or {}) do
        local metadata = descriptor.expectedKoreaderMetadata or {}
        if metadata.title == recommendation.title then
            if matching then return nil end
            matching = descriptor
        end
    end
    if not matching then return nil end
    return {
        id = tostring(matching.serverBookId),
        title = recommendation.title,
        authors = recommendation.authors or {},
        seriesName = recommendation.seriesName,
    }
end

function Exactness.reviewDisplaySequence(reviews, fixUtf8)
    local output = {}
    local shown = math.min(3, #(reviews or {}))
    for index = 1, shown do
        local review = reviews[index]
        local who = review.reviewerName or review.metadataProvider or "Anonymous"
        local head = who
        if review.rating ~= nil then
            head = head .. "  " .. tostring(review.rating):gsub("%.0$", "") .. "/5"
        end
        output[#output + 1] = head
        if review.spoiler == true then
            output[#output + 1] = "This review contains spoilers."
            output[#output + 1] = "Reveal"
        else
            if type(review.title) == "string" and review.title ~= "" then
                output[#output + 1] = review.title
            end
            output[#output + 1] = fixUtf8(tostring(review.body or ""):sub(1, 300))
        end
    end
    if #(reviews or {}) > 3 then
        output[#output + 1] = "+" .. tostring(#reviews - 3) .. " more reviews"
    end
    return output
end

-- Strip only elements whose HTML default is unambiguously inline. Everything
-- else, including unknown/custom elements, remains part of the exact indexed
-- leaf-block identity. This is deliberately conservative: a false rejection
-- is safer than allowing two engines to serialize a cross-block range
-- differently and then normalizing away the mismatch.
local INLINE_TAGS = {
    a = true, abbr = true, b = true, bdi = true, bdo = true,
    cite = true, code = true, data = true, dfn = true, em = true,
    font = true, i = true, kbd = true, mark = true, q = true,
    rp = true, rt = true, ruby = true, s = true, samp = true,
    small = true, span = true, strong = true, sub = true, sup = true,
    time = true, u = true, var = true,
}

local function parsedXPointerLeaf(xpointer)
    if type(xpointer) ~= "string" or xpointer:sub(1, 1) ~= "/" then return nil end
    local text_path, removed_offsets = xpointer:gsub("%.[0-9]+$", "")
    if removed_offsets ~= 1 then return nil end
    local segments = {}
    for segment in text_path:gmatch("[^/]+") do
        segments[#segments + 1] = segment
    end
    if segments[1] ~= "body"
            or not tostring(segments[2]):match("^DocFragment%[%d+%]$") then
        return nil
    end
    local terminal = segments[#segments]
    if terminal ~= "text()" and not tostring(terminal):match("^text%(%)%[%d+%]$") then
        return nil
    end
    table.remove(segments)
    local inline_suffix = {}
    while #segments > 0 do
        local segment = segments[#segments]
        local tag = segment:match("^([%a][%w:_-]*)")
        tag = tag and tag:lower() or nil
        if not (tag and INLINE_TAGS[tag]) then break end
        table.insert(inline_suffix, 1, table.remove(segments))
    end
    if #segments == 0 then return nil end
    return {
        textNodePath = text_path,
        blockPath = "/" .. table.concat(segments, "/"),
        inlineSuffix = inline_suffix,
    }
end

function Exactness.selectionTopology(start_pos, end_pos)
    local start_leaf = parsedXPointerLeaf(start_pos)
    local end_leaf = parsedXPointerLeaf(end_pos)
    local start_path = start_leaf and start_leaf.textNodePath or nil
    local end_path = end_leaf and end_leaf.textNodePath or nil
    local start_block = start_leaf and start_leaf.blockPath or nil
    local end_block = end_leaf and end_leaf.blockPath or nil
    local crosses_text_node = start_path ~= nil and end_path ~= nil and start_path ~= end_path
    local start_inline_path = start_leaf
        and table.concat(start_leaf.inlineSuffix, "/") or nil
    local end_inline_path = end_leaf
        and table.concat(end_leaf.inlineSuffix, "/") or nil
    local inline_ancestry_differs = start_inline_path ~= nil
        and end_inline_path ~= nil and start_inline_path ~= end_inline_path
    local same_block = start_block ~= nil and start_block == end_block
    return {
        startTextNodePath = start_path,
        endTextNodePath = end_path,
        startBlockPath = start_block,
        endBlockPath = end_block,
        startInlineSuffix = start_leaf and start_leaf.inlineSuffix or {},
        endInlineSuffix = end_leaf and end_leaf.inlineSuffix or {},
        startInlinePath = start_inline_path,
        endInlinePath = end_inline_path,
        sameRenderedBlock = same_block,
        crossesTextNodeBoundary = crosses_text_node,
        crossesInlineBoundary = crosses_text_node and inline_ancestry_differs,
        acceptsSameBlockInlineSelection = same_block and crosses_text_node
            and inline_ancestry_differs,
    }
end

function Exactness.isPlausibleSingleBlockSelectionText(value)
    return type(value) == "string" and #value >= 5 and #value <= 500
        and value:match("%S") ~= nil and value:find("%c") == nil
end

function Exactness.containsOrderedExact(texts, expected)
    local cursor = 1
    for _, value in ipairs(texts or {}) do
        if value == expected[cursor] then cursor = cursor + 1 end
    end
    return cursor == #expected + 1
end

return Exactness
