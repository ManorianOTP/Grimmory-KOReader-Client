--[[
  Pure engine spec for grimmory.koplugin/view.lua.

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
-- book.fileName, book.personalRating, book.addedOn, book.lastReadTime,
-- book.metadata.allMetadataLocked,
-- book.shelves, book.bookType.

local function make_books()
    return {
        -- 1: basic fantasy, two authors, in a series, READ
        {
            id = 1,
            readStatus = "READ",
            fileSizeKb = 2048,   -- 2 MB
            addedOn = "2023-01-10",
            lastReadTime = "2024-03-01",
            personalRating = 9,
            metadata = {
                title        = "The Glass Cartographer",
                authors      = { "Mira Vale", "Jun Orr" },
                seriesName   = "The Meridian Cycle",
                seriesNumber = 1,
                pageCount    = 541,
                publishedDate= "2006-07-17",
                categories   = { "Fantasy", "Epic Fantasy" },
                publisher    = "Northbridge Press",
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
            addedOn = "2022-06-15",
            lastReadTime = "2025-01-20",
            metadata = {
                title        = "Signal at Perihelion",
                authors      = { "Rowan Keel" },
                seriesName   = "The Orbitals",
                seriesNumber = 1,
                pageCount    = 412,
                publishedDate= "1965-08-01",
                categories   = { "Sci-Fi" },
                publisher    = "Aster House",
                language     = "English",
                goodreadsRating = 4.2,
            },
        },
        -- 3: sci-fi, single author, same series as book 2 (number 2), UNREAD
        {
            id = 3,
            readStatus = "UNREAD",
            fileSizeKb = 768,    -- 0.75 MB → <1 MB
            addedOn = "2022-06-16",
            metadata = {
                title        = "The Quiet Aphelion",
                authors      = { "Rowan Keel" },
                seriesName   = "The Orbitals",
                seriesNumber = 2,
                pageCount    = 226,
                publishedDate= "1969-10-15",
                categories   = { "Sci-Fi" },
                publisher    = "Aster House",
                language     = "English",
            },
        },
        -- 4: fantasy, one author, no series, READ, very short
        {
            id = 4,
            readStatus = "READ",
            fileSizeKb = 200,    -- 0.2 MB → <1 MB
            addedOn = "2021-11-01",
            personalRating = 7,
            metadata = {
                title        = "The Orchard Clock",
                authors      = { "Elian Voss" },
                pageCount    = 208,
                publishedDate= "1988-01-01",
                categories   = { "Fiction", "Self-help" },
                publisher    = "Lantern House Editions",
                language     = "English",
                amazonRating = 4.6,
            },
        },
        -- 5: non-fiction, no author, no series, UNREAD, large file, 1990s
        {
            id = 5,
            readStatus = "UNREAD",
            fileSizeKb = 22000,  -- 21.5 MB → 20 MB+
            addedOn = "2020-03-05",
            metadata = {
                title        = "A Compact History of Dust",
                authors      = { "Nia Sen" },
                pageCount    = 212,
                publishedDate= "1998-09-01",
                categories   = { "Non-fiction", "Science" },
                publisher    = "Cairn Academic",
                language     = "English",
                goodreadsRating = 4.2,
            },
        },
        -- 6: mystery, one author, in a series, READING, 300-page boundary
        {
            id = 6,
            readStatus = "READING",
            fileSizeKb = 5500,   -- 5.37 MB → 5-20 MB
            addedOn = "2023-07-20",
            metadata = {
                title        = "The Red Thread Ledger",
                authors      = { "Tomas Quill" },
                seriesName   = "Inspector Rook",
                seriesNumber = 1,
                pageCount    = 300,
                publishedDate= "1887-11-01",
                categories   = { "Mystery" },
                publisher    = "Copper Street Press",
                language     = "English",
            },
        },
        -- 7: fantasy, no rating, no series, PAUSED, 2010s decade
        {
            id = 7,
            readStatus = "PAUSED",
            fileSizeKb = 1200,   -- 1.17 MB → 1-5 MB
            addedOn = "2024-01-01",
            metadata = {
                title        = "Wind Over Hollow Glass",
                authors      = { "Cerys North" },
                pageCount    = 662,
                publishedDate= "2007-03-27",
                categories   = { "Fantasy" },
                publisher    = "Northbank Fiction",
                language     = "English",
            },
        },
        -- 8: locked book (no metadata rating), for isDimensionPresent("locked")
        {
            id = 8,
            readStatus = "READ",
            fileSizeKb = 800,
            addedOn = "2019-05-10",
            metadata = {
                title        = "Locked Book",
                authors      = { "A. Author" },
                pageCount    = 150,
                publishedDate= "2019-05-01",
                categories   = { "Mystery" },
                publisher    = "Publisher X",
                language     = "English",
                allMetadataLocked = true,
            },
        },
        -- 9: book published in 1999 → decade: 1990s
        {
            id = 9,
            readStatus = "UNREAD",
            fileSizeKb = 3000,   -- 2.93 MB → 1-5 MB
            addedOn = "2018-08-08",
            metadata = {
                title        = "After the Last Bell",
                authors      = { "Ivo Marsh" },
                pageCount    = 218,
                publishedDate= "1999-08-17",
                categories   = { "Fiction" },
                publisher    = "Stonecrop Books",
                language     = "English",
                amazonRating = 4.0,
            },
        },
        -- 10: book missing most metadata (stress-tests nil handling)
        {
            id = 10,
            readStatus = nil,
            fileSizeKb = nil,
            addedOn = nil,
            metadata   = {},
        },
    }
end

local function ids(books)
    local result = {}
    for index, book in ipairs(books) do result[index] = book.id end
    return result
end

local function assert_ids(expected, books, label)
    local actual, seen = ids(books), {}
    assert.same(expected, actual, label)
    for _, id in ipairs(actual) do
        assert.is_nil(seen[id], (label or "result") .. " duplicated id " .. tostring(id))
        seen[id] = true
    end
    assert.equals(#expected, #actual, (label or "result") .. " contains extras")
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
            local expected = {
                title = {
                    asc = {5, 9, 8, 2, 1, 4, 3, 6, 7, 10},
                    desc = {7, 6, 3, 4, 1, 2, 8, 9, 5, 10},
                },
                title_series = {
                    asc = {6, 1, 2, 3, 4, 5, 7, 8, 9, 10},
                    desc = {3, 2, 1, 6, 4, 5, 7, 8, 9, 10},
                },
                author = {
                    asc = {8, 7, 4, 9, 1, 5, 2, 3, 6, 10},
                    desc = {6, 2, 3, 5, 1, 9, 4, 7, 8, 10},
                },
                last_read = {
                    asc = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10},
                    desc = {2, 1, 3, 4, 5, 6, 7, 8, 9, 10},
                },
                added_on = {
                    asc = {9, 8, 5, 4, 2, 3, 1, 6, 7, 10},
                    desc = {7, 6, 1, 3, 2, 4, 5, 8, 9, 10},
                },
                personal_rating = {
                    asc = {4, 1, 2, 3, 5, 6, 7, 8, 9, 10},
                    desc = {1, 4, 2, 3, 5, 6, 7, 8, 9, 10},
                },
                pages = {
                    asc = {8, 4, 5, 9, 3, 6, 2, 1, 7, 10},
                    desc = {7, 1, 2, 6, 3, 9, 5, 4, 8, 10},
                },
                author_series = {
                    asc = {8, 7, 4, 9, 1, 5, 2, 3, 6, 10},
                    desc = {6, 3, 2, 5, 1, 9, 4, 7, 8, 10},
                },
                file_name = {
                    asc = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10},
                    desc = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10},
                },
                file_size = {
                    asc = {4, 2, 3, 8, 7, 1, 9, 6, 5, 10},
                    desc = {5, 6, 9, 1, 7, 8, 3, 2, 4, 10},
                },
                publisher = {
                    asc = {2, 3, 5, 6, 4, 7, 1, 8, 9, 10},
                    desc = {9, 8, 1, 7, 4, 6, 5, 2, 3, 10},
                },
                published_date = {
                    asc = {6, 2, 3, 4, 5, 9, 1, 7, 8, 10},
                    desc = {8, 7, 1, 9, 5, 4, 3, 2, 6, 10},
                },
                amazon_rating = {
                    asc = {9, 4, 1, 2, 3, 5, 6, 7, 8, 10},
                    desc = {1, 4, 9, 2, 3, 5, 6, 7, 8, 10},
                },
                amazon_count = {
                    asc = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10},
                    desc = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10},
                },
                goodreads_rating = {
                    asc = {2, 5, 1, 3, 4, 6, 7, 8, 9, 10},
                    desc = {1, 2, 5, 3, 4, 6, 7, 8, 9, 10},
                },
                goodreads_count = {
                    asc = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10},
                    desc = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10},
                },
                hardcover_rating = {
                    asc = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10},
                    desc = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10},
                },
                hardcover_count = {
                    asc = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10},
                    desc = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10},
                },
                locked = {
                    asc = {8, 1, 2, 3, 4, 5, 6, 7, 9, 10},
                    desc = {8, 1, 2, 3, 4, 5, 6, 7, 9, 10},
                },
            }
            for key, descriptor in pairs(view.SORTS) do
                if key ~= "random" then
                    assert.is_table(expected[key], "missing exact sort oracle for " .. key)
                    for _, direction in ipairs({ "asc", "desc" }) do
                        assert_ids(expected[key][direction], view.applySort(books, {
                            key = key, dir = direction,
                        }), key .. " " .. direction)
                    end
                end
            end
        end)

        it("sorts by title desc, highest title first", function()
            local books = make_books()
            local sorted = view.applySort(books, { key = "title", dir = "desc" })
            assert_ids({7, 6, 3, 4, 1, 2, 8, 9, 5, 10}, sorted, "title desc")
        end)

        it("sorts by pages asc", function()
            local books = make_books()
            local sorted = view.applySort(books, { key = "pages", dir = "asc" })
            assert_ids({8, 4, 5, 9, 3, 6, 2, 1, 7, 10}, sorted, "pages asc")
        end)

        it("sorts by pages desc, nil still sinks last", function()
            local books = make_books()
            local sorted = view.applySort(books, { key = "pages", dir = "desc" })
            assert_ids({7, 1, 2, 6, 3, 9, 5, 4, 8, 10}, sorted, "pages desc")
        end)

        it("missing values sink last in asc direction", function()
            local books = make_books()
            local sorted = view.applySort(books, { key = "added_on", dir = "asc" })
            assert_ids({9, 8, 5, 4, 2, 3, 1, 6, 7, 10}, sorted, "added asc")
        end)

        it("missing values sink last in desc direction", function()
            local books = make_books()
            local sorted = view.applySort(books, { key = "added_on", dir = "desc" })
            assert_ids({7, 6, 1, 3, 2, 4, 5, 8, 9, 10}, sorted, "added desc")
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
            assert_ids({1, 2, 3}, sorted, "stable nil tie")
        end)

        it("random sort returns same id multiset (permutation)", function()
            local books = make_books()
            local sorted = view.applySort(books, { key = "random", dir = "asc", _seed = 42 })
            local shuffled = ids(sorted)
            assert.not_same(ids(books), shuffled,
                "random mode must actually move at least one book")
            local ordered = {}
            for _, id in ipairs(shuffled) do ordered[#ordered + 1] = id end
            table.sort(ordered)
            assert.same({1, 2, 3, 4, 5, 6, 7, 8, 9, 10}, ordered,
                "random result must contain each input exactly once")
            assert_ids(shuffled, sorted, "random permutation")
        end)

        it("random sort with same seed produces same order", function()
            local books = make_books()
            local s1 = view.applySort(books, { key = "random", dir = "asc", _seed = 99 })
            local s2 = view.applySort(books, { key = "random", dir = "asc", _seed = 99 })
            assert_ids(ids(s1), s2, "same-seed random replay")
            assert.not_same(ids(s1), ids(view.applySort(books, {
                key = "random", dir = "asc", _seed = 100,
            })), "different seeds must not be a no-op alias")
        end)

        it("title+series sorts by series then number then title", function()
            local books = {
                { id = 1, metadata = { title = "The Quiet Aphelion", seriesName = "The Orbitals", seriesNumber = 2 } },
                { id = 2, metadata = { title = "Signal at Perihelion", seriesName = "The Orbitals", seriesNumber = 1 } },
                { id = 3, metadata = { title = "The Orchard Clock", seriesName = nil } },
                { id = 4, metadata = { title = "The Glass Cartographer", seriesName = "The Meridian Cycle", seriesNumber = 1 } },
            }
            local sorted = view.applySort(books, { key = "title_series", dir = "asc" })
            -- Meridian precedes Orbitals; numbers order books within a series.
            assert_ids({4, 2, 1, 3}, sorted, "title_series asc")
        end)

        it("title_series desc: no-series books sink last", function()
            local books = {
                { id = 1, metadata = { title = "Signal at Perihelion", seriesName = "The Orbitals", seriesNumber = 1 } },
                { id = 2, metadata = { title = "The Orchard Clock", seriesName = nil } },
                { id = 3, metadata = { title = "The Glass Cartographer", seriesName = "The Meridian Cycle", seriesNumber = 1 } },
            }
            local sorted = view.applySort(books, { key = "title_series", dir = "desc" })
            assert_ids({1, 3, 2}, sorted, "title_series desc")
        end)

        it("author_series: no-author books sink last asc and desc", function()
            local books = {
                { id = 1, metadata = { title = "Signal at Perihelion", authors = {"Rowan Keel"}, seriesName = "The Orbitals", seriesNumber = 1 } },
                { id = 2, metadata = { title = "Untitled", authors = {} } },
            }
            local asc = view.applySort(books, { key = "author_series", dir = "asc" })
            assert_ids({1, 2}, asc, "author_series asc")
            local desc = view.applySort(books, { key = "author_series", dir = "desc" })
            assert_ids({1, 2}, desc, "author_series desc")
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
            assert_ids({1, 2, 3, 4, 5, 6, 7, 8, 9, 10}, result,
                "empty filter identity")
        end)

        it("single dimension filter: readStatus READ returns only READ books", function()
            local books = make_books()
            books[#books + 1] = { id = 11, readStatus = "", metadata = {} }
            books[#books + 1] = { id = 12, readStatus = "read", metadata = {} }
            books[#books + 1] = { id = 13, readStatus = false, metadata = {} }
            local vs = { combine = "AND", filters = { readStatus = { READ = true } } }
            local result = view.applyFilters(books, vs)
            assert_ids({1, 4, 8}, result,
                "READ excludes missing, normalized-null, empty, and case variants")
        end)

        it("within-dim OR: readStatus READ or READING", function()
            local books = make_books()
            local vs = { combine = "AND", filters = {
                readStatus = { READ = true, READING = true }
            }}
            local result = view.applyFilters(books, vs)
            assert_ids({1, 2, 4, 6, 8}, result, "READ or READING exact union")
        end)

        it("multi-dim AND: must match both readStatus AND author", function()
            local books = make_books()
            local vs = { combine = "AND", filters = {
                readStatus = { READ = true },
                author     = { ["Mira Vale"] = true },
            }}
            local result = view.applyFilters(books, vs)
            -- Only book 1 is READ and has Mira Vale as author
            assert_ids({1}, result, "READ and Mira Vale exact intersection")
        end)

        it("multi-dim OR: match readStatus OR author", function()
            local books = make_books()
            local vs = { combine = "OR", filters = {
                readStatus = { READ = true },
                author     = { ["Rowan Keel"] = true },
            }}
            local result = view.applyFilters(books, vs)
            -- READ books: 1, 4, 8; Rowan Keel: 2, 3; union = 1,2,3,4,8
            assert_ids({1, 2, 3, 4, 8}, result, "READ or Rowan Keel exact union")
        end)

        it("multi-author book matches either author", function()
            local books = make_books()
            books[#books + 1] = { id = 11, metadata = { authors = { "mira vale" } } }
            books[#books + 1] = { id = 12, metadata = { authors = { "" } } }
            books[#books + 1] = { id = 13, metadata = { authors = false } }
            books[#books + 1] = { id = 14, metadata = {} }
            -- Book 1 has authors: Mira Vale AND Jun Orr
            local vs_mira = { combine = "AND", filters = {
                author = { ["Mira Vale"] = true }
            }}
            local vs_jun = { combine = "AND", filters = {
                author = { ["Jun Orr"] = true }
            }}
            local r1 = view.applyFilters(books, vs_mira)
            local r2 = view.applyFilters(books, vs_jun)
            assert_ids({1}, r1, "exact first-author match")
            assert_ids({1}, r2, "exact second-author match")
            assert_ids({11}, view.applyFilters(books, {
                combine = "AND", filters = { author = { ["mira vale"] = true } },
            }), "author case variant remains a distinct exact value")
            assert_ids({}, view.applyFilters(books, {
                combine = "AND", filters = { author = { [""] = true } },
            }), "empty/missing/null-normalized authors never become a facet value")
        end)

        it("nil view_state returns all books", function()
            local books = make_books()
            local result = view.applyFilters(books, nil)
            assert_ids({1, 2, 3, 4, 5, 6, 7, 8, 9, 10}, result,
                "nil view state identity")
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
            -- READING books: 2 (Signal at Perihelion), 6 (The Red Thread Ledger)
            -- Sorted asc: "Signal at Perihelion" < "The Red Thread Ledger"
            assert_ids({2, 6}, result, "filter-then-sort exact result")
        end)
    end)

    -- -----------------------------------------------------------------------
    -- computeFacetCounts
    -- -----------------------------------------------------------------------

    describe("computeFacetCounts", function()
        it("counts all values when no other filters active", function()
            local books = make_books()
            books[#books + 1] = { id = 11, readStatus = "", metadata = {} }
            books[#books + 1] = { id = 12, readStatus = "read", metadata = {} }
            books[#books + 1] = { id = 13, readStatus = false, metadata = {} }
            local vs = { combine = "AND", filters = {} }
            local facets = view.computeFacetCounts(books, vs, "readStatus")
            assert.same({
                { value = "PAUSED", label = "PAUSED", count = 1 },
                { value = "READ", label = "READ", count = 3 },
                { value = "READING", label = "READING", count = 2 },
                { value = "UNREAD", label = "UNREAD", count = 3 },
                { value = "read", label = "read", count = 1 },
            }, facets.ordered,
                "facets must include the case variant but no missing/null/empty extras")
        end)

        it("drops zero-count values", function()
            local books = make_books()
            -- Filter to only Rowan Keel books (id 2 and 3, both READING/UNREAD)
            local vs = { combine = "AND", filters = {
                author = { ["Rowan Keel"] = true }
            }}
            -- Count readStatus facets: now only READING and UNREAD should appear
            local facets = view.computeFacetCounts(books, vs, "readStatus")
            assert.same({
                { value = "READING", label = "READING", count = 1 },
                { value = "UNREAD", label = "UNREAD", count = 1 },
            }, facets.ordered, "zero-count facets must be absent with no extras")
        end)

        it("facets for the queried dim ignore that dim's own filter", function()
            local books = make_books()
            -- Active filter: readStatus = READ  (affects what we're counting in readStatus itself)
            local vs = { combine = "AND", filters = {
                readStatus = { READ = true }
            }}
            -- Asking for readStatus facets: should see counts from ALL books (ignoring self-filter)
            local facets = view.computeFacetCounts(books, vs, "readStatus")
            assert.same({
                { value = "PAUSED", label = "PAUSED", count = 1 },
                { value = "READ", label = "READ", count = 3 },
                { value = "READING", label = "READING", count = 2 },
                { value = "UNREAD", label = "UNREAD", count = 3 },
            }, facets.ordered, "self-filter must be ignored exactly")
        end)

        it("counts respect other active filters", function()
            local books = make_books()
            -- Filter by Rowan Keel, count series facets
            local vs = { combine = "AND", filters = {
                author = { ["Rowan Keel"] = true }
            }}
            local facets = view.computeFacetCounts(books, vs, "series")
            assert.same({
                { value = "The Orbitals", label = "The Orbitals", count = 2 },
            }, facets.ordered, "other filters must leave one exact series facet")
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
            assert_ids({2, 6}, result, "300-499 exact bucket membership")
        end)

        it("4.0 amazon rating matches 4+ bucket", function()
            local books = make_books()
            -- Book 9 has amazonRating = 4.0
            local vs = { combine = "AND", filters = {
                amazon_rating = { ["4+"] = true }
            }}
            local result = view.applyFilters(books, vs)
            assert_ids({1, 4, 9}, result, "amazon 4+ exact bucket membership")
        end)

        it("1999 book lands in 1990s decade", function()
            local books = make_books()
            -- Book 9 published 1999-08-17
            local vs = { combine = "AND", filters = {
                published_year = { ["1990s"] = true }
            }}
            local result = view.applyFilters(books, vs)
            assert_ids({5, 9}, result, "1990s exact bucket membership")
        end)

        it("1965 book lands in Pre-1990", function()
            local books = make_books()
            -- Book 2 published 1965
            local vs = { combine = "AND", filters = {
                published_year = { ["Pre-1990"] = true }
            }}
            local result = view.applyFilters(books, vs)
            assert_ids({2, 3, 4, 6}, result, "Pre-1990 exact bucket membership")
        end)

        it("file size <1 MB bucket", function()
            local books = make_books()
            -- Books 2(512kb), 3(768kb), 4(200kb) are <1 MB
            local vs = { combine = "AND", filters = {
                file_size = { ["<1 MB"] = true }
            }}
            local result = view.applyFilters(books, vs)
            assert_ids({2, 3, 4, 8}, result, "sub-1MB exact bucket membership")
        end)

        it("personal rating 9 lands in 8+ bucket", function()
            local books = make_books()
            -- Book 1 has personalRating = 9
            local vs = { combine = "AND", filters = {
                personal_rating = { ["8+"] = true }
            }}
            local result = view.applyFilters(books, vs)
            assert_ids({1}, result, "personal rating 8+ exact bucket membership")
        end)

        it("personal rating 7 lands in 6+ bucket, not 8+", function()
            local books = make_books()
            -- Book 4 has personalRating = 7
            local vs_8 = { combine = "AND", filters = { personal_rating = { ["8+"] = true } } }
            local vs_6 = { combine = "AND", filters = { personal_rating = { ["6+"] = true } } }
            local r8 = view.applyFilters(books, vs_8)
            local r6 = view.applyFilters(books, vs_6)
            assert_ids({1}, r8, "personal rating 8+ excludes seven")
            assert_ids({4}, r6, "personal rating 6+ exact bucket membership")
        end)

        it("0-rated book (no rating) lands in Unrated bucket", function()
            local books = make_books()
            -- Books without personalRating (or 0) should be Unrated
            local vs = { combine = "AND", filters = {
                personal_rating = { ["Unrated"] = true }
            }}
            local result = view.applyFilters(books, vs)
            assert_ids({2, 3, 5, 6, 7, 8, 9, 10}, result,
                "Unrated exact bucket membership")
        end)
    end)

    -- -----------------------------------------------------------------------
    -- isDimensionPresent
    -- -----------------------------------------------------------------------

    describe("isDimensionPresent", function()
        it("returns false when no book has metadata.allMetadataLocked", function()
            local books = {}
            for _, b in ipairs(make_books()) do
                if not (b.metadata or {}).allMetadataLocked then
                    books[#books+1] = b
                end
            end
            -- locked is a sort key, not a DIMENSIONS key — use the fallback path
            assert.falsy(view.isDimensionPresent(books, "locked"))
        end)

        it("returns true when metadata.allMetadataLocked=true", function()
            local books = make_books()
            -- Book 8 has metadata.allMetadataLocked=true
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
                author     = { ["Rowan Keel"] = true },
            }}
            assert.equals(3, view.activeFilterCount(vs))
        end)
    end)
end)
