--[[
  Pure engine spec for booklore.koplugin/view.lua.

  No HTTP fixture needed — view.lua is pure Lua with no I/O.
  A small inline table of ~10 varied books covers all test cases.
]]

local spec_helper = require("spec_helper")

local view

-- ---------------------------------------------------------------------------
-- Inline book fixtures
-- ---------------------------------------------------------------------------

-- All books share a minimal structure matching the server payload shape.
-- Fields used by view.lua: book.metadata.*, book.readStatus, book.fileSizeKb,
-- book.fileName, book.personalRating, book.locked, book.createdAt, book.lastReadAt,
-- book.shelves, book.bookType.

local function make_books()
    return {
        -- 1: basic fantasy, two authors, in a series, READ
        {
            id = 1,
            readStatus = "READ",
            fileSizeKb = 2048,   -- 2 MB
            createdAt  = "2023-01-10",
            lastReadAt = "2024-03-01",
            personalRating = 9,
            metadata = {
                title        = "The Final Empire",
                authors      = { "Brandon Sanderson", "Isaac Stewart" },
                seriesName   = "Mistborn",
                seriesNumber = 1,
                pageCount    = 541,
                publishedDate= "2006-07-17",
                categories   = { "Fantasy", "Epic Fantasy" },
                publisher    = "Tor Books",
                language     = "English",
                amazonRating     = 4.7,
                goodreadsRating  = 4.4,
            },
        },
        -- 2: sci-fi, single author, same series as book 3, READING
        {
            id = 2,
            readStatus = "READING",
            fileSizeKb = 512,    -- 0.5 MB → <1 MB
            createdAt  = "2022-06-15",
            lastReadAt = "2025-01-20",
            metadata = {
                title        = "Dune",
                authors      = { "Frank Herbert" },
                seriesName   = "Dune",
                seriesNumber = 1,
                pageCount    = 412,
                publishedDate= "1965-08-01",
                categories   = { "Sci-Fi" },
                publisher    = "Chilton Books",
                language     = "English",
                goodreadsRating = 4.2,
            },
        },
        -- 3: sci-fi, single author, same series as book 2 (number 2), UNREAD
        {
            id = 3,
            readStatus = "UNREAD",
            fileSizeKb = 768,    -- 0.75 MB → <1 MB
            createdAt  = "2022-06-16",
            metadata = {
                title        = "Dune Messiah",
                authors      = { "Frank Herbert" },
                seriesName   = "Dune",
                seriesNumber = 2,
                pageCount    = 226,
                publishedDate= "1969-10-15",
                categories   = { "Sci-Fi" },
                publisher    = "Putnam",
                language     = "English",
            },
        },
        -- 4: fantasy, one author, no series, READ, very short
        {
            id = 4,
            readStatus = "READ",
            fileSizeKb = 200,    -- 0.2 MB → <1 MB
            createdAt  = "2021-11-01",
            personalRating = 7,
            metadata = {
                title        = "The Alchemist",
                authors      = { "Paulo Coelho" },
                pageCount    = 208,
                publishedDate= "1988-01-01",
                categories   = { "Fiction", "Self-help" },
                publisher    = "HarperCollins",
                language     = "English",
                amazonRating = 4.6,
            },
        },
        -- 5: non-fiction, no author, no series, UNREAD, large file, 1990s
        {
            id = 5,
            readStatus = "UNREAD",
            fileSizeKb = 22000,  -- 21.5 MB → 20 MB+
            createdAt  = "2020-03-05",
            metadata = {
                title        = "A Brief History of Time",
                authors      = { "Stephen Hawking" },
                pageCount    = 212,
                publishedDate= "1998-09-01",
                categories   = { "Non-fiction", "Science" },
                publisher    = "Bantam",
                language     = "English",
                goodreadsRating = 4.2,
            },
        },
        -- 6: mystery, one author, in a series, READING, 300-page boundary
        {
            id = 6,
            readStatus = "READING",
            fileSizeKb = 5500,   -- 5.37 MB → 5-20 MB
            createdAt  = "2023-07-20",
            metadata = {
                title        = "A Study in Scarlet",
                authors      = { "Arthur Conan Doyle" },
                seriesName   = "Sherlock Holmes",
                seriesNumber = 1,
                pageCount    = 300,
                publishedDate= "1887-11-01",
                categories   = { "Mystery" },
                publisher    = "Ward Lock & Co",
                language     = "English",
            },
        },
        -- 7: fantasy, no rating, no series, PAUSED, 2010s decade
        {
            id = 7,
            readStatus = "PAUSED",
            fileSizeKb = 1200,   -- 1.17 MB → 1-5 MB
            createdAt  = "2024-01-01",
            metadata = {
                title        = "The Name of the Wind",
                authors      = { "Patrick Rothfuss" },
                pageCount    = 662,
                publishedDate= "2007-03-27",
                categories   = { "Fantasy" },
                publisher    = "DAW Books",
                language     = "English",
            },
        },
        -- 8: locked book (no metadata rating), for isDimensionPresent("locked")
        {
            id = 8,
            readStatus = "READ",
            fileSizeKb = 800,
            locked     = true,
            createdAt  = "2019-05-10",
            metadata = {
                title        = "Locked Book",
                authors      = { "A. Author" },
                pageCount    = 150,
                publishedDate= "2019-05-01",
                categories   = { "Mystery" },
                publisher    = "Publisher X",
                language     = "English",
            },
        },
        -- 9: book published in 1999 → decade: 1990s
        {
            id = 9,
            readStatus = "UNREAD",
            fileSizeKb = 3000,   -- 2.93 MB → 1-5 MB
            createdAt  = "2018-08-08",
            metadata = {
                title        = "Fight Club",
                authors      = { "Chuck Palahniuk" },
                pageCount    = 218,
                publishedDate= "1999-08-17",
                categories   = { "Fiction" },
                publisher    = "W. W. Norton",
                language     = "English",
                amazonRating = 4.0,
            },
        },
        -- 10: book missing most metadata (stress-tests nil handling)
        {
            id = 10,
            readStatus = nil,
            fileSizeKb = nil,
            createdAt  = nil,
            metadata   = {},
        },
    }
