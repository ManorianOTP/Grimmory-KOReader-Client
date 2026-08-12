-- Pure EPUB annotation conversion and three-way reconciliation helpers.
-- Network IO and document persistence remain in main.lua.

local AnnotationSync = {}

local TO_SERVER_COLOR = {
    yellow = "#FFC107", green = "#4ADE80", cyan = "#38BDF8",
    pink = "#F472B6", orange = "#FB923C", red = "#FB523C",
    purple = "#F452FC", blue = "#0248F8", gray = "#AAAAAA",
    white = "#FAFAFA",
}
local TO_LOCAL_COLOR = {}
for local_name, server_name in pairs(TO_SERVER_COLOR) do
    TO_LOCAL_COLOR[server_name] = local_name
end

local TO_SERVER_STYLE = {
    lighten = "highlight", underscore = "underline",
    strikeout = "strikethrough", squiggly = "squiggly",
}
local TO_LOCAL_STYLE = {
    highlight = "lighten", underline = "underscore",
    strikethrough = "strikeout", squiggly = "squiggly",
}

local function field(value)
    if value == nil or type(value) == "function" then return "" end
    return tostring(value)
end

local function optional(value)
    -- KOReader's JSON decoder represents JSON null as a callable sentinel.
    if type(value) == "function" then return nil end
    return value
end

local function fingerprint(body)
    return table.concat({ field(body.cfi), field(body.text),
        field(body.chapterTitle), field(body.color), field(body.style),
        field(body.note) }, "\0")
end

local function immutableFingerprint(body)
    return table.concat({ field(body.cfi), field(body.text),
        field(body.chapterTitle) }, "\0")
end

function AnnotationSync.remoteBody(annotation)
    return {
        bookId = optional(annotation.bookId) or optional(annotation.book_id),
        cfi = optional(annotation.cfi),
        chapterTitle = optional(annotation.chapterTitle)
            or optional(annotation.chapter),
        text = optional(annotation.text),
        color = optional(annotation.color),
        style = optional(annotation.style),
        -- Empty string deliberately means "clear note"; the server ignores
        -- JSON null for update requests.
        note = optional(annotation.note) or "",
    }
end

function AnnotationSync.shadowFor(remote)
    local out = {}
    for _, annotation in ipairs(remote or {}) do
        if annotation.id ~= nil then
            local body = AnnotationSync.remoteBody(annotation)
            out[tostring(annotation.id)] = {
                full = fingerprint(body), immutable = immutableFingerprint(body),
            }
        end
    end
    return out
end

local function baseFingerprints(value)
    if type(value) == "table" then return value.full, value.immutable end
    return value, nil -- compatibility with an early single-fingerprint state
end

