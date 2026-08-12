-- Additive Grimmory shelf -> KOReader collection reconciliation.
-- Only namespaced collections carrying our scoped ownership metadata are
-- modified. Files, unrelated collections, and user-added members are never
-- deleted.

local ShelfCollections = {}
ShelfCollections.__index = ShelfCollections

local function deepCopy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local out = {}
    seen[value] = out
    for key, child in pairs(value) do
        out[deepCopy(key, seen)] = deepCopy(child, seen)
    end
    return out
end

local function identity(server_url, username, shelf_id)
    return (server_url or "") .. "\n" .. (username or "") .. "\n"
        .. tostring(shelf_id)
end

local function ownedBy(meta, server_url, username, shelf_id)
    return type(meta) == "table" and meta.schema == 1
        and identity(meta.server_url, meta.username, meta.shelf_id)
            == identity(server_url, username, shelf_id)
end

local function shelfId(value)
    if type(value) == "table" then return value.id end
    return value
end

function ShelfCollections.new(opts)
    opts = opts or {}
    return setmetatable({
        read_collection = opts.read_collection or require("readcollection"),
        realpath = opts.realpath or require("ffi/util").realpath,
    }, ShelfCollections)
end

local function findCaseInsensitive(coll, wanted)
    wanted = wanted:lower()
    for name in pairs(coll or {}) do
        if name:lower() == wanted then return name end
    end
end

local function ownedName(read_collection, server_url, username, wanted_id)
    for name, settings in pairs(read_collection.coll_settings or {}) do
        local meta = settings and settings.grimmory_shelf
        if ownedBy(meta, server_url, username, wanted_id) then
            return name, meta
        end
    end
end

local function uniqueName(read_collection, base, server_url, username, id)
    local candidate = base
    local collision = findCaseInsensitive(read_collection.coll, candidate)
    if collision then
        local settings = read_collection.coll_settings[collision]
        if ownedBy(settings and settings.grimmory_shelf,
                server_url, username, id) then return collision end
        candidate = base .. " (" .. tostring(username or "account")
            .. " · " .. tostring(id) .. ")"
    end
    local suffix = 2
    while findCaseInsensitive(read_collection.coll, candidate) do
        candidate = base .. " (" .. tostring(username or "account")
            .. " · " .. tostring(id) .. " · " .. tostring(suffix) .. ")"
        suffix = suffix + 1
    end
    return candidate
end

function ShelfCollections:reconcile(server_url, username, shelves, books,
        local_files_by_book)
    local rc = self.read_collection
    local ok_read, read_err = pcall(rc._read, rc)
    if not ok_read then return nil, tostring(read_err) end
    rc.coll = rc.coll or {}
    rc.coll_settings = rc.coll_settings or {}
    -- Reconciliation is one logical transaction. KOReader's collection API
    -- mutates its in-memory maps before write(), so an adapter exception or an
    -- explicit false result must restore the exact pre-run state rather than
    -- leave ownership metadata and collection contents disagreeing.
    local before_coll = deepCopy(rc.coll)
    local before_settings = deepCopy(rc.coll_settings)
    local function abort(reason)
        rc.coll = before_coll
        rc.coll_settings = before_settings
        return nil, tostring(reason or "collection mutation failed")
    end

    local remote = {}
    for _, shelf in ipairs(shelves or {}) do
        if type(shelf) == "table" and shelf.id ~= nil
                and type(shelf.name) == "string" and shelf.name ~= "" then
            remote[tostring(shelf.id)] = shelf
        end
    end

    local desired = {}
    for id in pairs(remote) do desired[id] = {} end
    for _, book in ipairs(books or {}) do
        local paths = local_files_by_book[tostring(book.id)] or {}
        for _, raw_shelf in ipairs(book.shelves or {}) do
            local id = tostring(shelfId(raw_shelf) or "")
            if remote[id] then
                for _, path in ipairs(paths) do
                    local resolved = self.realpath(path)
                    if resolved then desired[id][resolved] = true end
                end
            end
        end
    end

    local changed, summary = false, { created = 0, added = 0, removed = 0 }
    local ids = {}
    for id in pairs(remote) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local shelf = remote[id]
        local name, meta = ownedName(rc, server_url, username, shelf.id)
        local generated = "Grimmory — " .. shelf.name
        if not name then
            name = uniqueName(rc, generated, server_url, username, shelf.id)
            local ok_add, add_result = pcall(rc.addCollection, rc, name)
            if not ok_add or add_result == false then
                return abort(ok_add and "addCollection returned false" or add_result)
            end
            if type(rc.coll[name]) ~= "table"
                    or type(rc.coll_settings[name]) ~= "table" then
                return abort("addCollection did not create collection state")
            end
            meta = {
                schema = 1, server_url = server_url, username = username,
                shelf_id = shelf.id, remote_name = shelf.name,
                generated_name = name, managed_paths = {}, remote_missing = false,
            }
            rc.coll_settings[name].grimmory_shelf = meta
            changed, summary.created = true, summary.created + 1
        elseif meta.remote_name ~= shelf.name then
            local target = uniqueName(rc, generated, server_url, username, shelf.id)
            if name == meta.generated_name and target ~= name then
                local ok_rename, rename_result = pcall(
                    rc.renameCollection, rc, name, target)
                if not ok_rename or rename_result == false
                        or type(rc.coll[target]) ~= "table"
                        or type(rc.coll_settings[target]) ~= "table" then
                    return abort(ok_rename
                        and "renameCollection did not create target state"
                        or rename_result)
                end
                name = target
                meta = rc.coll_settings[name].grimmory_shelf
            end
            meta.remote_name = shelf.name
            meta.generated_name = meta.generated_name or name
            changed = true
        end
        meta.remote_missing = false
        meta.managed_paths = meta.managed_paths or {}
        local wanted = desired[id]
        for path in pairs(meta.managed_paths) do
            if not wanted[path] then
                if rc.coll[name] and rc.coll[name][path] then
                    local ok_remove, remove_result = pcall(
                        rc.removeItem, rc, path, name, true)
                    if not ok_remove or remove_result == false then
                        return abort(ok_remove
                            and "removeItem returned false" or remove_result)
                    end
                    summary.removed = summary.removed + 1
                end
                meta.managed_paths[path] = nil
                changed = true
            end
        end
        for path in pairs(wanted) do
            if not (rc.coll[name] and rc.coll[name][path]) then
                local ok_add, add_result = pcall(rc.addItem, rc, path, name)
                if not ok_add or add_result == false then
                    return abort(ok_add and "addItem returned false" or add_result)
                end
                meta.managed_paths[path] = true
                summary.added = summary.added + 1
                changed = true
            end
        end
    end

    -- A deleted server shelf is frozen in place. This retains its collection,
    -- contents, and user edits while making its stale state explicit.
    for _, settings in pairs(rc.coll_settings) do
        local meta = settings and settings.grimmory_shelf
        if type(meta) == "table" and meta.schema == 1
                and meta.server_url == server_url and meta.username == username
                and not remote[tostring(meta.shelf_id)]
                and meta.remote_missing ~= true then
            meta.remote_missing = true
            changed = true
        end
    end

    if changed then
        local ok_write, write_err = pcall(rc.write, rc)
        if not ok_write then return abort(write_err) end
    end
    summary.changed = changed
    return summary, nil
end

return ShelfCollections
