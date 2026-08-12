-- Deterministic inputs for visual regression scenarios. This module deliberately
-- contains synthetic data only: production widgets are still built by
-- grimmory.koplugin. IDs and field shapes mirror the local fixture server so a
-- server-backed lane can replace these tables without changing scene builders.

local scenarios = {}

local function pendingBook(index, title)
    return {
        id = index,
        title = title or ("Pending book " .. tostring(index)),
        active = true,
        device_percentage = 12.5 + index,
        device_position = "epubcfi(/6/" .. tostring(index * 2) .. ")",
        server_percentage = 7.25 + index,
        server_position = "epubcfi(/6/" .. tostring(index) .. ")",
        features = { progress = true },
    }
end

local function pendingBooks(count)
    local result = {}
    for index = 1, count do result[index] = pendingBook(index) end
    return result
end

local titles = {
    { "The Glass Cartographer", "Mira Vale", "The Meridian Cycle", 1 },
    { "Echoes Beneath the Brass Sky", "Mira Vale", "The Meridian Cycle", 2 },
    { "A Lantern at the Edge", "Mira Vale", "The Meridian Cycle", 2.5 },
    { "The Orchard Beyond Winter", "Elian Voss", "The Winter Orchard Chronicles", 1 },
    { "A Palace of Salt and Rain", "Elian Voss", "The Winter Orchard Chronicles", 2 },
    { "The Crown of Hollow Rivers", "Elian Voss", "The Winter Orchard Chronicles", 3 },
    { "An Interlude of Frost and Ember", "Elian Voss", "The Winter Orchard Chronicles", 3.5 },
    { "The Silver City at Dawn", "Elian Voss", "The Winter Orchard Chronicles", 4 },
    { "A Deliberately Long Fixture Title That Exercises Ellipsis and Narrow Portrait Layouts", "An Extremely Long Synthetic Author Name Designed for Narrow Screens", "Visual Regression", 1 },
    { "The Small Quiet Book", "A. Fixture", "Visual Regression", 2 },
    { "Offline Reading Sample", "A. Fixture", "Visual Regression", 3 },
    { "Pagination Boundary Volume", "A. Fixture", "Visual Regression", 4 },
}

