--[[
  Pure view engine for the Grimmory library browser.

  No require of any ui/*, no gettext, no globals.
  Labels are raw English; main.lua wraps them in _().

  Public API
  ----------
  view.SORTS[key]       sort descriptor table
  view.DIMENSIONS[key]  filter dimension descriptor table

  view.applySort(books, sort_desc)           -> new array
  view.applyFilters(books, view_state)       -> new array
  view.applyView(base_set, view_state)       -> new array
  view.computeFacetCounts(base_set, view_state, dim_key)
      -> { ordered = {{value, label, count}, ...} }
  view.activeFilterCount(view_state)         -> integer
  view.isDimensionPresent(base_set, key)     -> bool
]]

local view = {}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local function book_meta(book)
    return book.metadata or {}
end

-- Decorate-sort-undecorate: builds {book, idx, key} triples, sorts, strips.
-- nil keys sort after all non-nil keys in both directions.
local function dsu_sort(books, key_fn, dir)
    local decorated = {}
    for i, book in ipairs(books) do
        decorated[i] = { book = book, idx = i, key = key_fn(book) }
    end

    table.sort(decorated, function(a, b)
        local ka, kb = a.key, b.key
        -- nil sinks last in both directions
        if ka == nil and kb == nil then return a.idx < b.idx end
        if ka == nil then return false end
        if kb == nil then return true end
        if ka == kb then return a.idx < b.idx end
        if dir == "desc" then
            return ka > kb
        else
            return ka < kb
        end
    end)

    local result = {}
    for i, d in ipairs(decorated) do
        result[i] = d.book
    end
    return result
end

-- Zero-pad a number to 6 digits for lexicographic numeric comparison.
local function pad6(n)
    if type(n) ~= "number" then return "999999" end
    return string.format("%06d", math.max(0, math.min(999999, math.floor(n))))
end

-- Build a compound sort key: series (alpha) + zero-padded series number + title.
local function compound_series_key(book)
    local meta = book_meta(book)
    local s = meta.seriesName
    local n = meta.seriesNumber
    local t = meta.title
    if not s or s == "" then
        return nil  -- dsu_sort nil-sinks in both directions
    end
    return s:lower() .. "\x00" .. pad6(n) .. "\x00" .. (t and t:lower() or "")
end

local function compound_author_series_key(book)
    local meta = book_meta(book)
    local authors = meta.authors
    if type(authors) ~= "table" or #authors == 0 then
        return nil  -- no author: sink last in both directions
    end
    local first_author = (authors[1] or ""):lower()
    return first_author .. "\x00" .. (compound_series_key(book) or "")
end

-- Extract 4-digit year string from a publishedDate field (e.g. "1999-07-08").
local function year_from_date(book)
    local meta = book_meta(book)
    local d = meta.publishedDate
    if not d then return nil end
    local y = d:match("^(%d%d%d%d)")
    if not y then return nil end
    return tonumber(y)
end

-- ---------------------------------------------------------------------------
-- Bucket helpers (exposed on dimension descriptors)
-- ---------------------------------------------------------------------------

local function bucket_page_count(book)
    local meta = book_meta(book)
    local n = meta.pageCount
    if type(n) ~= "number" then return nil end
    if n < 100   then return "<100"      end
    if n < 300   then return "100-299"   end
    if n < 500   then return "300-499"   end
    if n < 1000  then return "500-999"   end
    return "1000+"
end

local function bucket_file_size(book)
    local kb = book.fileSizeKb
    if type(kb) ~= "number" then return nil end
    local mb = kb / 1024
    if mb < 1  then return "<1 MB"   end
    if mb < 5  then return "1-5 MB"  end
    if mb < 20 then return "5-20 MB" end
    return "20 MB+"
end

local function bucket_published_year(book)
    local y = year_from_date(book)
    if not y then return nil end
    if y >= 2020 then return "2020s"   end
    if y >= 2010 then return "2010s"   end
    if y >= 2000 then return "2000s"   end
    if y >= 1990 then return "1990s"   end
    return "Pre-1990"
end

-- External ratings (Amazon, Goodreads, Hardcover) are on a 0-5 scale.
-- Cumulative threshold buckets: 4+, 3+, 2+, Any rated.
local function bucket_external_rating(r)
    if type(r) ~= "number" then return nil end
    if r >= 4 then return "4+"        end
    if r >= 3 then return "3+"        end
    if r >= 2 then return "2+"        end
    return "Any rated"
end

-- Personal rating is 0-10. Thresholds: 8+, 6+, 4+, Rated, Unrated.
local function bucket_personal_rating(book)
    local r = book.personalRating
    if type(r) ~= "number" or r == 0 then return "Unrated" end
    if r >= 8 then return "8+"    end
    if r >= 6 then return "6+"    end
    if r >= 4 then return "4+"    end
    return "Rated"
end

-- ---------------------------------------------------------------------------
-- SORTS registry
-- ---------------------------------------------------------------------------

view.SORTS = {}

local function def_sort(key, label, tier, kind, get_fn)
    view.SORTS[key] = { key = key, label = label, tier = tier, kind = kind, get = get_fn }
end

-- Essential sorts
def_sort("title", "Title", "essential", "string", function(book)
    local t = book_meta(book).title
    return t and t:lower() or nil
end)

def_sort("title_series", "Title + Series", "essential", "string", function(book)
    return compound_series_key(book)
end)

def_sort("author", "Author", "essential", "string", function(book)
    local meta = book_meta(book)
    local a = meta.authors
    if type(a) == "table" and #a > 0 then
        return (a[1] or ""):lower()
    end
    return nil
end)

def_sort("last_read", "Last Read", "essential", "date", function(book)
    return book.lastReadAt
end)

def_sort("added_on", "Added On", "essential", "date", function(book)
    return book.createdAt
end)

def_sort("personal_rating", "Personal Rating", "essential", "number", function(book)
    local r = book.personalRating
    if type(r) == "number" and r > 0 then return r end
    return nil
end)

def_sort("pages", "Pages", "essential", "number", function(book)
    return book_meta(book).pageCount
end)

def_sort("random", "Random", "essential", "random", function(book)
    return nil  -- resolved at sort-time via _seed decoration
end)

-- Advanced sorts
def_sort("author_series", "Author + Series", "advanced", "string", function(book)
    return compound_author_series_key(book)
end)

def_sort("file_name", "File Name", "advanced", "string", function(book)
    local fn = book.fileName
    return fn and fn:lower() or nil
end)

def_sort("file_size", "File Size", "advanced", "number", function(book)
    return book.fileSizeKb
end)

def_sort("publisher", "Publisher", "advanced", "string", function(book)
    local p = book_meta(book).publisher
    return p and p:lower() or nil
end)

def_sort("published_date", "Published Date", "advanced", "date", function(book)
    return book_meta(book).publishedDate
end)

def_sort("amazon_rating", "Amazon Rating", "advanced", "number", function(book)
    return book_meta(book).amazonRating
end)

def_sort("amazon_count", "Amazon #", "advanced", "number", function(book)
    return book_meta(book).amazonReviewCount
end)

def_sort("goodreads_rating", "Goodreads Rating", "advanced", "number", function(book)
    return book_meta(book).goodreadsRating
end)

def_sort("goodreads_count", "Goodreads #", "advanced", "number", function(book)
    return book_meta(book).goodreadsReviewCount
end)

def_sort("hardcover_rating", "Hardcover Rating", "advanced", "number", function(book)
    return book_meta(book).hardcoverRating
end)

def_sort("hardcover_count", "Hardcover #", "advanced", "number", function(book)
    return book_meta(book).hardcoverReviewCount
end)

-- Conditional (registered, shown only if isDimensionPresent)
def_sort("locked", "Locked", "advanced", "number", function(book)
    if book.locked then return 1 else return 0 end
end)

-- ---------------------------------------------------------------------------
-- DIMENSIONS registry
-- ---------------------------------------------------------------------------

view.DIMENSIONS = {}

local function def_dim(key, label, tier, values_fn, format_fn, bucket_order)
    view.DIMENSIONS[key] = {
        key          = key,
        label        = label,
        tier         = tier,
        multi        = true,
        values       = values_fn,
        format       = format_fn or function(v) return v end,
        bucket_order = bucket_order,
    }
end

-- Essential filter dimensions
def_dim("author", "Author", "essential",
    function(book)
        local meta = book_meta(book)
        local authors = meta.authors
        if type(authors) ~= "table" then return {} end
        local out = {}
        for _, a in ipairs(authors) do
            if a and a ~= "" then out[#out+1] = a end
        end
        return out
    end
)

def_dim("genre", "Genre", "essential",
    function(book)
        local meta = book_meta(book)
        local cats = meta.categories
        if type(cats) ~= "table" then return {} end
        local out = {}
        for _, c in ipairs(cats) do
            if c and c ~= "" then out[#out+1] = c end
        end
        return out
    end
)

def_dim("series", "Series", "essential",
    function(book)
        local meta = book_meta(book)
        local s = meta.seriesName
        if s and s ~= "" then return {s} end
        return {}
    end
)

def_dim("readStatus", "Read Status", "essential",
    function(book)
        local s = book.readStatus
        if s and s ~= "" then return {s} end
        return {}
    end
)

def_dim("publisher", "Publisher", "essential",
    function(book)
        local p = book_meta(book).publisher
        if p and p ~= "" then return {p} end
        return {}
    end
)

def_dim("language", "Language", "essential",
    function(book)
        local l = book_meta(book).language
        if l and l ~= "" then return {l} end
        return {}
    end
)

-- Advanced filter dimensions
def_dim("personal_rating", "Personal Rating", "advanced",
    function(book)
        local b = bucket_personal_rating(book)
        if b then return {b} end
        return {}
    end,
    nil,
    { ["8+"] = 1, ["6+"] = 2, ["4+"] = 3, ["Rated"] = 4, ["Unrated"] = 5 }
)

def_dim("published_year", "Published Year", "advanced",
    function(book)
        local b = bucket_published_year(book)
        if b then return {b} end
        return {}
    end,
    nil,
    { ["2020s"] = 1, ["2010s"] = 2, ["2000s"] = 3, ["1990s"] = 4, ["Pre-1990"] = 5 }
)

def_dim("book_type", "Book Type", "advanced",
    function(book)
        local t = book.bookType or book_meta(book).bookType
        if t and t ~= "" then return {t} end
        return {}
    end
)

def_dim("shelf_status", "Shelf Status", "advanced",
    function(book)
        if type(book.shelves) == "table" and #book.shelves > 0 then
            return {"Shelved"}
        end
        return {"Unshelved"}
    end
)

def_dim("file_size", "File Size", "advanced",
    function(book)
        local b = bucket_file_size(book)
        if b then return {b} end
        return {}
    end,
    nil,
    { ["<1 MB"] = 1, ["1-5 MB"] = 2, ["5-20 MB"] = 3, ["20 MB+"] = 4 }
)

def_dim("page_count", "Page Count", "advanced",
    function(book)
        local b = bucket_page_count(book)
        if b then return {b} end
        return {}
    end,
    nil,
    { ["<100"] = 1, ["100-299"] = 2, ["300-499"] = 3, ["500-999"] = 4, ["1000+"] = 5 }
)

def_dim("amazon_rating", "Amazon Rating", "advanced",
    function(book)
        local r = book_meta(book).amazonRating
        local b = bucket_external_rating(r)
        if b then return {b} end
        return {}
    end,
    nil,
    { ["4+"] = 1, ["3+"] = 2, ["2+"] = 3, ["Any rated"] = 4 }
)

def_dim("goodreads_rating", "Goodreads Rating", "advanced",
    function(book)
        local r = book_meta(book).goodreadsRating
        local b = bucket_external_rating(r)
        if b then return {b} end
        return {}
    end,
    nil,
    { ["4+"] = 1, ["3+"] = 2, ["2+"] = 3, ["Any rated"] = 4 }
)

-- Conditional (registered, shown only if isDimensionPresent)
def_dim("metadata_match_score", "Metadata Match Score", "advanced",
    function(book)
        local s = book.metadataMatchScore
        if type(s) == "number" then return {tostring(s)} end
        return {}
    end
)

-- ---------------------------------------------------------------------------
-- applySort
-- ---------------------------------------------------------------------------

function view.applySort(books, sort_desc)
    if not sort_desc then
        sort_desc = { key = "title", dir = "asc" }
    end
    local key  = sort_desc.key  or "title"
    local dir  = sort_desc.dir  or "asc"
    local seed = sort_desc._seed

    local sd = view.SORTS[key]
    if not sd then
        sd = view.SORTS["title"]
    end

    if sd.kind == "random" then
        -- Assign one decoration value per book up-front using the stored seed.
        -- This ensures re-renders with the same seed produce the same order.
        local state = seed or 12345
        local function lcg()
            state = (state * 1103515245 + 12345) % 2147483648
            return state
        end
        local decorated = {}
        for i, book in ipairs(books) do
            decorated[i] = { book = book, idx = i, rnd = lcg() }
        end
        table.sort(decorated, function(a, b)
            if a.rnd == b.rnd then return a.idx < b.idx end
            return a.rnd < b.rnd
        end)
        local result = {}
        for i, d in ipairs(decorated) do result[i] = d.book end
        return result
    end

    return dsu_sort(books, sd.get, dir)
end

-- ---------------------------------------------------------------------------
-- applyFilters
-- ---------------------------------------------------------------------------

-- Returns true if a single book passes the filter for one dimension.
-- Within a dimension, values are OR-ed.
local function book_matches_dim(book, dim_key, selected_values)
    local dim = view.DIMENSIONS[dim_key]
    if not dim then return true end
    local book_values = dim.values(book)
    for _, bv in ipairs(book_values) do
        if selected_values[bv] then return true end
    end
    return false
end

function view.applyFilters(books, vs)
    if not vs or not vs.filters then return books end
    local filters = vs.filters
    local combine = vs.combine or "AND"

    -- Collect active dimensions (those with at least one selected value)
    local active_dims = {}
    for dim_key, selected in pairs(filters) do
        local has_any = false
        for _, v in pairs(selected) do
            if v then has_any = true; break end
        end
        if has_any then
            active_dims[#active_dims+1] = dim_key
        end
    end

    if #active_dims == 0 then return books end

    local result = {}
    for _, book in ipairs(books) do
        local matches
        if combine == "OR" then
            matches = false
            for _, dim_key in ipairs(active_dims) do
                if book_matches_dim(book, dim_key, filters[dim_key]) then
                    matches = true
                    break
                end
            end
        else  -- AND
            matches = true
            for _, dim_key in ipairs(active_dims) do
                if not book_matches_dim(book, dim_key, filters[dim_key]) then
                    matches = false
                    break
                end
            end
        end
        if matches then result[#result+1] = book end
    end
    return result
end

-- ---------------------------------------------------------------------------
-- applyView
-- ---------------------------------------------------------------------------

function view.applyView(base_set, vs)
    local filtered = view.applyFilters(base_set, vs)
    local sort_desc = vs and vs.sort or nil
    return view.applySort(filtered, sort_desc)
end

-- ---------------------------------------------------------------------------
-- computeFacetCounts
-- ---------------------------------------------------------------------------

function view.computeFacetCounts(base_set, vs, dim_key)
    local dim = view.DIMENSIONS[dim_key]
    if not dim then return { ordered = {} } end

    -- Build a modified view_state that strips out this dimension's own filter
    -- so counts reflect other-dim filtering only.
    local vs2 = { combine = (vs and vs.combine or "AND"), filters = {} }
    if vs and vs.filters then
        for k, v in pairs(vs.filters) do
            if k ~= dim_key then
                vs2.filters[k] = v
            end
        end
    end

    -- Filter the base set by all dimensions except the queried one.
    local candidate_set = view.applyFilters(base_set, vs2)

    -- Count occurrences of each value in the candidate set.
    local counts = {}
    for _, book in ipairs(candidate_set) do
        local bvals = dim.values(book)
        for _, bv in ipairs(bvals) do
            counts[bv] = (counts[bv] or 0) + 1
        end
    end

    -- Collect and sort (alpha by value key).
    local ordered = {}
    for val, cnt in pairs(counts) do
        if cnt > 0 then
            ordered[#ordered+1] = {
                value = val,
                label = dim.format(val),
                count = cnt,
            }
        end
    end
    local bo = dim.bucket_order
    if bo then
        table.sort(ordered, function(a, b)
            local ra = bo[a.value] or math.huge
            local rb = bo[b.value] or math.huge
            if ra ~= rb then return ra < rb end
            return a.value < b.value
        end)
    else
        table.sort(ordered, function(a, b) return a.value < b.value end)
    end

    return { ordered = ordered }
end

-- ---------------------------------------------------------------------------
-- activeFilterCount
-- ---------------------------------------------------------------------------

function view.activeFilterCount(vs)
    if not vs or not vs.filters then return 0 end
    local n = 0
    for _, selected in pairs(vs.filters) do
        for _, v in pairs(selected) do
            if v then n = n + 1 end
        end
    end
    return n
end

-- ---------------------------------------------------------------------------
-- isDimensionPresent
-- ---------------------------------------------------------------------------

function view.isDimensionPresent(base_set, key)
    local dim = view.DIMENSIONS[key]
    if not dim then
        -- For sort keys (e.g. "locked"), check the book field directly.
        for _, book in ipairs(base_set) do
            if book[key] ~= nil then return true end
        end
        return false
    end
    for _, book in ipairs(base_set) do
        local vals = dim.values(book)
        if #vals > 0 then return true end
    end
    return false
end

return view
