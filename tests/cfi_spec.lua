--[[
  CFI translation spec.

  Exercises cfi.lua against every synthetic EPUB fixture, one fixture per
  known CFI pitfall. Each describe block documents which invariant it tests.
]]
local spec_helper = require("spec_helper")
local lfs = require("lfs")
local json = require("json")

local cfi

local FIXTURES = REPO_ROOT .. "/tests/fixtures/synthetic"

local function make_reader(dir)
    return spec_helper.make_reader(dir)
end

local function init_book(fixture_name, chapter)
    local dir = FIXTURES .. "/" .. fixture_name
    local reader = make_reader(dir)
    local ok, err = cfi.initBook(dir, reader)
    assert.is_nil(err, "initBook error for " .. fixture_name .. ": " .. tostring(err))
    assert.is_truthy(ok)
    return reader
end

describe("cfi.lua", function()
    before_each(function()
        spec_helper.setup()
        cfi = require("cfi")
    end)

    after_each(function()
        if cfi then cfi.clearCache() end
        spec_helper.teardown()
    end)

    describe("minimal fixture - happy path round-trip", function()
        it("xpointerToCFI and cfiToXPointer are inverse for a simple XPointer", function()
            init_book("minimal")
            -- Canonical XPointer form: /text()[1] is required for crengine on reverse direction.
            local xp = "/body/DocFragment[1]/body/p[1]/text()[1].5"
            local cfi_str, err = cfi.xpointerToCFI(xp)
            assert.is_nil(err, tostring(err))
            assert.is_string(cfi_str)
            assert.truthy(cfi_str:match("^epubcfi%("))
            local xp2, err2 = cfi.cfiToXPointer(cfi_str)
            assert.is_nil(err2, tostring(err2))
            assert.equals(xp, xp2)
        end)

        it("round-trips a same-node highlight range", function()
            init_book("minimal")
            local pos0 = "/body/DocFragment[1]/body/p[1]/text()[1].1"
            local pos1 = "/body/DocFragment[1]/body/p[1]/text()[1].7"
            local range, err = cfi.xpointerRangeToCFI(pos0, pos1)
            assert.is_nil(err, tostring(err))
            assert.matches("^epubcfi%(.+,.+,.+%)$", range)
            local actual0, actual1, reverse_err = cfi.cfiRangeToXPointers(range)
            assert.is_nil(reverse_err, tostring(reverse_err))
            assert.equals(pos0, actual0)
            assert.equals(pos1, actual1)
        end)

        it("navigates an epub.js page-range progress CFI from its first endpoint", function()
            init_book("minimal")
            local first_xp = "/body/DocFragment[1]/body/p[1]/text()[1].2"
            local last_xp = "/body/DocFragment[1]/body/p[1]/text()[1].8"
            local first = assert(cfi.xpointerToCFI(first_xp))
            local last = assert(cfi.xpointerToCFI(last_xp))
            local range = assert(cfi.asRange(first, last))

            local resolved, err = cfi.cfiToXPointer(range)

            assert.is_nil(err, tostring(err))
            assert.equals(first_xp, resolved)
            local element_anchor = first:gsub("/1:%d+%)$", ")")
            assert.equals(
                "/body/DocFragment[1]/body/p[1]/text()[1].0",
                assert(cfi.cfiToXPointer(element_anchor)),
                "element anchors must use CREngine's exact canonical text target")

            local literal_start, literal_end = cfi.splitRange(
                "epubcfi(/6/22!/4/2[chapter-11],/2,/30[p12]/1:426)")
            assert.equals("epubcfi(/6/22!/4/2[chapter-11]/2)", literal_start)
            assert.equals(
                "epubcfi(/6/22!/4/2[chapter-11]/30[p12]/1:426)",
                literal_end)
            local annotation_start, annotation_end = cfi.splitRange(
                "epubcfi(/6/16!/4/2[chapter-8]/2,/1:0,/1:24)")
            assert.equals(
                "epubcfi(/6/16!/4/2[chapter-8]/2/1:0)", annotation_start)
            assert.equals(
                "epubcfi(/6/16!/4/2[chapter-8]/2/1:24)", annotation_end)
            local empty_start, pagebreak_end = cfi.splitRange(
                "epubcfi(/6/4!/4/2,,/4[calibre_pb_0])")
            assert.equals("epubcfi(/6/4!/4/2)", empty_start)
            assert.equals(
                "epubcfi(/6/4!/4/2/4[calibre_pb_0])", pagebreak_end)
            local asserted_root, asserted_end = cfi.splitRange(
                "epubcfi(/6/4!/4/2[id144],,/8/2)")
            assert.equals("epubcfi(/6/4!/4/2[id144])", asserted_root)
            assert.equals("epubcfi(/6/4!/4/2[id144]/8/2)", asserted_end)
        end)

        it("round-trips a range spanning element siblings", function()
            init_book("whitespace")
            local pos0 = "/body/DocFragment[1]/body/p[1]/text()[1].2"
            local pos1 = "/body/DocFragment[1]/body/p[2]/text()[1].3"
            local range = assert(cfi.xpointerRangeToCFI(pos0, pos1))
            local actual0, actual1 = cfi.cfiRangeToXPointers(range)
            assert.equals(pos0, actual0)
            assert.equals(pos1, actual1)
        end)
    end)

    describe("whitespace fixture - SLAXML stripWhitespace invariant", function()
        it("indentation between elements does not advance child indices", function()
            init_book("whitespace")
            -- Second paragraph is still p[2] even with whitespace between paragraphs
            local xp = "/body/DocFragment[1]/body/p[2]/text()[1].0"
            local cfi_str, err = cfi.xpointerToCFI(xp)
            assert.is_nil(err, tostring(err))
            -- Verify round-trip: if stripWhitespace is broken, p[2] would be
            -- computed at wrong CFI index and the reverse walk would differ.
            local xp2, err2 = cfi.cfiToXPointer(cfi_str)
            assert.is_nil(err2, tostring(err2))
            assert.equals(xp, xp2)
        end)
    end)

    describe("body_index fixture - body offset computed by walking html children", function()
        it("body CFI step is correct even when body is not the first child of html", function()
            init_book("body_index")
            local xp = "/body/DocFragment[1]/body/p[1]/text()[1].3"
            local cfi_str, err = cfi.xpointerToCFI(xp)
            assert.is_nil(err, tostring(err))
            -- body appears after head in the XHTML; its CFI index must be > 2
            assert.truthy(cfi_str:match("/[46]/%d"), "body CFI index should be >= 4")
            local xp2, err2 = cfi.cfiToXPointer(cfi_str)
            assert.is_nil(err2, tostring(err2))
            assert.equals(xp, xp2)
        end)
    end)

    describe("text_node fixture - crengine text()[N] requirement on reverse sync", function()
        it("cfiToXPointer emits /text()[1] before the char offset", function()
            init_book("text_node")
            local xp = "/body/DocFragment[1]/body/p[1]/text()[1].4"
            local cfi_str, err = cfi.xpointerToCFI(xp)
            assert.is_nil(err, tostring(err))
            local xp2, err2 = cfi.cfiToXPointer(cfi_str)
            assert.is_nil(err2, tostring(err2))
            -- Must round-trip with explicit text()[1] selector
            assert.truthy(xp2:match("/text%(%)%[1%]%.%d+$"),
                "reverse XPointer must contain /text()[1].N suffix, got: " .. tostring(xp2))
        end)
    end)

    describe("utf16_surrogate fixture - CREngine scalar maps to surrogate pair", function()
        it("maps one CREngine emoji position to two UTF-16 code units", function()
            init_book("utf16_surrogate")
            -- CREngine uses an lString32 scalar offset: the emoji occupies one
            -- XPointer position, while epub.js represents it as a surrogate pair.
            local xp = "/body/DocFragment[1]/body/p[1]/text()[1].1"
            local cfi_str, err = cfi.xpointerToCFI(xp)
            assert.is_nil(err, tostring(err))
            assert.truthy(cfi_str:match(":2%)$"),
                "surrogate pair offset should be :2, got: " .. tostring(cfi_str))
        end)

        it("round-trips a highlight whose endpoint follows an emoji", function()
            init_book("utf16_surrogate")
            local pos0 = "/body/DocFragment[1]/body/p[1]/text()[1].0"
            local pos1 = "/body/DocFragment[1]/body/p[1]/text()[1].1"
            local range = assert(cfi.xpointerRangeToCFI(pos0, pos1))
            local actual0, actual1 = cfi.cfiRangeToXPointers(range)
            assert.equals(pos0, actual0)
            assert.equals(pos1, actual1)
        end)

        it("rejects a CFI endpoint between an astral surrogate pair", function()
            init_book("utf16_surrogate")
            local after_emoji = assert(cfi.xpointerToCFI(
                "/body/DocFragment[1]/body/p[1]/text()[1].1"))
            local inside_surrogate = after_emoji:gsub(":2%)$", ":1)")
            local xp, err = cfi.cfiToXPointer(inside_surrogate)
            assert.is_nil(xp)
            assert.matches("splits an astral surrogate pair", err)
        end)
    end)

    describe("unicode_offsets fixture - Kindle and Unicode scalar regressions", function()
        it("preserves the first literal Kindle smart-punctuation endpoint", function()
            init_book("unicode_offsets")
            local xp = "/body/DocFragment[1]/body/p[1]/text()[1].26"
            local cfi_str, err = cfi.xpointerToCFI(xp)
            assert.is_nil(err, tostring(err))
            assert.truthy(cfi_str:match(":26%)$"),
                "26 CREngine scalars must remain CFI :26, got: " .. tostring(cfi_str))
            assert.equals(xp, assert(cfi.cfiToXPointer(cfi_str)))
        end)

        it("preserves the second literal Kindle smart-punctuation endpoint", function()
            init_book("unicode_offsets")
            local xp = "/body/DocFragment[1]/body/p[2]/text()[1].19"
            local cfi_str, err = cfi.xpointerToCFI(xp)
            assert.is_nil(err, tostring(err))
            assert.truthy(cfi_str:match(":19%)$"),
                "19 CREngine scalars must remain CFI :19, got: " .. tostring(cfi_str))
            assert.equals(xp, assert(cfi.cfiToXPointer(cfi_str)))
        end)

        it("counts astral scalars and decomposed combining marks independently", function()
            init_book("unicode_offsets")
            local prefix_cases = {
                -- 😀 is one CREngine scalar but two UTF-16 units.
                { scalar = 1, utf16 = 2 },
                -- The base e is another scalar/unit.
                { scalar = 2, utf16 = 3 },
                -- U+0301 is a separate scalar/unit, not a grapheme count.
                { scalar = 3, utf16 = 4 },
            }
            for _, case in ipairs(prefix_cases) do
                local xp = "/body/DocFragment[1]/body/p[3]/text()[1]."
                    .. tostring(case.scalar)
                local cfi_str = assert(cfi.xpointerToCFI(xp))
                assert.truthy(cfi_str:match(":" .. tostring(case.utf16) .. "%)$"))
                assert.equals(xp, assert(cfi.cfiToXPointer(cfi_str)))
            end
        end)

        it("resolves a flattened Unicode offset through inline elements", function()
            init_book("unicode_offsets")
            -- Four scalars in “Hi , then emoji + e inside <em>. The local
            -- CREngine offset is 2 and the local CFI UTF-16 offset is 3.
            local parent_xp = "/body/DocFragment[1]/body/p[4].6"
            local cfi_str, err = cfi.xpointerToCFI(parent_xp)
            assert.is_nil(err, tostring(err))
            assert.truthy(cfi_str:match(":3%)$"), tostring(cfi_str))
            local resolved = assert(cfi.cfiToXPointer(cfi_str))
            assert.equals(
                "/body/DocFragment[1]/body/p[4]/em[1]/text()[1].2",
                resolved)
            assert.equals(cfi_str, assert(cfi.xpointerToCFI(resolved)))
        end)

        it("keeps an inline endpoint before its following punctuation tail", function()
            init_book("unicode_offsets")
            -- Authoritative real-book v5 shape: meaningful paragraph text,
            -- followed by one inline element, followed by punctuation text.
            -- EPUB CFI numbers that first element /2; /4 is the virtual point
            -- after it and would make Foliate include the punctuation tail.
            local pos0 = "/body/DocFragment[1]/body/p[5]/text()[1].0"
            local pos1 = "/body/DocFragment[1]/body/p[5]/span[1]/text()[1].5"
            local range = assert(cfi.xpointerRangeToCFI(pos0, pos1))

            assert.equals(
                "epubcfi(/6/2[chapter1]!/4/10,/1:0,/2/1:5)",
                range)
            assert.falsy(range:find("/4/1:5", 1, true),
                "the inline endpoint must not address Foliate's after-element slot")
            local actual0, actual1 = cfi.cfiRangeToXPointers(range)
            assert.equals(pos0, actual0)
            assert.equals(pos1, actual1)

            local stale_endpoint = range:gsub("/2/1:5", "/4/1:5")
            local stale0, stale1, stale_err =
                cfi.cfiRangeToXPointers(stale_endpoint)
            assert.is_nil(stale0)
            assert.is_nil(stale1)
            assert.matches("absolute index 4 not found", stale_err)

            -- CFI merges adjacent character-data nodes into one odd chunk.
            -- The comment makes SLAXML emit two meaningful text nodes; the
            -- second node's local offset 1 must include the first node's two
            -- units in forward conversion, then reverse to that exact node.
            local adjacent = "/body/DocFragment[1]/body/p[6]/text()[2].1"
            local adjacent_cfi = assert(cfi.xpointerToCFI(adjacent))
            assert.equals(
                "epubcfi(/6/2[chapter1]!/4/12/1:3)", adjacent_cfi)
            assert.equals(adjacent, assert(cfi.cfiToXPointer(adjacent_cfi)))
        end)
    end)

    describe("nested inline fixture - containing-element offsets", function()
        it("resolves a flattened parent offset into the descendant text node", function()
            init_book("nested_inline")
            -- Real-world CREngine output may put the offset on <p> even when
            -- the character lives inside a nested inline element. Offset 8 is
            -- two Unicode scalars into "messy", after six in "Hello ".
            local parent_xp = "/body/DocFragment[1]/body/p[1].8"
            local cfi_str, err = cfi.xpointerToCFI(parent_xp)
            assert.is_nil(err, tostring(err))
            local resolved_xp, reverse_err = cfi.cfiToXPointer(cfi_str)
            assert.is_nil(reverse_err, tostring(reverse_err))
            assert.equals(
                "/body/DocFragment[1]/body/p[1]/em[1]/text()[1].2",
                resolved_xp)
            assert.equals(cfi_str, assert(cfi.xpointerToCFI(resolved_xp)),
                "canonical descendant XPointer must preserve the same CFI")
        end)
    end)

    describe("mixed_siblings fixture - element indices skip text nodes", function()
        it("second element sibling has CFI index 4 even with interleaved text nodes", function()
            init_book("mixed_siblings")
            local xp = "/body/DocFragment[1]/body/p[2]/text()[1].0"
            local cfi_str, err = cfi.xpointerToCFI(xp)
            assert.is_nil(err, tostring(err))
            local xp2, err2 = cfi.cfiToXPointer(cfi_str)
            assert.is_nil(err2, tostring(err2))
            assert.equals(xp, xp2)
        end)
    end)

    describe("self_closing_anchor fixture - empty landmarks remain element siblings", function()
        it("canonicalises CREngine's .0 position on an empty element", function()
            init_book("self_closing_anchor")
            local cfi_str, err = cfi.xpointerToCFI(
                "/body/DocFragment[1]/body/a[1].0")
            assert.is_nil(err, tostring(err))
            local resolved_xp, reverse_err = cfi.cfiToXPointer(cfi_str)
            assert.is_nil(reverse_err, tostring(reverse_err))
            assert.equals("/body/DocFragment[1]/body/a[1]", resolved_xp)
        end)

        it("round-trips a paragraph after a self-closing anchor", function()
            init_book("self_closing_anchor")
            -- Derived minimal structure from the supplied EPUB: page landmarks may
            -- be serialized as empty anchors between ordinary content elements.
            local xp = "/body/DocFragment[1]/body/p[2]/text()[1].5"
            local cfi_str, err = cfi.xpointerToCFI(xp)
            assert.is_nil(err, tostring(err))
            local xp2, err2 = cfi.cfiToXPointer(cfi_str)
            assert.is_nil(err2, tostring(err2))
            assert.equals(xp, xp2)
        end)
    end)

    describe("multi_docfragment fixture - DocFragment SYNTHETIC stripping", function()
        it("DocFragment[2] resolves to second spine entry chapter2.xhtml", function()
            init_book("multi_docfragment")
            local xp = "/body/DocFragment[2]/body/p[1]/text()[1].0"
            local cfi_str, err = cfi.xpointerToCFI(xp)
            assert.is_nil(err, tostring(err))
            -- Spine index 2 -> CFI spine step 4
            assert.truthy(cfi_str:match("/6/4%["),
                "second DocFragment should produce spine step /6/4, got: " .. tostring(cfi_str))
            local xp2, err2 = cfi.cfiToXPointer(cfi_str)
            assert.is_nil(err2, tostring(err2))
            assert.equals(xp, xp2)
        end)
    end)
end)