local function fixtureBooks()
    local result = {}
    for index, row in ipairs(titles) do
        local id = 1000 + index
        local shelf_id = row[3] == "The Meridian Cycle" and 71
            or (row[3] == "The Winter Orchard Chronicles" and 72 or nil)
        local primary = {
            id = 5000 + index,
            bookId = id,
            fileName = row[1] .. ".epub",
            fileSizeKb = 3072 + index * 241,
            bookType = "EPUB",
            extension = "epub",
            book = true,
            folderBased = false,
            isPrimary = true,
        }
        local book = {
            id = id,
            title = row[1],
            libraryId = 41,
            libraryName = "Visual Test Library",
            fileName = primary.fileName,
            fileSizeKb = primary.fileSizeKb,
            bookType = "EPUB",
            primaryFile = primary,
            downloadFiles = { primary },
            bookFiles = { primary },
            readStatus = index % 3 == 0 and "Read" or "Reading",
            personalRating = index % 5 + 1,
            epubProgress = { percentage = index * 6.75 },
            lastReadTime = index <= 5 and string.format("2026-08-%02dT12:00:00Z", 10 - index) or nil,
            lastReadAt = index <= 5 and string.format("2026-08-%02dT12:00:00Z", 10 - index) or nil,
            addedOn = string.format("2026-07-%02dT12:00:00Z", 29 - index),
            createdAt = string.format("2026-07-%02dT12:00:00Z", 29 - index),
            shelves = shelf_id and { { id = shelf_id, name = shelf_id == 71
                and "The Meridian Cycle" or "The Winter Orchard Chronicles" } } or {},
            metadata = {
                title = row[1],
                subtitle = index == 1 and "A Synthetic Visual Test Subtitle" or nil,
                authors = { row[2] },
                seriesName = row[3],
                seriesNumber = row[4],
                seriesTotal = row[3] == "Visual Regression" and 4 or nil,
                description = "<p>This is synthetic descriptive text created for layout testing. "
                    .. "It is intentionally long enough to exercise wrapping, truncation, and the Show more control.</p>"
                    .. "<p>No text or cover art has been copied from any supplied ebook. "
                    .. "Repeated fixture prose keeps every pixel deterministic across test runs. "
                    .. "The final paragraph checks spacing around formatted HTML and the fixed action bar.</p>"
                    .. "<p>Additional neutral words extend this sample beyond the collapsed-description threshold: "
                    .. "alignment typography rhythm margins contrast hierarchy navigation metadata reviews recommendations.</p>",
                categories = { "Speculative Adventure", "Mystery", "Very Long Synthetic Category Name" },
                tags = { "Fixture", "Regression", "Touch interface" },
                publisher = "Deterministic Test Press",
                publishedDate = tostring(2009 + index),
                pageCount = 300 + index * 73,
                language = "English",
                isbn13 = string.format("978000%07d", id),
                coverUpdatedOn = "2026-08-01T12:00:00Z",
                allMetadataLocked = index % 2 == 0,
            },
        }
        result[#result + 1] = book
    end

    -- The rich detail fixture uses multiple formats, ratings and reviews.
    local rich = result[1]
    rich.downloadFiles = {
        rich.primaryFile,
        {
            id = 6001, bookId = rich.id, fileName = "glass-cartographer.pdf",
            fileSizeKb = 18432, bookType = "PDF", extension = "pdf",
            book = true, folderBased = false, isPrimary = false,
        },
    }
    rich.bookFiles = rich.downloadFiles
    rich.metadata.amazonRating = 4.8
    rich.metadata.amazonReviewCount = 28412
    rich.metadata.goodreadsRating = 4.7
    rich.metadata.goodreadsReviewCount = 193840
    rich.metadata.hardcoverRating = 4.6
    rich.metadata.hardcoverReviewCount = 9512
    rich.metadata.bookReviews = {
        { reviewerName = "Visual Reader", rating = 5, body = "A concise synthetic review for checking type and spacing." },
        { reviewerName = "Spoiler Tester", rating = 4, title = "Hidden fixture text", spoiler = true, body = "Synthetic spoiler body." },
        { metadataProvider = "Fixture Source", rating = 4.5, body = "A second visible review used only for deterministic layout." },
        { reviewerName = "Overflow Counter", rating = 3, body = "This fourth review should be represented by the remainder count." },
    }
    return result
end

local function shelves()
    return {
        { id = 71, name = "The Meridian Cycle" },
        { id = 72, name = "The Winter Orchard Chronicles" },
        { id = 73, name = "Currently Reading" },
    }
end

local function stressShelves()
    local result = shelves()
    local names = {
        "Award Winners", "Book Club", "Comfort Reads", "Doorstoppers",
        "Finished This Year", "High Priority", "Library Loans",
        "Needs Metadata Review", "Owned in Print", "Paused",
        "Recommendations", "Very Long Shelf Name for Narrow Screen Testing",
    }
    for index, name in ipairs(names) do
        result[#result + 1] = { id = 80 + index, name = name }
    end
    return result
end

local function libraryScenario(kind, extra)
    local books = fixtureBooks()
    local result = {
        kind = kind,
        books = books,
        libraries = { { id = 41, name = "Visual Test Library" } },
        shelves = shelves(),
    }
    for key, value in pairs(extra or {}) do result[key] = value end
    return result
end

scenarios.wifi_badge_absent = { kind = "wifi", pending = {}, badge_text = nil }
scenarios.wifi_badge_1 = { kind = "wifi", pending = pendingBooks(1), badge_text = "1" }
scenarios.wifi_badge_9_plus = { kind = "wifi", pending = pendingBooks(10), badge_text = "9+" }

scenarios.connection_empty = { kind = "connection", pending = {}, online = true }
scenarios.connection_offline = { kind = "connection", pending = {}, online = false, exercise_connect = true }
scenarios.connection_pending = {
    kind = "connection", online = true,
    pending = { pendingBook(1, "The Observatory Below"), pendingBook(2, "A Harbour Made of Stars") },
}
scenarios.connection_pending_detail = { kind = "connection_detail", online = true, pending = { pendingBook(1, "Position detail fixture") } }
scenarios.connection_long_title = {
    kind = "connection", online = true,
    pending = { pendingBook(1, "A Deliberately Very Long Book Title That Must Stay Readable Without Covering the Device and Server Positions") },
}
scenarios.connection_error = { kind = "connection_error", online = true, pending = { pendingBook(1, "Sync retry fixture") }, error = "test server unavailable" }

scenarios.dashboard_real_library = libraryScenario("dashboard")
scenarios.dashboard_real_library_offline = libraryScenario("dashboard", { offline = true })
scenarios.sidebar_populated = libraryScenario("sidebar", { shelves = stressShelves() })
scenarios.book_list_populated = libraryScenario("book_list", { title = "All Books" })
scenarios.book_list_filtered_empty = libraryScenario("book_list", {
    title = "All Books",
    filters = { author = { ["An Author Who Does Not Exist"] = true } },
})
scenarios.view_options = libraryScenario("view_options")
scenarios.sort_menu_active = libraryScenario("sort_menu", { sort = { key = "pages", dir = "desc" } })
scenarios.filter_menu_active = libraryScenario("filter_menu", {
    filters = { author = { ["Mira Vale"] = true }, genre = { ["Speculative Adventure"] = true } },
})
scenarios.filter_values_selected_long = libraryScenario("filter_values", {
    dimension = "author",
    filters = { author = { ["Mira Vale"] = true, ["An Extremely Long Synthetic Author Name Designed for Narrow Screens"] = true } },
})
scenarios.search_dialog_keyboard = libraryScenario("search_dialog", { title = "All Books" })
scenarios.search_results_long_query = libraryScenario("search_results", {
    parent_title = "All Books",
    query = "A Deliberately Long Fixture Title That Exercises Ellipsis",
    expected_book_id = 1009,
    no_match_query = "No Synthetic Book Has This Exact Title 404",
})

scenarios.book_detail_rich_top = libraryScenario("book_detail", { book_index = 1, detail_position = "top" })
scenarios.book_detail_rich_middle = libraryScenario("book_detail", { book_index = 1, detail_position = "middle" })
scenarios.book_detail_rich_bottom = libraryScenario("book_detail", { book_index = 1, detail_position = "bottom" })
scenarios.book_detail_spoiler_revealed = libraryScenario("book_detail", {
    book_index = 1, detail_position = "bottom", spoiler_revealed = true,
})
scenarios.book_detail_offline = libraryScenario("book_detail", { book_index = 1, offline = true, detail_position = "top" })
scenarios.book_detail_downloaded = libraryScenario("book_detail", { book_index = 1, local_file_id = 5001, detail_position = "top" })
scenarios.download_format_mixed = libraryScenario("download_formats", { book_index = 1, local_file_id = 5001 })

scenarios.login_dialog = libraryScenario("login_dialog")
scenarios.account_switcher_mixed = libraryScenario("account_switcher")
scenarios.download_folder_dialog = libraryScenario("download_folder")
scenarios.main_menu_signed_in = libraryScenario("main_menu")
scenarios.settings_menu = libraryScenario("settings_menu")
scenarios.tailscale_menu = libraryScenario("tailscale_menu")
scenarios.sign_out_confirm = libraryScenario("sign_out_confirm")
scenarios.uninstall_choices = libraryScenario("uninstall_confirm")
scenarios.update_available = libraryScenario("update_available")
scenarios.tailscale_install_prompt = libraryScenario("tailscale_install_prompt")
scenarios.tailscale_status_connected = libraryScenario("tailscale_status")
scenarios.tailscale_auth_instructions = libraryScenario("tailscale_auth")
scenarios.tailscale_auth_qr = libraryScenario("tailscale_auth_qr")
scenarios.sync_main_menu_pending = libraryScenario("sync_main_menu")
scenarios.offline_wifi_prompt = libraryScenario("offline_wifi_prompt")
scenarios.download_progress_50 = libraryScenario("download_progress", { book_index = 1 })
scenarios.long_error_message = libraryScenario("long_error")
scenarios.reader_download_open = libraryScenario("reader_download_open")
scenarios.reader_epub_open = libraryScenario("reader_open")
scenarios.reader_sync_conflict = libraryScenario("reader_sync_conflict")

return scenarios
