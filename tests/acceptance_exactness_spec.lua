local Exactness = dofile("tests/emulator/acceptance_driver.koplugin/acceptance_exactness.lua")

describe("acceptance metadata exactness", function()
    it("rejects truncated and extra review fields", function()
        local expected = {{ reviewerName = "Reader", body = "complete body", rating = 5 }}
        assert.is_true(Exactness.equalRecords(
            {{ id = 91, reviewerName = "Reader", body = "complete body", rating = 5 }}, expected))
        assert.is_false(Exactness.equalRecords(
            {{ reviewerName = "Reader", body = "complete", rating = 5 }}, expected))
        assert.is_false(Exactness.equalRecords(
            {{ reviewerName = "Reader", body = "complete body", rating = 5, country = "extra" }}, expected))
    end)

    it("requires the complete normalized description rather than a prefix", function()
        local html = function(value) return value:gsub("<[^>]+>", "") end
        local fix = function(value) return value end
        local expected = Exactness.displayedDescription("<p>complete description ending</p>", html, fix)
        assert.are.equal("complete description ending", expected)
        assert.are_not.equal("complete description", expected)
    end)

    it("rejects extra and wrong-associated search results", function()
        local descriptors = {
            { serverBookId = 1, expectedKoreaderMetadata = { title = "Exact Book", authors = {"A"} } },
            { serverBookId = 2, expectedKoreaderMetadata = { title = "Other", authors = {"Exact Book Club"} } },
            { serverBookId = 3, expectedKoreaderMetadata = { title = "Unrelated", authors = {"B"} } },
        }
        local expected = Exactness.expectedSearchIds(descriptors, "Exact Book")
        assert.same({"1", "2"}, expected)
        assert.are_not.same(expected, Exactness.resultIds({
            { book_data = { id = 1 } }, { book_data = { id = 3 } },
        }))
        assert.are_not.same(expected, {"1", "2", "3"})
    end)

    it("binds recommendations to exact book records and ordered card text", function()
        local descriptors = {{
            serverBookId = 7,
            expectedKoreaderMetadata = { title = "Recommended", authors = {"One", "Two"}, seriesName = "S" },
        }}
        local expected = Exactness.expectedRecommendationProjection({
            title = "Recommended", authors = {"One", "Two"}, seriesName = "S",
        }, descriptors)
        assert.is_true(Exactness.equalExactRecords(Exactness.recommendationProjection({
            id = 7, metadata = { title = "Recommended", authors = {"One", "Two"}, seriesName = "S" },
        }), expected))
        assert.is_false(Exactness.equalExactRecords(Exactness.recommendationProjection({
            id = 8, metadata = { title = "Recommended", authors = {"Wrong"}, seriesName = "S" },
        }), expected))
        assert.is_true(Exactness.containsOrderedExact(
            {"Recommended", "One …", "Second", "Two"}, {"Recommended", "One …", "Second", "Two"}))
        assert.is_false(Exactness.containsOrderedExact(
            {"Recommended", "Two", "Second", "One …"}, {"Recommended", "One …", "Second", "Two"}))

        assert.same({"Genres", "Fantasy", "Epic", "Short"},
            Exactness.detailGenreSequence({"Fantasy", "Epic"}, {"fantasy", "Short"}))
        assert.are_not.same({"Genres", "Fantasy", "Epic", "Wrong"},
            Exactness.detailGenreSequence({"Fantasy", "Epic"}, {"fantasy", "Short"}))
    end)

    it("projects the exact live DTO genre sequence without inventing cache order", function()
        local exact = Exactness.detailGenreSequence(
            {"Zulu", "Alpha", "zulu", ""},
            {"Tag", "ALPHA", "Tail"})
        assert.same({"Genres", "Zulu", "Alpha", "Tag", "Tail"}, exact)

        -- The detail assertion is an exact array comparison: every common
        -- weakening must differ from the independently projected sequence.
        assert.are_not.same(exact,
            {"Genres", "Wrong", "Alpha", "Tag", "Tail"})
        assert.are_not.same(exact,
            {"Genres", "Alpha", "Zulu", "Tag", "Tail"})
        assert.are_not.same(exact,
            {"Genres", "Zulu", "Alpha", "Tag"})
        assert.are_not.same(exact,
            {"Genres", "Zulu", "Alpha", "Tag", "Tail", "Extra"})

        local categories, tags = {}, {}
        for index = 1, 8 do categories[index] = "Category " .. index end
        for index = 1, 8 do tags[index] = "Tag " .. index end
        local capped = Exactness.detailGenreSequence(categories, tags)
        assert.are.equal(13, #capped) -- label plus twelve chips
        assert.are.equal("Category 8", capped[9])
        assert.are.equal("Tag 4", capped[13])
        assert.is_nil(capped[14])
    end)

    it("accepts only same-block ranges that cross a genuine inline boundary", function()
        local paragraph = "/body/DocFragment[1]/body/div[1]/p[3]"
        local same_block = Exactness.selectionTopology(
            paragraph .. "/text()[1].4",
            paragraph .. "/em[1]/text()[1].9")
        assert.is_true(same_block.sameRenderedBlock)
        assert.is_true(same_block.crossesTextNodeBoundary)
        assert.is_true(same_block.crossesInlineBoundary)
        assert.is_true(same_block.acceptsSameBlockInlineSelection)
        assert.are.equal(same_block.startBlockPath, same_block.endBlockPath)

        local cross_block = Exactness.selectionTopology(
            paragraph .. "/strong[1]/text()[1].4",
            "/body/DocFragment[1]/body/div[1]/p[4]/text()[1].9")
        assert.is_false(cross_block.sameRenderedBlock)
        assert.is_true(cross_block.crossesInlineBoundary)
        assert.is_false(cross_block.acceptsSameBlockInlineSelection)
        assert.are_not.equal(cross_block.startBlockPath, cross_block.endBlockPath)

        local no_inline = Exactness.selectionTopology(
            paragraph .. "/text()[1].4",
            paragraph .. "/text()[2].9")
        assert.is_true(no_inline.sameRenderedBlock)
        assert.is_true(no_inline.crossesTextNodeBoundary)
        assert.is_false(no_inline.crossesInlineBoundary)
        assert.is_false(no_inline.acceptsSameBlockInlineSelection)

        local same_inline_parent = Exactness.selectionTopology(
            paragraph .. "/em[1]/text()[1].4",
            paragraph .. "/em[1]/text()[2].9")
        assert.is_true(same_inline_parent.sameRenderedBlock)
        assert.is_true(same_inline_parent.crossesTextNodeBoundary)
        assert.is_false(same_inline_parent.crossesInlineBoundary)
        assert.is_false(same_inline_parent.acceptsSameBlockInlineSelection)

        local paragraph_one = "/body/DocFragment[1]/body/div[1]/p[1]"
        local paragraph_ten = "/body/DocFragment[1]/body/div[1]/p[10]"
        local one_to_ten = Exactness.selectionTopology(
            paragraph_one .. "/span[1]/text()[1].0",
            paragraph_ten .. "/text()[1].5")
        assert.is_false(one_to_ten.sameRenderedBlock)
        assert.is_false(one_to_ten.acceptsSameBlockInlineSelection)
        assert.are_not.equal(one_to_ten.startBlockPath, one_to_ten.endBlockPath)

        local one_to_two = Exactness.selectionTopology(
            paragraph_one .. "/text()[1].0",
            "/body/DocFragment[1]/body/div[1]/p[2]/em[1]/text()[1].5")
        assert.is_false(one_to_two.sameRenderedBlock)
        assert.is_false(one_to_two.acceptsSameBlockInlineSelection)

        local fragment_one_to_ten = Exactness.selectionTopology(
            paragraph_one .. "/span[1]/text()[1].0",
            "/body/DocFragment[10]/body/div[1]/p[1]/text()[1].5")
        assert.is_false(fragment_one_to_ten.sameRenderedBlock)
        assert.is_false(fragment_one_to_ten.acceptsSameBlockInlineSelection)

        local sibling_li = Exactness.selectionTopology(
            "/body/DocFragment[1]/body/ul[1]/li[1]/text()[1].0",
            "/body/DocFragment[1]/body/ul[1]/li[1]/p[1]/em[1]/text()[1].5")
        assert.is_false(sibling_li.sameRenderedBlock)
        assert.is_false(sibling_li.acceptsSameBlockInlineSelection)

        local sibling_td = Exactness.selectionTopology(
            "/body/DocFragment[1]/body/table[1]/tr[1]/td[1]/p[1]/span[1]/text()[1].0",
            "/body/DocFragment[1]/body/table[1]/tr[1]/td[2]/p[1]/text()[1].5")
        assert.is_false(sibling_td.sameRenderedBlock)
        assert.is_false(sibling_td.acceptsSameBlockInlineSelection)

        local unknown_is_block = Exactness.selectionTopology(
            paragraph_one .. "/text()[1].0",
            paragraph_one .. "/custom-inline[1]/em[1]/text()[1].5")
        assert.is_false(unknown_is_block.sameRenderedBlock)
        assert.are.equal(paragraph_one .. "/custom-inline[1]",
            unknown_is_block.endBlockPath)
        assert.is_false(unknown_is_block.acceptsSameBlockInlineSelection)

        local missing_offset = Exactness.selectionTopology(
            paragraph_one .. "/text()[1]",
            paragraph_one .. "/em[1]/text()[1].5")
        assert.is_nil(missing_offset.startTextNodePath)
        assert.is_false(missing_offset.acceptsSameBlockInlineSelection)
        local missing_fragment = Exactness.selectionTopology(
            "/body/p[1]/text()[1].0",
            "/body/p[1]/em[1]/text()[1].5")
        assert.is_nil(missing_fragment.startBlockPath)
        assert.is_false(missing_fragment.acceptsSameBlockInlineSelection)

        assert.is_true(Exactness.isPlausibleSingleBlockSelectionText(
            "plausible candidate"))
        assert.is_false(Exactness.isPlausibleSingleBlockSelectionText("tiny"))
        assert.is_false(Exactness.isPlausibleSingleBlockSelectionText(
            string.rep("x", 501)))
        for _, separator in ipairs({ "\n", "\r", "\t", string.char(31) }) do
            assert.is_false(Exactness.isPlausibleSingleBlockSelectionText(
                "first" .. separator .. "second"))
        end
        local literal_v4_cross_block =
            "“Record what changed, including the awkward details,” the field guide advised.\n"
            .. "On the 10 morning, Mara returned to an orchard crossed by old stone"
        assert.is_false(Exactness.isPlausibleSingleBlockSelectionText(
            literal_v4_cross_block))
    end)
end)