-- Recorded lane: local-only, skipped when fixtures/recorded/ is absent.
local recorded_dir = REPO_ROOT .. "/tests/fixtures/recorded"
local recorded_attr = lfs.attributes(recorded_dir, "mode")
if recorded_attr == "directory" then
    describe("cfi.lua - recorded real-book fixtures", function()
        before_each(function()
            spec_helper.setup()
            cfi = require("cfi")
        end)
        after_each(function()
            if cfi then cfi.clearCache() end
            spec_helper.teardown()
        end)
        it("round-trips every populated real-book XPointer and CFI sample", function()
            local book_dirs = {}
            for entry in lfs.dir(recorded_dir) do
                if entry ~= "." and entry ~= ".." and
                   lfs.attributes(recorded_dir .. "/" .. entry, "mode") == "directory" then
                    table.insert(book_dirs, entry)
                end
            end
            table.sort(book_dirs)
            assert.is_true(#book_dirs > 0,
                "recorded fixture directory exists but contains no book directories")

            local sample_count = 0
            for _, book_id in ipairs(book_dirs) do
                local book_dir = recorded_dir .. "/" .. book_id
                local samples_path = book_dir .. "/samples.json"
                local handle, open_err = io.open(samples_path, "rb")
                assert.is_truthy(handle,
                    "cannot open " .. samples_path .. ": " .. tostring(open_err))
                local encoded = handle:read("*a")
                handle:close()
                local samples = json.decode(encoded)
                assert.equals("table", type(samples),
                    "invalid JSON object in " .. samples_path)
                assert.equals("table", type(samples.xpointers),
                    "missing xpointers array in " .. samples_path)
                assert.is_true(#samples.xpointers > 0,
                    "xpointers array is empty in " .. samples_path)

                cfi.clearCache()
                local reader = make_reader(book_dir)
                local ok, init_err = cfi.initBook(book_dir, reader)
                assert.is_nil(init_err, tostring(init_err))
                assert.is_truthy(ok)

                for index, sample in ipairs(samples.xpointers) do
                    local label = book_id .. " sample " .. tostring(index)
                    assert.equals("string", type(sample.xp), label .. " has no xp string")
                    assert.equals("string", type(sample.cfi), label .. " has no cfi string")
                    local converted_cfi, cfi_err = cfi.xpointerToCFI(sample.xp)
                    assert.is_nil(cfi_err, label .. ": " .. tostring(cfi_err))
                    assert.equals(sample.cfi, converted_cfi, label .. " XPointer -> CFI")
                    local converted_xp, xp_err = cfi.cfiToXPointer(sample.cfi)
                    assert.is_nil(xp_err, label .. ": " .. tostring(xp_err))
                    assert.equals(sample.xp, converted_xp, label .. " CFI -> XPointer")
                    sample_count = sample_count + 1
                end
            end
            assert.is_true(sample_count > 0, "no recorded CFI samples were exercised")
        end)
    end)
end
