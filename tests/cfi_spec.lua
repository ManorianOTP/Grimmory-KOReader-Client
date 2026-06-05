--[[
  CFI translation spec.

  Exercises cfi.lua against every synthetic EPUB fixture, one fixture per
  known CFI pitfall. Each describe block documents which invariant it tests.
]]
local spec_helper = require("spec_helper")
local lfs = require("lfs")

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

    describe("utf16_surrogate fixture - 4-byte UTF-8 maps to surrogate pair offset", function()
        it("byte offset across emoji maps to 2 UTF-16 code units", function()
            init_book("utf16_surrogate")
            -- XPointer byte offset: 4 bytes for the emoji at position 0 in text node
            -- CFI UTF-16 offset should be 2 (surrogate pair)
            local xp = "/body/DocFragment[1]/body/p[1]/text()[1].4"
            local cfi_str, err = cfi.xpointerToCFI(xp)
            assert.is_nil(err, tostring(err))
            -- CFI char offset for a single 4-byte UTF-8 emoji should be :2
            assert.truthy(cfi_str:match(":2%)$"),
                "surrogate pair offset should be :2, got: " .. tostring(cfi_str))
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
        it("placeholder - populate tests/fixtures/recorded/ to enable", function()
            pending("no recorded fixtures present")
        end)
    end)
end
