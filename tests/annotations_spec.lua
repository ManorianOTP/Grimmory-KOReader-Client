local AnnotationSync = require("annotations")

local function range_cfi()
    return {
        xpointerRangeToCFI = function(pos0, pos1)
            return "epubcfi(" .. pos0 .. "|" .. pos1 .. ")"
        end,
        cfiRangeToXPointers = function(value)
            local pos0, pos1 = value:match("^epubcfi%((.-)|(.-)%)$")
            return pos0, pos1
        end,
    }
end

local function local_highlight(overrides)
    local annotation = {
        pos0 = "/body/p[1].0",
        pos1 = "/body/p[1].5",
        datetime = "2026-08-09 10:00:00Z",
        datetime_updated = "2026-08-09 10:00:00Z",
        color = "yellow",
        drawer = "lighten",
        chapter = "One",
        text = "hello",
        note = "base note",
    }
    for key, value in pairs(overrides or {}) do annotation[key] = value end
    return annotation
end

local function remote_annotation(overrides)
    local annotation = {
        id = 7,
        bookId = 99,
        cfi = "epubcfi(/body/p[1].0|/body/p[1].5)",
        chapterTitle = "One",
        text = "hello",
        color = "#FFC107",
        style = "highlight",
        note = "base note",
        createdAt = "2026-08-09T10:00:00Z",
        updatedAt = "2026-08-09T10:00:00Z",
    }
    for key, value in pairs(overrides or {}) do annotation[key] = value end
    return annotation
end