-- Convert KOReader highlights/notes to server-shaped records. Bookmarks are
-- intentionally ignored: Grimmory requires a non-empty CFI range and text.
function AnnotationSync.fromLocal(annotations, cfi, book_id)
    local out, rejected = {}, {}
    for index, annotation in ipairs(annotations or {}) do
        if annotation.pos0 ~= nil and annotation.pos1 ~= nil then
            local ok, range_or_err = pcall(cfi.xpointerRangeToCFI,
                annotation.pos0, annotation.pos1)
            if ok and type(range_or_err) == "string" then
                -- A converter correction can reveal that an already tracked
                -- immutable server CFI points somewhere other than the local
                -- selection. Canonicalise both ranges through the current
                -- reverse converter so harmless assertion/path spelling
                -- differences do not count as a mismatch. With no trustworthy
                -- origin provenance, any real mismatch must fail closed.
                local immutable_cfi_mismatch = false
                if annotation.grimmory_cfi
                        and type(cfi.cfiRangeToXPointers) == "function" then
                    local local_ok, local0, local1 = pcall(
                        cfi.cfiRangeToXPointers, range_or_err)
                    local server_ok, server0, server1 = pcall(
                        cfi.cfiRangeToXPointers, annotation.grimmory_cfi)
                    immutable_cfi_mismatch = not local_ok or not server_ok
                        or local0 == nil or local1 == nil
                        or server0 == nil or server1 == nil
                        or local0 ~= server0 or local1 ~= server1
                end
                local color = TO_SERVER_COLOR[annotation.color] or "#FFC107"
                if annotation.grimmory_color
                        and annotation.color == annotation.grimmory_local_color then
                    color = annotation.grimmory_color
                end
                local style = TO_SERVER_STYLE[annotation.drawer] or "highlight"
                if annotation.grimmory_style
                        and annotation.drawer == annotation.grimmory_local_style then
                    style = annotation.grimmory_style
                end
                local body = {
                    bookId = book_id,
                    -- epub.js assertions and CREngine can spell the same DOM
                    -- range differently. A tracked highlight's endpoints are
                    -- immutable, so retain its exact server CFI identity. A
                    -- mismatch is deliberately not an automatic migration:
                    -- old records have no trustworthy device/web provenance,
                    -- and Grimmory can only change a CFI via delete+create.
                    cfi = annotation.grimmory_cfi or range_or_err,
                    chapterTitle = annotation.chapter or "",
                    text = annotation.text or "",
                    color = color,
                    style = style,
                    note = annotation.note or "",
                }
                local valid = body.cfi ~= "" and #body.cfi <= 1000
                    and body.text ~= "" and #body.text <= 5000
                    and #body.chapterTitle <= 500 and #body.note <= 5000
                if valid then
                    out[#out + 1] = {
                        index = index,
                        id = annotation.grimmory_id,
                        body = body,
                        fingerprint = fingerprint(body),
                        immutable = immutableFingerprint(body),
                        immutable_cfi_mismatch = immutable_cfi_mismatch,
                    }
                else
                    rejected[#rejected + 1] = { index = index, reason = "invalid-fields" }
                end
            else
                rejected[#rejected + 1] = {
                    index = index, reason = tostring(range_or_err),
                }
            end
        end
    end
    return out, rejected
end

-- Plan changes against the last clean base. Any true concurrent edit is
-- fail-closed: it becomes a conflict and neither side is overwritten.
function AnnotationSync.plan(local_items, remote, shadow)
    shadow = shadow or {}
    local plan = {
        creates = {}, updates = {}, deletes = {}, adopts = {},
        conflicts = {}, drop_local_ids = {},
    }
    local local_by_id, remote_by_id, remote_by_cfi = {}, {}, {}
    local duplicate_conflicts = {}
    for _, item in ipairs(local_items or {}) do
        if item.id ~= nil then
            local id = tostring(item.id)
            if local_by_id[id] then duplicate_conflicts[id] = "duplicate-local-id"
            else local_by_id[id] = item end
        end
    end
    for _, annotation in ipairs(remote or {}) do
        if annotation.id ~= nil then
            local id = tostring(annotation.id)
            if remote_by_id[id] then duplicate_conflicts[id] = "duplicate-remote-id"
            else remote_by_id[id] = annotation end
            if annotation.cfi then
                local prior = remote_by_cfi[annotation.cfi]
                if prior ~= nil then
                    remote_by_cfi[annotation.cfi] = false
                    if type(prior) == "table" and prior.id ~= nil then
                        duplicate_conflicts[tostring(prior.id)] = "duplicate-remote-cfi"
                    end
                    duplicate_conflicts[id] = "duplicate-remote-cfi"
                else
                    remote_by_cfi[annotation.cfi] = annotation
                end
            end
        end
    end

    for _, item in ipairs(local_items or {}) do
        if item.id == nil then
            local exact = remote_by_cfi[item.body.cfi]
            if exact == false then
                -- Multiple remote identities claim this immutable range.
                -- Neither create nor adoption is safe until the server data
                -- is repaired; duplicate_conflicts keeps the book dirty.
            elseif exact then
                plan.adopts[#plan.adopts + 1] = {
                    index = item.index, id = exact.id,
                }
                local_by_id[tostring(exact.id)] = item
            else
                plan.creates[#plan.creates + 1] = item
            end
        end
    end

    for id, base in pairs(shadow) do
        local item, remote_item = local_by_id[id], remote_by_id[id]
        local base_full, base_immutable = baseFingerprints(base)
        local remote_body = remote_item and AnnotationSync.remoteBody(remote_item)
        local remote_full = remote_body and fingerprint(remote_body)
        local remote_immutable = remote_body and immutableFingerprint(remote_body)
        if item and remote_item then
            local local_changed = item.fingerprint ~= base_full
            local remote_changed = remote_full ~= base_full
            if item.immutable_cfi_mismatch then
                plan.conflicts[id] = "immutable-cfi-mismatch"
            elseif local_changed and remote_changed and item.fingerprint ~= remote_full then
                plan.conflicts[id] = "both-edited"
            elseif local_changed then
                if base_immutable and item.immutable ~= base_immutable then
                    plan.conflicts[id] = "immutable-local-edit"
                else
                    plan.updates[#plan.updates + 1] = {
                        id = remote_item.id,
                        body = { color = item.body.color, style = item.body.style,
                            note = item.body.note },
                    }
                end
            end
        elseif not item and remote_item then
            if remote_full ~= base_full then
                plan.conflicts[id] = "local-delete-remote-edit"
            else
                plan.deletes[#plan.deletes + 1] = { id = remote_item.id }
            end
        elseif item and not remote_item then
            if item.fingerprint ~= base_full
                    or (base_immutable and item.immutable ~= base_immutable) then
                plan.conflicts[id] = "local-edit-remote-delete"
            else
                plan.drop_local_ids[id] = true
            end
        end
    end

    for id, item in pairs(local_by_id) do
        if shadow[id] == nil then
            local remote_item = remote_by_id[id]
            if item.immutable_cfi_mismatch then
                plan.conflicts[id] = "immutable-cfi-mismatch"
            elseif not remote_item then
                plan.conflicts[id] = "unbased-local-record"
            else
                local remote_full = fingerprint(AnnotationSync.remoteBody(remote_item))
                if remote_full ~= item.fingerprint then
                    plan.conflicts[id] = "unbased-divergence"
                end
            end
        end
    end

    -- A tracked local record may predate our base store. Adopt the current
    -- remote value without writing; the next clean snapshot establishes base.
    for id, reason in pairs(duplicate_conflicts) do
        plan.conflicts[id] = reason
        plan.drop_local_ids[id] = nil
    end
    local function removeConflictedOperations(items)
        local clean = {}
        for _, item in ipairs(items) do
            if item.id == nil or not plan.conflicts[tostring(item.id)] then
                clean[#clean + 1] = item
            end
        end
        return clean
    end
    plan.updates = removeConflictedOperations(plan.updates)
    plan.deletes = removeConflictedOperations(plan.deletes)
    plan.adopts = removeConflictedOperations(plan.adopts)
    return plan
end

local function localDate(iso)
    if type(iso) ~= "string" then return nil end
    local value = iso:gsub("T", " "):gsub("%.%d+Z$", "Z")
    return value
end

function AnnotationSync.toLocal(remote, cfi)
    local ok, pos0, pos1, conversion_err = pcall(
        cfi.cfiRangeToXPointers, remote.cfi)
    if not ok then return nil, tostring(pos0) end
    if not pos0 or not pos1 then
        return nil, tostring(conversion_err or pos0 or pos1 or "invalid CFI range")
    end
    local local_color = TO_LOCAL_COLOR[remote.color] or "yellow"
    local local_style = TO_LOCAL_STYLE[remote.style] or "lighten"
    return {
        grimmory_id = remote.id,
        grimmory_cfi = remote.cfi,
        grimmory_color = optional(remote.color),
        grimmory_local_color = local_color,
        grimmory_style = optional(remote.style),
        grimmory_local_style = local_style,
        datetime = localDate(remote.createdAt or remote.created_at),
        datetime_updated = localDate(remote.updatedAt or remote.updated_at),
        color = local_color,
        drawer = local_style,
        chapter = optional(remote.chapterTitle) or optional(remote.chapter),
        text = optional(remote.text),
        note = optional(remote.note) ~= "" and optional(remote.note) or nil,
        page = pos0, pos0 = pos0, pos1 = pos1,
    }
end

-- Merge a final server snapshot into local annotations while preserving
-- bookmarks, unsupported local annotations, and explicit conflict records.
function AnnotationSync.mergeLocal(local_annotations, remote, cfi, conflicts)
    conflicts = conflicts or {}
    local conversion_errors = {}
    local remote_by_id, remote_by_cfi = {}, {}
    for _, item in ipairs(remote or {}) do
        if item.id ~= nil then remote_by_id[tostring(item.id)] = item end
        if item.cfi then remote_by_cfi[item.cfi] = item end
    end
    local out, used = {}, {}
    for _, annotation in ipairs(local_annotations or {}) do
        local id = annotation.grimmory_id and tostring(annotation.grimmory_id)
        if not id then
            out[#out + 1] = annotation
        elseif conflicts[id] then
            out[#out + 1] = annotation
            used[id] = true
        elseif remote_by_id[id] then
            local converted, err = AnnotationSync.toLocal(remote_by_id[id], cfi)
            out[#out + 1] = converted or annotation
            if not converted then
                conversion_errors[#conversion_errors + 1] = tostring(err)
            end
            used[id] = true
        end
        -- A clean tracked local whose id disappeared remotely is omitted.
    end
    -- New local creates can be adopted by exact CFI after the final GET.
    for i, annotation in ipairs(out) do
        if not annotation.grimmory_id and annotation.pos0 and annotation.pos1 then
            local ok, range = pcall(cfi.xpointerRangeToCFI,
                annotation.pos0, annotation.pos1)
            local match = ok and remote_by_cfi[range] or nil
            local match_id = match and tostring(match.id) or nil
            if match and not used[match_id] and not conflicts[match_id] then
                local converted, err = AnnotationSync.toLocal(match, cfi)
                if converted then out[i] = converted; used[match_id] = true end
                if not converted then
                    conversion_errors[#conversion_errors + 1] = tostring(err)
                end
            end
        end
    end
    -- Preserve the server's explicit order. Iterating remote_by_id with pairs
    -- made the visible order depend on Lua's hash layout and let tests with a
    -- single remote annotation miss the instability.
    for _, item in ipairs(remote or {}) do
        local id = item.id ~= nil and tostring(item.id) or nil
        if id and not used[id] and not conflicts[id] then
            local converted, err = AnnotationSync.toLocal(item, cfi)
            if converted then out[#out + 1] = converted end
            if not converted then
                conversion_errors[#conversion_errors + 1] = tostring(err)
            end
            used[id] = true
        end
    end
    return out, conversion_errors
end

AnnotationSync.fingerprint = fingerprint
AnnotationSync.immutableFingerprint = immutableFingerprint

return AnnotationSync