end

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

describe("view", function()
    before_each(function()
        spec_helper.setup()
        view = require("view")
    end)

    after_each(function()
        spec_helper.teardown()
    end)

    -- -----------------------------------------------------------------------
    -- Registry shape
    -- -----------------------------------------------------------------------

    describe("SORTS registry", function()
        it("has required essential keys", function()
            local essentials = {"title","title_series","author","last_read","added_on",
                                "personal_rating","pages","random"}
            for _, k in ipairs(essentials) do
                assert.is_table(view.SORTS[k], "missing essential sort: " .. k)
                assert.equals("essential", view.SORTS[k].tier, k .. " should be essential")
            end
        end)

        it("has locked as advanced", function()
            assert.is_table(view.SORTS["locked"])
            assert.equals("advanced", view.SORTS["locked"].tier)
        end)

        it("each entry has key, label, tier, kind, get", function()
            for k, sd in pairs(view.SORTS) do
                assert.is_string(sd.key,   k .. ".key")
                assert.is_string(sd.label, k .. ".label")
                assert.is_string(sd.tier,  k .. ".tier")
                assert.is_string(sd.kind,  k .. ".kind")
                assert.is_function(sd.get, k .. ".get")
            end
        end)
    end)

    describe("DIMENSIONS registry", function()
        it("has required essential dims", function()
            local essentials = {"author","genre","series","readStatus","publisher","language"}
            for _, k in ipairs(essentials) do
                assert.is_table(view.DIMENSIONS[k], "missing essential dim: " .. k)
                assert.equals("essential", view.DIMENSIONS[k].tier, k .. " should be essential")
            end
        end)

        it("has metadata_match_score as advanced", function()
            assert.is_table(view.DIMENSIONS["metadata_match_score"])
            assert.equals("advanced", view.DIMENSIONS["metadata_match_score"].tier)
        end)

        it("each entry has key, label, tier, values, format", function()
            for k, dd in pairs(view.DIMENSIONS) do
                assert.is_string(dd.key,    k .. ".key")
                assert.is_string(dd.label,  k .. ".label")
                assert.is_string(dd.tier,   k .. ".tier")
                assert.is_function(dd.values, k .. ".values")
                assert.is_function(dd.format, k .. ".format")
            end
        end)
    end)

    -- -----------------------------------------------------------------------
    -- applySort
    -- -----------------------------------------------------------------------

    describe("applySort", function()
        it("sorts by title asc", function()
            local books = make_books()
            local sorted = view.applySort(books, { key = "title", dir = "asc" })
            -- First book alphabetically should be "A Brief History of Time"
            assert.equals("A Brief History of Time",
                (sorted[1].metadata or {}).title)
        end)

        it("sorts by title desc, highest title first", function()
            local books = make_books()
            local sorted = view.applySort(books, { key = "title", dir = "desc" })
            -- "The Name of the Wind" starts with T — highest alphabetically among our fixtures
            -- Book 7 = "The Name of the Wind", book 9 = "The...", book 1 = "The Final Empire"
            -- Desc: T > ... > A. First non-nil title should be highest alphabetically.
            -- Book 10 has nil title and must still sink to last.
            assert.equals(10, sorted[#sorted].id)
            -- First element should have a title starting with "T" (The Name of the Wind)
            local first_title = (sorted[1].metadata or {}).title or ""
            assert.truthy(first_title > "S", "expected desc first title > 'S', got: " .. first_title)
        end)

        it("sorts by pages asc", function()
            local books = make_books()
            local sorted = view.applySort(books, { key = "pages", dir = "asc" })
            -- Only books with pageCount should come first; nil-pageCount (book 10) sinks last
            assert.not_equals(10, sorted[1].id)
            assert.equals(10, sorted[#sorted].id)
        end)

        it("sorts by pages desc, nil still sinks last", function()
            local books = make_books()
            local sorted = view.applySort(books, { key = "pages", dir = "desc" })
            -- Highest pages first; book 10 (nil pages) must still be last
            assert.equals(10, sorted[#sorted].id)
            -- book 7 has 662 pages = max
            assert.equals(7, sorted[1].id)
        end)

        it("missing values sink last in asc direction", function()
            local books = make_books()
            local sorted = view.applySort(books, { key = "added_on", dir = "asc" })
            -- Book 10 has nil createdAt, should be last
            assert.equals(10, sorted[#sorted].id)
        end)

        it("missing values sink last in desc direction", function()
            local books = make_books()
            local sorted = view.applySort(books, { key = "added_on", dir = "desc" })
            -- Book 10 has nil createdAt, should still be last even in desc
            assert.equals(10, sorted[#sorted].id)
        end)

        it("is stable: equal keys preserve original order", function()
            -- Books with the same readStatus string sort stably
            local books = {
                { id = 1, readStatus = "READ", metadata = { title = "B" } },
                { id = 2, readStatus = "READ", metadata = { title = "A" } },
                { id = 3, readStatus = "READ", metadata = { title = "C" } },
            }
            -- Sort by pages (all nil) — should preserve original order
            local sorted = view.applySort(books, { key = "pages", dir = "asc" })
            assert.equals(1, sorted[1].id)
            assert.equals(2, sorted[2].id)
            assert.equals(3, sorted[3].id)
        end)

        it("random sort returns same id multiset (permutation)", function()
            local books = make_books()
            local sorted = view.applySort(books, { key = "random", dir = "asc", _seed = 42 })
            assert.equals(#books, #sorted)
            -- Same IDs present
            local orig_ids = {}
            for _, b in ipairs(books) do orig_ids[b.id] = true end
            for _, b in ipairs(sorted) do
                assert.truthy(orig_ids[b.id], "unexpected id in random sort: " .. tostring(b.id))
            end
        end)

        it("random sort with same seed produces same order", function()
            local books = make_books()
            local s1 = view.applySort(books, { key = "random", dir = "asc", _seed = 99 })
            local s2 = view.applySort(books, { key = "random", dir = "asc", _seed = 99 })
            for i = 1, #s1 do
                assert.equals(s1[i].id, s2[i].id)
            end
        end)

        it("title+series sorts by series then number then title", function()
            local books = {
                { id = 1, metadata = { title = "Dune Messiah",    seriesName = "Dune", seriesNumber = 2 } },
                { id = 2, metadata = { title = "Dune",            seriesName = "Dune", seriesNumber = 1 } },
                { id = 3, metadata = { title = "The Alchemist",   seriesName = nil } },
                { id = 4, metadata = { title = "The Final Empire",seriesName = "Mistborn", seriesNumber = 1 } },
            }
            local sorted = view.applySort(books, { key = "title_series", dir = "asc" })
            -- Dune(1) < Dune Messiah(2) < Mistborn: Final Empire < no-series: The Alchemist
            assert.equals(2, sorted[1].id)   -- Dune #1
            assert.equals(1, sorted[2].id)   -- Dune Messiah #2
            assert.equals(4, sorted[3].id)   -- Mistborn #1
            assert.equals(3, sorted[4].id)   -- no series
        end)

        it("title_series desc: no-series books sink last", function()
            local books = {
                { id = 1, metadata = { title = "Dune", seriesName = "Dune", seriesNumber = 1 } },
                { id = 2, metadata = { title = "The Alchemist", seriesName = nil } },
                { id = 3, metadata = { title = "The Final Empire", seriesName = "Mistborn", seriesNumber = 1 } },
            }
            local sorted = view.applySort(books, { key = "title_series", dir = "desc" })
            assert.equals(2, sorted[#sorted].id)
        end)

        it("author_series: no-author books sink last asc and desc", function()
            local books = {
                { id = 1, metadata = { title = "Dune", authors = {"Frank Herbert"}, seriesName = "Dune", seriesNumber = 1 } },
                { id = 2, metadata = { title = "Untitled", authors = {} } },
            }
            local asc = view.applySort(books, { key = "author_series", dir = "asc" })
            assert.equals(2, asc[#asc].id)
            local desc = view.applySort(books, { key = "author_series", dir = "desc" })
            assert.equals(2, desc[#desc].id)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- applyFilters
    -- -----------------------------------------------------------------------

    describe("applyFilters", function()
        it("identity: empty filters returns all books", function()
            local books = make_books()
            local vs = { combine = "AND", filters = {} }
            local result = view.applyFilters(books, vs)
            assert.equals(#books, #result)
        end)

        it("single dimension filter: readStatus READ returns only READ books", function()
            local books = make_books()
            local vs = { combine = "AND", filters = { readStatus = { READ = true } } }
            local result = view.applyFilters(books, vs)
            for _, b in ipairs(result) do
                assert.equals("READ", b.readStatus)
            end
            assert.truthy(#result > 0)
        end)

        it("within-dim OR: readStatus READ or READING", function()
            local books = make_books()
            local vs = { combine = "AND", filters = {
                readStatus = { READ = true, READING = true }
            }}
            local result = view.applyFilters(books, vs)
            for _, b in ipairs(result) do
                assert.truthy(b.readStatus == "READ" or b.readStatus == "READING",
                    "unexpected status: " .. tostring(b.readStatus))
            end
        end)

        it("multi-dim AND: must match both readStatus AND author", function()
            local books = make_books()
            local vs = { combine = "AND", filters = {
                readStatus = { READ = true },
                author     = { ["Brandon Sanderson"] = true },
            }}
            local result = view.applyFilters(books, vs)
            -- Only book 1 is READ and has Brandon Sanderson as author
            assert.equals(1, #result)
            assert.equals(1, result[1].id)
        end)

        it("multi-dim OR: match readStatus OR author", function()
            local books = make_books()
            local vs = { combine = "OR", filters = {
                readStatus = { READ = true },
                author     = { ["Frank Herbert"] = true },
            }}
            local result = view.applyFilters(books, vs)
            -- READ books: 1, 4, 8; Frank Herbert: 2, 3; union = 1,2,3,4,8
            local ids = {}
            for _, b in ipairs(result) do ids[b.id] = true end
            assert.truthy(ids[1])
            assert.truthy(ids[2])
            assert.truthy(ids[3])
            assert.truthy(ids[4])
            assert.truthy(ids[8])
        end)

        it("multi-author book matches either author", function()
            local books = make_books()
            -- Book 1 has authors: Brandon Sanderson AND Isaac Stewart
            local vs_brandon = { combine = "AND", filters = {
                author = { ["Brandon Sanderson"] = true }
            }}
            local vs_isaac = { combine = "AND", filters = {
                author = { ["Isaac Stewart"] = true }
            }}
            local r1 = view.applyFilters(books, vs_brandon)
            local r2 = view.applyFilters(books, vs_isaac)
            local found1, found2 = false, false
            for _, b in ipairs(r1) do if b.id == 1 then found1 = true end end
            for _, b in ipairs(r2) do if b.id == 1 then found2 = true end end
            assert.truthy(found1, "multi-author book not found by first author")
            assert.truthy(found2, "multi-author book not found by second author")
        end)

        it("nil view_state returns all books", function()
            local books = make_books()
            local result = view.applyFilters(books, nil)
            assert.equals(#books, #result)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- applyView
    -- -----------------------------------------------------------------------

    describe("applyView", function()
        it("applies filter then sort", function()
            local books = make_books()
            local vs = {
                combine = "AND",
                filters = { readStatus = { READING = true } },
                sort    = { key = "title", dir = "asc" },
            }
            local result = view.applyView(books, vs)
            -- READING books: 2 (Dune), 6 (A Study in Scarlet)
            -- Sorted asc: "A Study in Scarlet" < "Dune"
            assert.equals(2, #result)
            assert.equals(6, result[1].id)
            assert.equals(2, result[2].id)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- computeFacetCounts
    -- -----------------------------------------------------------------------

    describe("computeFacetCounts", function()
        it("counts all values when no other filters active", function()
            local books = make_books()
            local vs = { combine = "AND", filters = {} }
            local facets = view.computeFacetCounts(books, vs, "readStatus")
            -- Should have READ, READING, UNREAD, PAUSED counts
            local by_val = {}
            for _, f in ipairs(facets.ordered) do by_val[f.value] = f.count end
            assert.truthy(by_val["READ"] and by_val["READ"] >= 3)
            assert.truthy(by_val["READING"] and by_val["READING"] >= 2)
            assert.truthy(by_val["UNREAD"] and by_val["UNREAD"] >= 3)
        end)

        it("drops zero-count values", function()
            local books = make_books()
            -- Filter to only Frank Herbert books (id 2 and 3, both READING/UNREAD)
            local vs = { combine = "AND", filters = {
                author = { ["Frank Herbert"] = true }
            }}
            -- Count readStatus facets: now only READING and UNREAD should appear
            local facets = view.computeFacetCounts(books, vs, "readStatus")
            local by_val = {}
            for _, f in ipairs(facets.ordered) do by_val[f.value] = f.count end
            -- READ books by Frank Herbert: none → should be absent
            assert.is_nil(by_val["READ"])
            assert.truthy(by_val["READING"])
            assert.truthy(by_val["UNREAD"])
        end)

        it("facets for the queried dim ignore that dim's own filter", function()
            local books = make_books()
            -- Active filter: readStatus = READ  (affects what we're counting in readStatus itself)
            local vs = { combine = "AND", filters = {
                readStatus = { READ = true }
            }}
            -- Asking for readStatus facets: should see counts from ALL books (ignoring self-filter)
            local facets = view.computeFacetCounts(books, vs, "readStatus")
            local by_val = {}
            for _, f in ipairs(facets.ordered) do by_val[f.value] = f.count end
            -- READING should appear (it's in the full set)
            assert.truthy(by_val["READING"], "READING should appear when self-filter ignored")
        end)

        it("counts respect other active filters", function()
            local books = make_books()
            -- Filter by Frank Herbert, count series facets
            local vs = { combine = "AND", filters = {
                author = { ["Frank Herbert"] = true }
            }}
            local facets = view.computeFacetCounts(books, vs, "series")
            local by_val = {}
            for _, f in ipairs(facets.ordered) do by_val[f.value] = f.count end
            -- Only Dune series should appear (Frank Herbert's only series here)
            assert.truthy(by_val["Dune"])
            -- Mistborn should not appear
            assert.is_nil(by_val["Mistborn"])
        end)
    end)

    -- -----------------------------------------------------------------------
    -- Bucket boundaries
    -- -----------------------------------------------------------------------

    describe("bucket boundaries", function()
        it("300-page book lands in 300-499", function()
            local books = make_books()
            local vs = { combine = "AND", filters = {
                page_count = { ["300-499"] = true }
            }}
            local result = view.applyFilters(books, vs)
            -- Book 6 has exactly 300 pages
            local found = false
            for _, b in ipairs(result) do
                if b.id == 6 then found = true end
            end
            assert.truthy(found, "300-page book not in 300-499 bucket")
            -- Book with 226 pages should not be in 300-499
            local has_226 = false
            for _, b in ipairs(result) do
                if b.id == 3 then has_226 = true end
            end
            assert.falsy(has_226, "226-page book should not be in 300-499 bucket")
        end)

        it("4.0 amazon rating matches 4+ bucket", function()
            local books = make_books()
            -- Book 9 has amazonRating = 4.0
            local vs = { combine = "AND", filters = {
                amazon_rating = { ["4+"] = true }
            }}
            local result = view.applyFilters(books, vs)
            local found = false
            for _, b in ipairs(result) do
                if b.id == 9 then found = true end
            end
            assert.truthy(found, "4.0 amazon rating should match 4+ bucket")
        end)

        it("1999 book lands in 1990s decade", function()
            local books = make_books()
            -- Book 9 published 1999-08-17
            local vs = { combine = "AND", filters = {
                published_year = { ["1990s"] = true }
            }}
            local result = view.applyFilters(books, vs)
            local found = false
            for _, b in ipairs(result) do
                if b.id == 9 then found = true end
            end
            assert.truthy(found, "1999 book should be in 1990s decade bucket")
        end)

        it("1965 book lands in Pre-1990", function()
            local books = make_books()
            -- Book 2 published 1965
            local vs = { combine = "AND", filters = {
                published_year = { ["Pre-1990"] = true }
            }}
            local result = view.applyFilters(books, vs)
            local found = false
            for _, b in ipairs(result) do
                if b.id == 2 then found = true end
            end
            assert.truthy(found, "1965 book should be in Pre-1990 bucket")
        end)

        it("file size <1 MB bucket", function()
            local books = make_books()
            -- Books 2(512kb), 3(768kb), 4(200kb) are <1 MB
            local vs = { combine = "AND", filters = {
                file_size = { ["<1 MB"] = true }
            }}
            local result = view.applyFilters(books, vs)
            local ids = {}
            for _, b in ipairs(result) do ids[b.id] = true end
            assert.truthy(ids[2])
            assert.truthy(ids[3])
            assert.truthy(ids[4])
            -- Book 1 (2048 kb = 2MB) should not be in <1MB
            assert.falsy(ids[1])
        end)

        it("personal rating 9 lands in 8+ bucket", function()
            local books = make_books()
            -- Book 1 has personalRating = 9
            local vs = { combine = "AND", filters = {
                personal_rating = { ["8+"] = true }
            }}
            local result = view.applyFilters(books, vs)
            local found = false
            for _, b in ipairs(result) do
                if b.id == 1 then found = true end
            end
            assert.truthy(found, "personalRating=9 should match 8+ bucket")
        end)

        it("personal rating 7 lands in 6+ bucket, not 8+", function()
            local books = make_books()
            -- Book 4 has personalRating = 7
            local vs_8 = { combine = "AND", filters = { personal_rating = { ["8+"] = true } } }
            local vs_6 = { combine = "AND", filters = { personal_rating = { ["6+"] = true } } }
            local r8 = view.applyFilters(books, vs_8)
            local r6 = view.applyFilters(books, vs_6)
            local in8, in6 = false, false
            for _, b in ipairs(r8) do if b.id == 4 then in8 = true end end
            for _, b in ipairs(r6) do if b.id == 4 then in6 = true end end
            assert.falsy(in8, "personalRating=7 should NOT match 8+")
            assert.truthy(in6, "personalRating=7 should match 6+")
        end)

        it("0-rated book (no rating) lands in Unrated bucket", function()
            local books = make_books()
            -- Books without personalRating (or 0) should be Unrated
            local vs = { combine = "AND", filters = {
                personal_rating = { ["Unrated"] = true }
            }}
            local result = view.applyFilters(books, vs)
            -- Book 2, 3, 5, 6, 7, 8, 9, 10 have no personalRating
            local found_no_rating = false
            for _, b in ipairs(result) do
                if b.id == 2 then found_no_rating = true end
            end
            assert.truthy(found_no_rating, "book with no personalRating should be in Unrated")
            -- Book 1 (personalRating=9) should NOT be Unrated
            local found_rated = false
            for _, b in ipairs(result) do
                if b.id == 1 then found_rated = true end
            end
            assert.falsy(found_rated, "book with personalRating=9 should not be Unrated")
        end)
    end)

    -- -----------------------------------------------------------------------
    -- isDimensionPresent
    -- -----------------------------------------------------------------------

    describe("isDimensionPresent", function()
        it("returns false when no book has the locked field", function()
            local books = {}
            for _, b in ipairs(make_books()) do
                if not b.locked then
                    books[#books+1] = b
                end
            end
            -- locked is a sort key, not a DIMENSIONS key — use the fallback path
            assert.falsy(view.isDimensionPresent(books, "locked"))
        end)

        it("returns true when at least one book has locked=true", function()
            local books = make_books()
            -- Book 8 has locked=true
            assert.truthy(view.isDimensionPresent(books, "locked"))
        end)

        it("returns false for author when no book has authors", function()
            local books = {{ id = 1, metadata = {} }, { id = 2, metadata = {} }}
            assert.falsy(view.isDimensionPresent(books, "author"))
        end)

        it("returns true for author when at least one book has authors", function()
            local books = make_books()
            assert.truthy(view.isDimensionPresent(books, "author"))
        end)
    end)

    -- -----------------------------------------------------------------------
    -- activeFilterCount
    -- -----------------------------------------------------------------------

    describe("activeFilterCount", function()
        it("returns 0 for empty filters", function()
            local vs = { combine = "AND", filters = {} }
            assert.equals(0, view.activeFilterCount(vs))
        end)

        it("returns 0 for nil view_state", function()
            assert.equals(0, view.activeFilterCount(nil))
        end)

        it("counts individual selected values", function()
            local vs = { combine = "AND", filters = {
                readStatus = { READ = true, READING = true },
                author     = { ["Frank Herbert"] = true },
            }}
            assert.equals(3, view.activeFilterCount(vs))
        end)
    end)
end)