describe("annotation conversion", function()
    it("ignores bookmarks and converts supported EPUB highlights", function()
        local bookmark = {
            page = "/body/p[2]", text = "bookmark", datetime = "2026-08-09 10:00:00Z",
        }
        local highlight = local_highlight{
            grimmory_id = 12,
            color = "green",
            drawer = "underscore",
        }
        highlight.note = nil

        local items, rejected = AnnotationSync.fromLocal(
            { bookmark, highlight }, range_cfi(), 99)

        assert.equals(1, #items)
        assert.equals(0, #rejected)
        assert.equals(2, items[1].index)
        assert.equals(12, items[1].id)
        assert.same({
            bookId = 99,
            cfi = "epubcfi(/body/p[1].0|/body/p[1].5)",
            chapterTitle = "One",
            text = "hello",
            color = "#4ADE80",
            style = "underline",
            note = "",
        }, items[1].body)
    end)

    it("converts a remote annotation back to KOReader fields", function()
        local converted = assert(AnnotationSync.toLocal(remote_annotation{
            color = "#4ADE80",
            style = "underline",
            note = "",
            updatedAt = "2026-08-09T10:01:02.123Z",
        }, range_cfi()))

        assert.same({
            grimmory_id = 7,
            grimmory_cfi = "epubcfi(/body/p[1].0|/body/p[1].5)",
            grimmory_color = "#4ADE80",
            grimmory_local_color = "green",
            grimmory_style = "underline",
            grimmory_local_style = "underscore",
            datetime = "2026-08-09 10:00:00Z",
            datetime_updated = "2026-08-09 10:01:02Z",
            color = "green",
            drawer = "underscore",
            chapter = "One",
            text = "hello",
            page = "/body/p[1].0",
            pos0 = "/body/p[1].0",
            pos1 = "/body/p[1].5",
        }, converted)
        local sent = AnnotationSync.fromLocal({ converted }, {
            xpointerRangeToCFI = function()
                return "epubcfi(a-different-but-equivalent-local-spelling)"
            end,
        }, 99)
        assert.equals(remote_annotation().cfi, sent[1].body.cfi,
            "tracked highlights must retain the exact server CFI identity")
        local json_null = function() end
        assert.same({
            bookId = 99,
            cfi = "epubcfi(/body/p[1].0|/body/p[1].5)",
            chapterTitle = "One",
            text = "hello",
            color = "#FFC107",
            style = "highlight",
            note = "",
        }, AnnotationSync.remoteBody(remote_annotation{ note = json_null }))
        local web_yellow = assert(AnnotationSync.toLocal(
            remote_annotation{ color = "#FACC15" }, range_cfi()))
        local preserved = AnnotationSync.fromLocal({ web_yellow }, range_cfi(), 99)
        assert.equals("#FACC15", preserved[1].body.color,
            "an untouched provider color must not drift through a local fallback")
    end)

    it("blocks automatic migration of an immutable tracked CFI without origin provenance", function()
        local old_device_cfi = "epubcfi(/6/2[chapter1]!/4/2/1,/1:0,/1:22)"
        local corrected_cfi = "epubcfi(/6/2[chapter1]!/4/2/1,/1:0,/1:26)"
        local tracked = local_highlight{
            grimmory_id = 7,
            grimmory_cfi = old_device_cfi,
            pos0 = "/body/DocFragment[1]/body/p[1]/text()[1].0",
            pos1 = "/body/DocFragment[1]/body/p[1]/text()[1].26",
            text = "“My fantasies.” He winked.",
        }
        local local_items = AnnotationSync.fromLocal({ tracked }, {
            xpointerRangeToCFI = function() return corrected_cfi end,
            cfiRangeToXPointers = function(range)
                local endpoint = range == old_device_cfi and 22 or 26
                return "/body/DocFragment[1]/body/p[1]/text()[1].0",
                    "/body/DocFragment[1]/body/p[1]/text()[1]."
                        .. tostring(endpoint)
            end,
        }, 99)

        assert.equals(old_device_cfi, local_items[1].body.cfi,
            "a converter change must not silently replace immutable server identity")
        assert.is_true(local_items[1].immutable_cfi_mismatch)

        local remote = { remote_annotation{
            cfi = old_device_cfi,
            text = tracked.text,
        } }
        local plan = AnnotationSync.plan(local_items, remote,
            AnnotationSync.shadowFor(remote))
        assert.equals("immutable-cfi-mismatch", plan.conflicts["7"])
        assert.equals(0, #plan.creates,
            "repair needs an explicit guarded delete+create migration")
        assert.equals(0, #plan.updates)
        assert.equals(0, #plan.deletes)
        local merged = AnnotationSync.mergeLocal({ tracked }, remote, {
            cfiRangeToXPointers = function()
                error("conflicted records must not be reconstructed from server CFI")
            end,
        }, plan.conflicts)
        assert.equals(tracked, merged[1],
            "ambiguous migration must preserve the current local selection")
    end)

    it("does not flag equivalent tracked CFI spellings with identical endpoints", function()
        local server_spelling = "epubcfi(/6/2[chapter1]!/4/2[p],/1:0,/1:5)"
        local local_spelling = "epubcfi(/6/2!/4/2,/1:0,/1:5)"
        local item = local_highlight{
            grimmory_id = 7,
            grimmory_cfi = server_spelling,
        }
        local converted = AnnotationSync.fromLocal({ item }, {
            xpointerRangeToCFI = function() return local_spelling end,
            cfiRangeToXPointers = function()
                return "/body/DocFragment[1]/body/p[1]/text()[1].0",
                    "/body/DocFragment[1]/body/p[1]/text()[1].5"
            end,
        }, 99)
        assert.is_false(converted[1].immutable_cfi_mismatch)
    end)

    it("adopts an identical server annotation by exact CFI without creating", function()
        local local_items = AnnotationSync.fromLocal(
            { local_highlight{ note = "same" } }, range_cfi(), 99)
        local remote = { remote_annotation{ note = "same" } }

        local plan = AnnotationSync.plan(local_items, remote, {})

        assert.same({
            creates = {}, updates = {}, deletes = {},
            adopts = { { index = 1, id = 7 } },
            conflicts = {}, drop_local_ids = {},
        }, plan)

        local merged = AnnotationSync.mergeLocal(
            { local_highlight{ note = "same" } }, remote, range_cfi(), {})
        assert.equals(1, #merged)
        assert.equals(7, merged[1].grimmory_id)
    end)

    it("preserves remote order and returns no unasserted merge errors", function()
        local bookmark = { page = "/bookmark", text = "bookmark" }
        local remote = {
            remote_annotation{ id = 30, text = "third", cfi = "epubcfi(a|b)" },
            remote_annotation{ id = 10, text = "first", cfi = "epubcfi(c|d)" },
            remote_annotation{ id = 20, text = "second", cfi = "epubcfi(e|f)" },
        }
        local cfi = {
            cfiRangeToXPointers = function(value)
                local first, second = value:match("^epubcfi%((.-)|(.-)%)$")
                return first, second
            end,
        }

        local merged, errors = AnnotationSync.mergeLocal({ bookmark }, remote, cfi, {})

        assert.same({}, errors)
        assert.equals(4, #merged)
        assert.equals(bookmark, merged[1])
        assert.same({ 30, 10, 20 }, {
            merged[2].grimmory_id, merged[3].grimmory_id,
            merged[4].grimmory_id,
        })
        assert.same({ "third", "first", "second" }, {
            merged[2].text, merged[3].text, merged[4].text,
        })
    end)

    it("preserves an untracked local annotation when exact-CFI fields diverge", function()
        local original = local_highlight{ note = "device note" }
        local local_items = AnnotationSync.fromLocal({ original }, range_cfi(), 99)
        local remote = { remote_annotation{ note = "server note" } }

        local plan = AnnotationSync.plan(local_items, remote, {})
        assert.same({
            creates = {}, updates = {}, deletes = {}, adopts = {},
            conflicts = { ["7"] = "unbased-divergence" },
            drop_local_ids = {},
        }, plan)

        local merged = AnnotationSync.mergeLocal(
            { original }, remote, range_cfi(), plan.conflicts)
        assert.equals(1, #merged)
        assert.equals("device note", merged[1].note)
        assert.is_nil(merged[1].grimmory_id,
            "a conflict must not silently adopt and overwrite the local record")
    end)

    it("retains a tracked local record and reports a remote CFI conversion failure", function()
        local original = local_highlight{ grimmory_id = 7 }
        local broken_cfi = {
            cfiRangeToXPointers = function() return nil, nil, "unsupported range" end,
        }

        local merged, errors = AnnotationSync.mergeLocal(
            { original }, { remote_annotation() }, broken_cfi, {})

        assert.equals(1, #merged)
        assert.equals(original, merged[1])
        assert.same({ "unsupported range" }, errors)
    end)
end)

describe("annotation three-way planning", function()
    it("fails closed on duplicate local IDs, remote IDs, and remote CFIs", function()
        local local_item = AnnotationSync.fromLocal({
            local_highlight{ grimmory_id = 7 },
        }, range_cfi(), 99)[1]
        local duplicate_local = AnnotationSync.plan(
            { local_item, local_item }, { remote_annotation() }, {})
        assert.same({ ["7"] = "duplicate-local-id" }, duplicate_local.conflicts)
        assert.same({}, duplicate_local.updates)
        assert.same({}, duplicate_local.deletes)
        assert.same({}, duplicate_local.adopts)

        local duplicate_remote = AnnotationSync.plan(
            { local_item }, { remote_annotation(), remote_annotation() }, {})
        assert.same({ ["7"] = "duplicate-remote-cfi" }, duplicate_remote.conflicts)
        assert.same({}, duplicate_remote.updates)
        assert.same({}, duplicate_remote.deletes)

        local same_cfi = remote_annotation{ id = 8 }
        local ambiguous = AnnotationSync.plan(
            AnnotationSync.fromLocal({ local_highlight() }, range_cfi(), 99),
            { remote_annotation(), same_cfi }, {})
        assert.same({
            ["7"] = "duplicate-remote-cfi",
            ["8"] = "duplicate-remote-cfi",
        }, ambiguous.conflicts)
        assert.same({}, ambiguous.creates)
        assert.same({}, ambiguous.adopts)
    end)

    it("fails closed when both device and server edited a tracked annotation", function()
        local base = remote_annotation()
        local shadow = AnnotationSync.shadowFor({ base })
        local local_items = AnnotationSync.fromLocal({
            local_highlight{ grimmory_id = 7, note = "device edit" },
        }, range_cfi(), 99)
        local remote = { remote_annotation{ color = "#4ADE80", note = "server edit" } }

        local plan = AnnotationSync.plan(local_items, remote, shadow)

        assert.same({
            creates = {}, updates = {}, deletes = {}, adopts = {},
            conflicts = { ["7"] = "both-edited" }, drop_local_ids = {},
        }, plan)
    end)

    it("distinguishes clean deletion from both delete/edit conflict directions", function()
        local base = remote_annotation()
        local shadow = AnnotationSync.shadowFor({ base })
        local clean_local = AnnotationSync.fromLocal({
            local_highlight{ grimmory_id = 7 },
        }, range_cfi(), 99)
        local edited_local = AnnotationSync.fromLocal({
            local_highlight{ grimmory_id = 7, note = "device edit" },
        }, range_cfi(), 99)

        local local_delete = AnnotationSync.plan({}, { base }, shadow)
        assert.same({
            creates = {}, updates = {}, deletes = { { id = 7 } }, adopts = {},
            conflicts = {}, drop_local_ids = {},
        }, local_delete)

        local local_delete_remote_edit = AnnotationSync.plan({}, {
            remote_annotation{ note = "server edit" },
        }, shadow)
        assert.same({
            creates = {}, updates = {}, deletes = {}, adopts = {},
            conflicts = { ["7"] = "local-delete-remote-edit" },
            drop_local_ids = {},
        }, local_delete_remote_edit)

        local remote_delete = AnnotationSync.plan(clean_local, {}, shadow)
        assert.same({
            creates = {}, updates = {}, deletes = {}, adopts = {},
            conflicts = {}, drop_local_ids = { ["7"] = true },
        }, remote_delete)

        local remote_delete_local_edit = AnnotationSync.plan(edited_local, {}, shadow)
        assert.same({
            creates = {}, updates = {}, deletes = {}, adopts = {},
            conflicts = { ["7"] = "local-edit-remote-delete" },
            drop_local_ids = {},
        }, remote_delete_local_edit)
    end)
end)
