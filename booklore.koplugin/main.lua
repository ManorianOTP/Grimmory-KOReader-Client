local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local InputDialog = require("ui/widget/inputdialog")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local ImageWidget = require("ui/widget/imagewidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local LineWidget = require("ui/widget/linewidget")
local Button = require("ui/widget/button")
local GestureRange = require("ui/gesturerange")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local Size = require("ui/size")
local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local Device = require("device")
local Screen = Device.screen
local json = require("json")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local T = require("ffi/util").template

local BookLoreApi = require("api")
local BookLoreView = require("view")
local LibraryCache = require("library_cache")
local Downloads = require("downloads")
local Session = require("session")
local Tailscale = require("tailscale")

-- Absolute path to this plugin's directory, for loading bundled assets
-- (icons/*.svg). Derived from this chunk's source so it works wherever the
-- plugin is deployed on device.
local PLUGIN_DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

local BookLore = WidgetContainer:extend{
    name = "booklore",
    is_doc_only = false,
}


-- init() runs once per ReaderUI/FileManager instantiation (i.e. on every
-- document open); this module-level flag scopes the Tailscale autostart
-- attempt to once per KOReader process.
local tailscale_autostart_attempted = false

-- ─── Initialisation ──────────────────────────────────────────────────

function BookLore:init()
    self.settings = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/booklore.lua"
    )
    self.server_url = self.settings:readSetting("server_url", "http://192.168.1.50:6060")
    self.username = self.settings:readSetting("username", "")

    -- Token lifecycle (load, silent refresh, 401 retry, clearing) lives in
    -- session.lua; the only UI side effect is the expiry notice injected here.
    self.session = Session.new{
        settings = self.settings,
        api = BookLoreApi,
        on_expired = function()
            UIManager:show(InfoMessage:new{ text = _("Session expired. Please login again.") })
        end,
    }

    self.download_dir = self.settings:readSetting(
        "download_dir",
        DataStorage:getFullDataDir() .. "/booklore/downloads"
    )
    self.downloads = Downloads.new{ download_dir = self.download_dir }

    self.tailscale = Tailscale.new{
        wifi_is_on = function() return NetworkMgr:isWifiOn() end,
    }

    self.view_state = {
        sort = {
            key = self.settings:readSetting("view_sort_key", "title"),
            dir = self.settings:readSetting("view_sort_dir", "asc"),
        },
        combine = self.settings:readSetting("view_combine", "AND"),
        filters = {},
    }

    -- True while the library is rendered read-only from the on-disk snapshot
    -- (device offline / server unreachable). Recomputed on every browseLibrary.
    self.offline_mode = false

    if self.settings:readSetting("tailscale_autostart") == true
            and not tailscale_autostart_attempted then
        tailscale_autostart_attempted = true
        -- Delay past startup so the attempt never slows boot or competes
        -- with the first paint; autostart() itself is silent (logs only).
        UIManager:scheduleIn(5, function() self.tailscale:autostart() end)
    end

    self.ui.menu:registerToMainMenu(self)
end

function BookLore:addToMainMenu(menu_items)
    menu_items.booklore = {
        text = _("BookLore"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Login"),
                callback = function() self:showLoginDialog() end,
            },
            {
                text = _("Browse Library"),
                callback = function() self:browseLibrary() end,
            },
            {
                text = _("Tailscale"),
                sub_item_table = {
                    {
                        text = _("Status"),
                        callback = function() self:showTailscaleStatus() end,
                    },
                    {
                        text = _("Connect"),
                        callback = function() self:tailscaleConnect() end,
                    },
                    {
                        text = _("Disconnect"),
                        callback = function() self:tailscaleDisconnect() end,
                    },
                    {
                        text = _("Autostart on KOReader start"),
                        keep_menu_open = true,
                        checked_func = function()
                            return self.settings:readSetting("tailscale_autostart") == true
                        end,
                        callback = function()
                            local enabled = self.settings:readSetting("tailscale_autostart") == true
                            self.settings:saveSetting("tailscale_autostart", not enabled)
                            self.settings:flush()
                        end,
                    },
                },
            },
        },
    }
end

-- ─── Tailscale ───────────────────────────────────────────────────────
-- Process logic (install pipeline, daemon detection, up/down/status,
-- silent autostart) lives in tailscale.lua so it is unit-testable off
-- device; the wrappers below own the dialogs and the QR auth flow.

--- Install Tailscale from static ARM binaries (UI shell around
-- Tailscale:install()).
function BookLore:tailscaleInstall()
    if not NetworkMgr:isWifiOn() then NetworkMgr:turnOnWifi() end

    UIManager:show(InfoMessage:new{
        text = _("Installing Tailscale…\n\nFetching latest version…"),
        timeout = 60,
    })

    UIManager:scheduleIn(0.2, function()
        local version, err = self.tailscale:install()
        if version then
            UIManager:show(InfoMessage:new{
                text = T(_("Tailscale %1 installed successfully.\n\nUse Connect to join your tailnet."), version),
            })
        else
            UIManager:show(InfoMessage:new{
                text = T(_("Tailscale install failed:\n%1"), tostring(err)),
                width = Screen:getWidth() * 0.9,
            })
        end
    end)
end

--- Prompt to install Tailscale if not present.
-- If already installed, calls the provided callback immediately.
-- @param then_do function: called after installation succeeds or if already installed
function BookLore:ensureTailscaleInstalled(then_do)
    if self.tailscale:isInstalled() then
        if then_do then then_do() end
        return
    end

    UIManager:show(ConfirmBox:new{
        text = _("Tailscale is not installed.\n\n"
            .. "Download and install the latest stable release?\n"
            .. "(Requires Wi-Fi — approx. 30 MB)"),
        ok_text = _("Install"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            self:tailscaleInstall()
        end,
    })
end

function BookLore:showTailscaleStatus()
    if not self.tailscale:isInstalled() then
        self:ensureTailscaleInstalled()
        return
    end

    if not self.tailscale:isDaemonRunning() then
        UIManager:show(InfoMessage:new{
            text = _("Tailscale is installed but the daemon is not running.\n\n"
                .. "Use Connect to start it."),
        })
        return
    end

    local output, code = self.tailscale:status()
    if code ~= 0 then
        local msg = output ~= "" and output or "Unknown error."
        UIManager:show(InfoMessage:new{
            text = T(_("tailscale status failed:\n%1"), msg),
            width = Screen:getWidth() * 0.9,
        })
        return
    end
    UIManager:show(InfoMessage:new{
        text = output,
        width = Screen:getWidth() * 0.9,
    })
end

function BookLore:tailscaleConnect()
    if not self.tailscale:isInstalled() then
        self:ensureTailscaleInstalled()
        return
    end

    if not NetworkMgr:isWifiOn() then NetworkMgr:turnOnWifi() end

    -- Start daemon if not running
    if not self.tailscale:isDaemonRunning() then
        UIManager:show(InfoMessage:new{
            text = _("Starting tailscaled…"),
            timeout = 3,
        })

        UIManager:scheduleIn(0.2, function()
            self.tailscale:startDaemon(function(ok, err)
                if not ok then
                    UIManager:show(InfoMessage:new{
                        text = T(_("Failed to start tailscaled:\n%1"), tostring(err)),
                        width = Screen:getWidth() * 0.9,
                    })
                    return
                end
                -- Daemon is running, now bring tailscale up
                self:_tailscaleUp()
            end)
        end)
        return
    end

    -- Daemon already running — check if already connected
    local connected, status_out = self.tailscale:isConnected()
    if connected then
        UIManager:show(InfoMessage:new{
            text = T(_("Tailscale is already connected.\n\n%1"), status_out),
            width = Screen:getWidth() * 0.9,
        })
        return
    end

    self:_tailscaleUp()
end

--- Internal: run `tailscale up` and handle the auth URL flow.
function BookLore:_tailscaleUp()
    UIManager:show(InfoMessage:new{
        text = _("Connecting to Tailscale…"),
        timeout = 3,
    })

    UIManager:scheduleIn(0.2, function()
        local ok, auth_url, output = self.tailscale:up()
        if ok then
            UIManager:show(InfoMessage:new{
                text = _("Tailscale connected successfully."),
            })
        elseif auth_url then
            -- Try to show a QR code for easy scanning
            local qr_ok, QRMessage = pcall(require, "ui/widget/qrmessage")
            if qr_ok and QRMessage then
                -- Show instructions first, then QR on dismiss
                UIManager:show(InfoMessage:new{
                    text = _("Tailscale authentication required.\n\n"
                        .. "Scan the QR code on the next screen "
                        .. "with your phone to log in.\n\n"
                        .. "Tap anywhere to show the QR code."),
                    dismiss_callback = function()
                        UIManager:show(QRMessage:new{
                            text = auth_url,
                            width = Screen:getWidth() * 0.9,
                            height = Screen:getHeight() * 0.9,
                        })
                    end,
                })
            else
                -- Fallback: plain text
                UIManager:show(InfoMessage:new{
                    text = T(_("Auth required. Visit this URL on another device:\n\n%1"), auth_url),
                    width = Screen:getWidth() * 0.9,
                })
            end
        else
            local msg = (output and output ~= "") and output or "Unknown error."
            UIManager:show(InfoMessage:new{
                text = T(_("Tailscale connect failed:\n%1"), msg),
                width = Screen:getWidth() * 0.9,
            })
        end
    end)
end

function BookLore:tailscaleDisconnect()
    if not self.tailscale:isInstalled() then
        UIManager:show(InfoMessage:new{
            text = _("Tailscale is not installed."),
        })
        return
    end

    local ok, output = self.tailscale:down()
    if ok then
        UIManager:show(InfoMessage:new{
            text = _("Tailscale disconnected."),
        })
    else
        local msg = output ~= "" and output or "Unknown error."
        UIManager:show(InfoMessage:new{
            text = T(_("Tailscale disconnect failed:\n%1"), msg),
        })
    end
end

-- ─── Login ───────────────────────────────────────────────────────────

function BookLore:showLoginDialog()
    self.login_dialog = MultiInputDialog:new{
        title = _("BookLore Login"),
        fields = {
            { text = self.server_url, hint = _("Server URL") },
            { text = self.username, hint = _("Username") },
            { text = "", hint = _("Password"), text_type = "password" },
        },
        buttons = {{
            {
                text = _("Cancel"), id = "close",
                callback = function() UIManager:close(self.login_dialog) end,
            },
            {
                text = _("Login"), is_enter_default = true,
                callback = function()
                    local f = self.login_dialog:getFields()
                    UIManager:close(self.login_dialog)
                    self:doLogin(f[1], f[2], f[3])
                end,
            },
        }},
    }
    UIManager:show(self.login_dialog)
    self.login_dialog:onShowKeyboard()
end

function BookLore:doLogin(server_url, username, password)
    if not NetworkMgr:isWifiOn() then NetworkMgr:turnOnWifi() end

    local token, refresh_token, err = BookLoreApi:login(server_url, username, password)
    if token and refresh_token then
        -- Token persistence rationale (refresh-token storage, token_time
        -- seeding) is documented in session.lua. (ref: DL-002, DL-004, DL-010)
        self.session:setTokens(token, refresh_token)
        self.server_url = server_url
        self.username = username
        self.settings:saveSetting("server_url", server_url)
        self.settings:saveSetting("username", username)
        self.settings:flush()
        UIManager:show(InfoMessage:new{ text = _("Logged in successfully.") })
    else
        UIManager:show(InfoMessage:new{
            text = T(_("Login failed:\n%1"), tostring(err)),
        })
    end
end

-- ─── Data loading ────────────────────────────────────────────────────

-- apiCall: thin delegate to the session dispatcher so the many existing
-- call sites keep their (method_name, ...) shape. Token splicing, silent
-- refresh, and the 401 retry state machine live in session.lua.
function BookLore:apiCall(method_name, ...)
    return self.session:call(self.server_url, method_name, ...)
end

-- ─── Offline library snapshot ────────────────────────────────────────
-- Persisted copy of the last successful library fetch so the library opens
-- read-only when the device is offline but was logged in before. The on-disk
-- read/write + account-match logic lives in the standalone library_cache
-- module so it is unit-testable without the UI deps.

function BookLore:saveSnapshot(books, shelves, libraries)
    LibraryCache.save(self.username, self.server_url, books, shelves, libraries)
end

function BookLore:loadSnapshot()
    return LibraryCache.load(self.username, self.server_url)
end

-- Bucket books into shelves / unshelved. Shared by the online and offline
-- render paths so the dashboard groupings are identical either way. Numeric
-- loops keep `_` bound to gettext (never shadow it near _("…") strings).
function BookLore:indexShelves(books)
    self.shelf_books = {}
    self.unshelved_books = {}
    for i = 1, #books do
        local book = books[i]
        local on_shelf = false
        if type(book.shelves) == "table" then
            for j = 1, #book.shelves do
                local shelf = book.shelves[j]
                local sid = type(shelf) == "table" and (shelf.id or shelf.shelfId) or nil
                if sid then
                    on_shelf = true
                    if not self.shelf_books[sid] then self.shelf_books[sid] = {} end
                    table.insert(self.shelf_books[sid], book)
                end
            end
        end
        if not on_shelf then table.insert(self.unshelved_books, book) end
    end
end

-- Short human-readable age for the offline banner, e.g. "3 hr ago".
function BookLore:formatRelativeTime(ts)
    if type(ts) ~= "number" then return _("a while ago") end
    local diff = os.time() - ts
    if diff < 0 then diff = 0 end   -- clock skew / future ts => "just now"
    if diff < 60 then
        return _("just now")
    elseif diff < 3600 then
        return T(_("%1 min ago"), math.floor(diff / 60))
    elseif diff < 86400 then
        return T(_("%1 hr ago"), math.floor(diff / 3600))
    else
        local days = math.floor(diff / 86400)
        if days == 1 then return _("yesterday") end
        return T(_("%1 days ago"), days)
    end
end

-- Render the dashboard from a cached snapshot, read-only (no network).
function BookLore:renderOfflineLibrary(snap)
    self.offline_mode = true
    self._snapshot_fetched_at = snap.fetched_at
    self.cached_books = snap.books
    self.cached_shelves = (type(snap.shelves) == "table") and snap.shelves or {}
    self.cached_libraries = (type(snap.libraries) == "table") and snap.libraries or {}
    self:indexShelves(snap.books)
    self.cover_cache_dir = DataStorage:getDataDir() .. "/cache/booklore"
    lfs.mkdir(self.cover_cache_dir)
    self:showDashboard()
end

function BookLore:browseLibrary()
    local logged_in = self.session:isLoggedIn()

    -- The snapshot is loaded lazily: decoding a large library JSON from disk
    -- on every open would penalize the common online path, which never needs
    -- it. Only the logged-out gate (here) and the offline/fallback paths load.
    local snap
    if not logged_in then
        snap = self:loadSnapshot()
        if not snap then
            UIManager:show(InfoMessage:new{
                text = _("Not logged in. Please login first."),
            })
            return
        end
    end

    -- When WiFi is off, ask before turning it on rather than connecting
    -- automatically; declining continues in the offline cache.
    if not NetworkMgr:isWifiOn() then
        UIManager:show(ConfirmBox:new{
            text = _("WiFi is off. Turn it on to load the latest library?"),
            ok_text = _("Turn on WiFi"),
            ok_callback = function()
                NetworkMgr:turnOnWifi(function()
                    self:fetchAndShowLibrary(snap)
                end)
            end,
            cancel_text = _("Stay offline"),
            cancel_callback = function()
                snap = snap or self:loadSnapshot()
                if snap then
                    self:renderOfflineLibrary(snap)
                else
                    UIManager:show(InfoMessage:new{
                        text = _("No cached library available offline. Turn on WiFi to load it."),
                    })
                end
            end,
        })
        return
    end

    self:fetchAndShowLibrary(snap)
end

-- Fetch the library online and render it. On a network-class failure, fall back
-- to the cached snapshot. `snap` is non-nil only when browseLibrary's
-- logged-out gate already loaded it; otherwise the fallback loads on demand.
function BookLore:fetchAndShowLibrary(snap)
    local books, err = self:apiCall("getBooks")
    if not books then
        -- apiCall already surfaced Session-expired on 401 paths. For a
        -- network-class failure, fall back to the cached snapshot if we have one.
        -- "not-logged-in" (tokens cleared by a prior 401) is NOT a server-confirmed
        -- auth failure -- we simply hold no credentials to try -- so it falls back
        -- to the cached library like any offline case.
        local auth_err = err and (err:match("^HTTP 401") or err == "refresh-in-progress")
        if not auth_err then
            snap = snap or self:loadSnapshot()
            if snap then
                self:renderOfflineLibrary(snap)
                return
            end
            UIManager:show(InfoMessage:new{
                text = T(_("Failed to fetch books:\n%1"), tostring(err)),
            })
        end
        return
    end

    self.offline_mode = false

    if type(books) == "table" and type(books.content) == "table" then
        books = books.content
    end

    if type(books) ~= "table" or #books == 0 then
        UIManager:show(InfoMessage:new{ text = _("No books found.") })
        return
    end

    self.cached_books = books

    local shelves = self:apiCall("getShelves")
    self.cached_shelves = (type(shelves) == "table") and shelves or {}

    local libraries = self:apiCall("getLibraries")
    self.cached_libraries = (type(libraries) == "table") and libraries or {}

    -- Persist a fresh snapshot for offline use.
    self:saveSnapshot(books, self.cached_shelves, self.cached_libraries)

    self:indexShelves(books)

    -- Ensure cover cache directory exists
    self.cover_cache_dir = DataStorage:getDataDir() .. "/cache/booklore"
    lfs.mkdir(self.cover_cache_dir)

    self:showDashboard()
end

-- ─── UI helpers ──────────────────────────────────────────────────────

-- WiFi status indicator for the top bar: a wifi glyph that is crossed out in
-- offline mode. Tapping it reports the connection state (and, when offline, the
-- cached-library age). Built as a fixed-size tappable image so buildTopBar can
-- give the search field the remaining width and never overflow screen_w.
function BookLore:buildWifiButton()
    local icon_sz = Screen:scaleBySize(24)
    local name = self.offline_mode and "wifi_off" or "wifi"
    local glyph
    local path = PLUGIN_DIR .. "icons/" .. name .. ".svg"
    if lfs.attributes(path, "mode") == "file" then
        local ok, img = pcall(ImageWidget.new, ImageWidget, {
            file = path,
            width = icon_sz,
            height = icon_sz,
            scale_factor = 0,
            alpha = true,
        })
        if ok and img then glyph = img end
    end
    if not glyph then
        -- Text fallback if the SVG asset is missing/unreadable.
        glyph = TextWidget:new{
            text = self.offline_mode and "⚠" or "≈",
            face = Font:getFace("cfont", 20),
        }
    end

    local frame = FrameContainer:new{
        bordersize = 0,
        padding_h = Size.padding.large,
        padding_v = Size.padding.default,
        background = Blitbuffer.COLOR_WHITE,
        glyph,
    }

    -- Tappable wrapper (same idiom as buildCoverCard): range references btn.dimen
    -- so the gesture box tracks the widget's painted position.
    local btn = InputContainer:new{
        dimen = Geom:new{ w = frame:getSize().w, h = frame:getSize().h },
    }
    table.insert(btn, frame)
    btn.ges_events = {
        Tap = {
            GestureRange:new{ ges = "tap", range = btn.dimen },
        },
    }
    btn.onTap = function()
        local text
        if self.offline_mode then
            text = T(_("Offline — showing cached library, last synced %1."),
                self:formatRelativeTime(self._snapshot_fetched_at))
        else
            text = _("Online.")
        end
        UIManager:show(InfoMessage:new{ text = text })
        return true
    end
    return btn
end

--- Build the top bar: [☰] [Search…                    ] [wifi] [✕]
-- @param on_menu function: called when ☰ is tapped
-- @param on_search function: called when search is tapped
-- @return widget: the top bar row
function BookLore:buildTopBar(on_menu, on_search, on_close)
    local screen_w = Screen:getWidth()
    local padding = Size.padding.large

    local menu_btn = Button:new{
        text = " ☰ ",
        callback = on_menu,
        radius = 0,
        no_focus = true,
        padding_h = Size.padding.large,
        padding_v = Size.padding.default,
    }

    local wifi_btn = self:buildWifiButton()

    local close_btn = Button:new{
        text = " ✕ ",
        callback = on_close or function()
            self:closeAllViews()
        end,
        radius = 0,
        no_focus = true,
        padding_h = Size.padding.large,
        padding_v = Size.padding.default,
    }

    -- Reserve fixed-element widths + the 3 inter-element spans + the 2 frame
    -- side paddings (padding * 5). search_w takes the remainder, so the row
    -- width is exactly screen_w and never triggers a horizontal scrollbar.
    local btn_space = menu_btn:getSize().w + wifi_btn:getSize().w
        + close_btn:getSize().w + padding * 5
    local search_w = screen_w - btn_space

    local search_btn = Button:new{
        text = _("Title, Author, Series, or ISBN…"),
        callback = on_search,
        radius = Size.radius.button,
        text_font_face = "cfont",
        text_font_size = 18,
        width = search_w,
        padding_v = Size.padding.default,
    }

    local row = HorizontalGroup:new{
        align = "center",
        menu_btn,
        HorizontalSpan:new{ width = padding },
        search_btn,
        HorizontalSpan:new{ width = padding },
        wifi_btn,
        HorizontalSpan:new{ width = padding },
        close_btn,
    }

    return FrameContainer:new{
        width = screen_w,
        bordersize = 0,
        padding = padding,
        padding_top = Size.padding.default,
        padding_bottom = Size.padding.default,
        background = Blitbuffer.COLOR_WHITE,
        row,
    }
end

--- Resolve an already-cached cover file without any network request.
-- Deliberately calls BookLoreApi directly rather than through apiCall: the
-- probe needs no token, and apiCall's not-logged-in gate must never block
-- offline rendering. The filename scheme lives in findCachedCover (shared
-- with downloadCover's cache-hit path). Returns the path or nil.
function BookLore:cachedCoverPath(book)
    if not (book and book.id and self.cover_cache_dir) then return nil end
    return (BookLoreApi:findCachedCover(book.id, book.coverUpdatedOn, self.cover_cache_dir))
end

--- Build a single cover card (cover image + title + author).
-- @param book table: book data
-- @param card_w number: card width in pixels
-- @param on_tap function: called when tapped
-- @return widget, number: the card widget and its height
function BookLore:buildCoverCard(book, card_w, on_tap)
    local cover_h = math.floor(card_w * 1.4)
    local meta = book.metadata or {}
    local title = meta.title or book.fileName or _("Untitled")
    local authors = ""
    if type(meta.authors) == "table" and #meta.authors > 0 then
        authors = meta.authors[1]
        if #meta.authors > 1 then authors = authors .. " …" end
    end

    -- Try to load cover from cache (download if needed).
    -- Guard accepts refresh_token alone: apiCall triggers a pre-emptive
    -- refresh so the cover call has a live access token. (ref: DL-001, DL-006)
    local cover_widget = nil
    local path
    if self.offline_mode then
        path = self:cachedCoverPath(book)
    elseif book.id and self.session:isLoggedIn() and self.cover_cache_dir then
        path = self:apiCall("downloadCover", book.id, book.coverUpdatedOn, self.cover_cache_dir)
    end
    if path then
        local ok, img = pcall(ImageWidget.new, ImageWidget, {
            file = path,
            width = card_w,
            height = cover_h,
            scale_factor = 0,
        })
        if ok and img then cover_widget = img end
    end

    -- Fallback: gray placeholder
    if not cover_widget then
        cover_widget = FrameContainer:new{
            width = card_w,
            height = cover_h,
            background = Blitbuffer.gray(0.85),
            bordersize = 1,
            CenterContainer:new{
                dimen = Geom:new{ w = card_w - 4, h = cover_h - 4 },
                TextBoxWidget:new{
                    text = title,
                    width = card_w - 20,
                    face = Font:getFace("cfont", 16),
                },
            },
        }
    end

    -- Title label
    local title_widget = TextWidget:new{
        text = title,
        face = Font:getFace("cfont", 16),
        max_width = card_w,
    }

    -- Author label
    local author_widget = TextWidget:new{
        text = authors,
        face = Font:getFace("cfont", 14),
        fgcolor = Blitbuffer.gray(0.4),
        max_width = card_w,
    }

    local card_content = VerticalGroup:new{
        align = "left",
        cover_widget,
        VerticalSpan:new{ width = Size.padding.small },
        title_widget,
        author_widget,
    }

    local total_h = cover_h + Size.padding.small
        + title_widget:getSize().h + author_widget:getSize().h

    -- Wrap in tappable InputContainer
    local card = InputContainer:new{
        dimen = Geom:new{ w = card_w, h = total_h },
    }
    table.insert(card, card_content)

    card.ges_events = {
        Tap = {
            GestureRange:new{
                ges = "tap",
                range = card.dimen,
            },
        },
    }
    card.onTap = function()
        if on_tap then on_tap(book) end
        return true
    end

    return card, total_h
end

--- Build a horizontal row of cover cards.
-- @param books table: array of books to show
-- @param max_cards number: max cards in the row
-- @param on_tap function(book): called when a card is tapped
-- @return widget: the row
function BookLore:buildCoverRow(books, max_cards, on_tap)
    local screen_w = Screen:getWidth()
    local padding = Size.padding.large
    local gap = Size.padding.default
    local n = math.min(max_cards, #books)
    if n == 0 then return nil end

    local card_w = math.floor((screen_w - padding * 2 - gap * (n - 1)) / n)

    local row = HorizontalGroup:new{ align = "top" }
    for i = 1, n do
        if i > 1 then
            table.insert(row, HorizontalSpan:new{ width = gap })
        end
        local card = self:buildCoverCard(books[i], card_w, on_tap)
        table.insert(row, card)
    end

    return CenterContainer:new{
        dimen = Geom:new{ w = screen_w, h = row:getSize().h },
        row,
    }
end

--- Build a section header ("Continue Reading", "Recently Added", etc.)
function BookLore:buildSectionHeader(text)
    local screen_w = Screen:getWidth()
    local padding = Size.padding.large
    return FrameContainer:new{
        width = screen_w,
        bordersize = 0,
        padding = padding,
        padding_top = Size.padding.large,
        padding_bottom = Size.padding.small,
        background = Blitbuffer.COLOR_WHITE,
        TextWidget:new{
            text = text,
            face = Font:getFace("tfont", 22),
            bold = true,
        },
    }
end

-- ─── Dashboard ───────────────────────────────────────────────────────

function BookLore:showDashboard()
    local books = self.cached_books
    if not books then return end
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    local on_tap_book = function(book)
        if self.dashboard_widget then
            UIManager:close(self.dashboard_widget)
        end
        self._back_from_detail = function() self:showDashboard() end
        self:showBookDetail(book)
    end

    -- Top bar
    local top_bar = self:buildTopBar(
        function()  -- ☰
            self:showSidebar()
        end,
        function()  -- Search
            if self.dashboard_widget then
                UIManager:close(self.dashboard_widget)
            end
            self:showSearch()
        end,
        function()  -- ✕ Close plugin
            self:closeAllViews()
        end
    )

    -- Build content
    local content = VerticalGroup:new{ align = "left" }
    table.insert(content, top_bar)

    -- Continue Reading: books with lastReadTime, most recent first
    local reading = {}
    for _, book in ipairs(books) do
        if book.lastReadTime and book.lastReadTime ~= "" then
            table.insert(reading, book)
        end
    end
    table.sort(reading, function(a, b)
        return (a.lastReadTime or "") > (b.lastReadTime or "")
    end)

    if #reading > 0 then
        table.insert(content, self:buildSectionHeader(_("Continue Reading")))
        local row = self:buildCoverRow(reading, 3, on_tap_book)
        if row then table.insert(content, row) end
    end

    -- Recently Added: by addedOn, most recent first
    local recent = {}
    for _, book in ipairs(books) do
        if book.addedOn and book.addedOn ~= "" then
            table.insert(recent, book)
        end
    end
    table.sort(recent, function(a, b)
        return (a.addedOn or "") > (b.addedOn or "")
    end)

    if #recent > 0 then
        table.insert(content, self:buildSectionHeader(_("Recently Added")))
        local row = self:buildCoverRow(recent, 3, on_tap_book)
        if row then table.insert(content, row) end
    end

    -- Fallback if no reading history or recently added
    if #reading == 0 and #recent == 0 then
        table.insert(content, self:buildSectionHeader(_("All Books")))
        local row = self:buildCoverRow(books, 3, on_tap_book)
        if row then table.insert(content, row) end
    end

    -- Full-screen frame
    local frame = FrameContainer:new{
        width = screen_w,
        height = screen_h,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        content,
    }

    self.dashboard_widget = InputContainer:new{
        dimen = Geom:new{ w = screen_w, h = screen_h },
    }
    table.insert(self.dashboard_widget, frame)

    UIManager:show(self.dashboard_widget)
    UIManager:setDirty("all", "ui")
end

-- ─── Sidebar overlay ─────────────────────────────────────────────────

--- Close all active views (dashboard, book list, filters, detail).
-- Called before navigating from the sidebar to avoid stale widgets.
function BookLore:closeAllViews()
    if self.detail_widget then
        UIManager:close(self.detail_widget)
        self.detail_widget = nil
    end
    if self.book_list_widget then
        UIManager:close(self.book_list_widget)
        self.book_list_widget = nil
    end
    if self.view_options_widget then
        UIManager:close(self.view_options_widget)
        self.view_options_widget = nil
    end
    if self.sort_menu_widget then
        UIManager:close(self.sort_menu_widget)
        self.sort_menu_widget = nil
    end
    if self.filter_menu_widget then
        UIManager:close(self.filter_menu_widget)
        self.filter_menu_widget = nil
    end
    if self.filter_values_widget then
        UIManager:close(self.filter_values_widget)
        self.filter_values_widget = nil
    end
    -- Legacy field names kept for safety during transition
    if self.filter_menu then
        UIManager:close(self.filter_menu)
        self.filter_menu = nil
    end
    if self.filter_values_menu then
        UIManager:close(self.filter_values_menu)
        self.filter_values_menu = nil
    end
    if self.dashboard_widget then
        UIManager:close(self.dashboard_widget)
        self.dashboard_widget = nil
    end
    -- Force full e-ink repaint so the screen doesn't show ghost content
    UIManager:setDirty("all", "full")
end

function BookLore:showSidebar()
    local books = self.cached_books
    if not books then return end
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local sidebar_w = math.floor(screen_w * 0.70)
    local dismiss_w = screen_w - sidebar_w
    local padding = Size.padding.large
    local item_h = Screen:scaleBySize(40)

    local close_sidebar = function()
        if self.sidebar_widget then
            UIManager:close(self.sidebar_widget)
            UIManager:setDirty("all", "full")
        end
    end

    local navigate = function(book_list, title)
        close_sidebar()
        self:closeAllViews()
        self:showBookList(book_list, title,
            function() self:showDashboard() end)
    end

    -- Build sidebar content as a VerticalGroup
    local sidebar_content = VerticalGroup:new{ align = "left" }
    local indent = Size.padding.large

    -- Track clickable items: { y_offset, height, callback } for each.
    -- y_offset is relative to sidebar_content top.
    local clickable_items = {}
    local cumulative_h = 0

    -- Helper: add a section header (bold, smaller font, not clickable)
    local function addHeader(text)
        local widget = FrameContainer:new{
            width = sidebar_w,
            bordersize = 0,
            padding_left = indent,
            padding_right = indent,
            padding_top = padding,
            padding_bottom = Size.padding.small,
            background = Blitbuffer.COLOR_WHITE,
            TextWidget:new{
                text = text,
                face = Font:getFace("tfont", 14),
                bold = true,
            },
        }
        table.insert(sidebar_content, widget)
        cumulative_h = cumulative_h + widget:getSize().h
    end

    -- Helper: add a clickable sidebar item with icon, left-aligned
    local function addItem(icon, text, count, callback)
        local icon_w = TextWidget:new{
            text = icon .. "  ",
            face = Font:getFace("cfont", 20),
        }
        local label_w = TextWidget:new{
            text = text,
            face = Font:getFace("cfont", 20),
            max_width = sidebar_w - indent * 4 - icon_w:getSize().w,
        }

        local left_part = HorizontalGroup:new{
            align = "center",
            icon_w,
            label_w,
        }

        local row_content
        if count then
            local count_w = TextWidget:new{
                text = tostring(count),
                face = Font:getFace("cfont", 18),
            }
            local spacer_w = sidebar_w - indent * 2
                - left_part:getSize().w - count_w:getSize().w
            if spacer_w < 0 then spacer_w = 0 end

            row_content = HorizontalGroup:new{
                align = "center",
                left_part,
                HorizontalSpan:new{ width = spacer_w },
                count_w,
            }
        else
            row_content = left_part
        end

        local row_widget = FrameContainer:new{
            width = sidebar_w,
            bordersize = 0,
            padding_left = indent,
            padding_right = indent,
            padding_top = Size.padding.small,
            padding_bottom = Size.padding.small,
            background = Blitbuffer.COLOR_WHITE,
            row_content,
        }

        local h = row_widget:getSize().h
        table.insert(clickable_items, {
            y_offset = cumulative_h,
            height = h,
            callback = callback,
        })

        table.insert(sidebar_content, row_widget)
        cumulative_h = cumulative_h + h
    end

    -- Helper: add a thin separator line
    local function addSeparator()
        local sep = CenterContainer:new{
            dimen = Geom:new{ w = sidebar_w, h = Size.padding.default },
            LineWidget:new{
                dimen = Geom:new{ w = sidebar_w - indent * 2, h = 1 },
                background = Blitbuffer.gray(0.85),
            },
        }
        table.insert(sidebar_content, sep)
        cumulative_h = cumulative_h + sep:getSize().h
    end

    -- ── HOME ──
    addHeader(_("HOME"))
    addItem("⌂", _("Dashboard"), nil, function()
        close_sidebar()
        self:closeAllViews()
        self:showDashboard()
    end)
    addItem("▤", _("All Books"), #books, function()
        navigate(books, _("All Books"))
    end)

    -- ── LIBRARIES ──
    local lib_books = {}
    for _, book in ipairs(books) do
        local lid = book.libraryId or 0
        if not lib_books[lid] then lib_books[lid] = {} end
        table.insert(lib_books[lid], book)
    end

    addSeparator()
    addHeader(_("LIBRARIES"))

    if #self.cached_libraries > 0 then
        for _, lib in ipairs(self.cached_libraries) do
            local lid = lib.id
            local name = lib.name or "Library"
            local count = lib_books[lid] and #lib_books[lid] or 0
            addItem("▦", name, count, function()
                navigate(lib_books[lid] or {}, name)
            end)
        end
    else
        local lib_names = {}
        for _, book in ipairs(books) do
            local lid = book.libraryId or 0
            if not lib_names[lid] then
                lib_names[lid] = book.libraryName or "Library"
            end
        end
        local sorted = {}
        for lid, name in pairs(lib_names) do
            table.insert(sorted, { lid = lid, name = name })
        end
        table.sort(sorted, function(a, b) return a.name:lower() < b.name:lower() end)
        for _, entry in ipairs(sorted) do
            local count = lib_books[entry.lid] and #lib_books[entry.lid] or 0
            addItem("▦", entry.name, count, function()
                navigate(lib_books[entry.lid] or {}, entry.name)
            end)
        end
    end

    -- ── SHELVES ──
    addSeparator()
    addHeader(_("SHELVES"))

    addItem("◇", _("Unshelved"), #self.unshelved_books, function()
        navigate(self.unshelved_books, _("Unshelved"))
    end)
    for _, shelf in ipairs(self.cached_shelves) do
        local name = shelf.name or shelf.shelfName or "?"
        local sid = shelf.id or shelf.shelfId
        local count = self.shelf_books[sid] and #self.shelf_books[sid] or 0
        -- Use heart for Favorites, box for others
        local icon = "□"
        if name:lower() == "favorites" then icon = "♡" end
        addItem(icon, name, count, function()
            navigate(self.shelf_books[sid] or {}, name)
        end)
    end

    -- ── MAGIC SHELVES ──
    addSeparator()
    addHeader(_("MAGIC SHELVES"))

    -- Sidebar left panel
    local sidebar_panel = FrameContainer:new{
        width = sidebar_w,
        height = screen_h,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        sidebar_content,
    }

    self.sidebar_widget = InputContainer:new{
        dimen = Geom:new{ w = screen_w, h = screen_h },
    }
    table.insert(self.sidebar_widget, sidebar_panel)

    -- Single tap handler for the entire sidebar area.
    -- On tap, we check y against clickable_items to find which row
    -- was hit, then invert that exact row and fire its callback.
    self.sidebar_widget.ges_events = {
        TapSidebar = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{
                    x = 0, y = 0,
                    w = sidebar_w, h = screen_h,
                },
            },
        },
        TapDismiss = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{
                    x = sidebar_w, y = 0,
                    w = dismiss_w, h = screen_h,
                },
            },
        },
    }

    self.sidebar_widget.onTapDismiss = function()
        close_sidebar()
        return true
    end

    self.sidebar_widget.onTapSidebar = function(this, arg, ges)
        local tap_y = ges.pos.y
        for _, item in ipairs(clickable_items) do
            if tap_y >= item.y_offset and tap_y < item.y_offset + item.height then
                -- Invert this row directly in the framebuffer.
                -- Do NOT call forceRePaint — it would re-render the
                -- sidebar widgets on top and overwrite the inversion.
                local inv_x = 0
                local inv_y = item.y_offset
                local inv_w = sidebar_w
                local inv_h = item.height

                Screen.bb:invertRect(inv_x, inv_y, inv_w, inv_h)
                UIManager:setDirty(nil, "fast", Geom:new{
                    x = inv_x, y = inv_y, w = inv_w, h = inv_h,
                })

                -- After a short delay (for the invert to be visible),
                -- invert back and fire the callback.
                local cb = item.callback
                UIManager:scheduleIn(0.15, function()
                    Screen.bb:invertRect(inv_x, inv_y, inv_w, inv_h)
                    UIManager:setDirty(nil, "ui", Geom:new{
                        x = inv_x, y = inv_y, w = inv_w, h = inv_h,
                    })
                    if cb then cb() end
                end)
                return true
            end
        end
        return true
    end

    UIManager:show(self.sidebar_widget)
    UIManager:setDirty("all", "ui")
end

-- ─── Book list ───────────────────────────────────────────────────────

function BookLore:showBookList(base_set, title, back_callback)
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    -- Apply current view_state (sort + filters) to the base set.
    local view_result = BookLoreView.applyView(base_set, self.view_state)
    local n_active = BookLoreView.activeFilterCount(self.view_state)

    -- Build top bar
    local top_bar = self:buildTopBar(
        function()  -- ☰
            self:showSidebar()
        end,
        function()  -- Search
            if self.book_list_widget then
                UIManager:close(self.book_list_widget)
            end
            self:showSearchWithin(base_set, title, back_callback)
        end,
        function()  -- ✕ Close plugin
            self:closeAllViews()
        end
    )
    local bar_h = top_bar:getSize().h

    -- Build menu items
    local item_table = {}

    -- Combined view-options row (sort + filter summary, single row).
    local sort_key = self.view_state.sort and self.view_state.sort.key or "title"
    local sort_dir = self.view_state.sort and self.view_state.sort.dir or "asc"
    local sort_desc = BookLoreView.SORTS[sort_key] or BookLoreView.SORTS["title"]
    local sort_label = _(sort_desc.label) .. (sort_dir == "asc" and " ↑" or " ↓")
    local filter_label = n_active > 0 and (_("Filter: ") .. n_active .. " ▾") or _("Filter ▾")
    table.insert(item_table, {
        text      = _("Sort: ") .. sort_label,
        mandatory = filter_label,
        book_data = nil,
        is_viewopts = true,
    })

    for bi = 1, #view_result do
        local book = view_result[bi]
        local meta = book.metadata or {}
        local book_title = meta.title or book.fileName or _("Untitled")
        local authors = ""
        if type(meta.authors) == "table" and #meta.authors > 0 then
            authors = table.concat(meta.authors, ", ")
        end
        local status = book.readStatus or ""
        if self:getLocalPath(book) then
            status = "● " .. status
        end
        table.insert(item_table, {
            text = book_title,
            mandatory = status,
            info = authors,
            book_data = book,
        })
    end

    self._back_from_detail = function()
        self:showBookList(base_set, title, back_callback)
    end

    -- Guard flag: when onMenuChoice fires and navigates, prevent
    -- close_callback from also navigating (both can fire when
    -- closing the parent widget triggers Menu cleanup).
    local navigated = false

    -- Menu fills remaining height below top bar
    local menu_h = screen_h - bar_h

    -- Compose the menu title: show "N of M — filtered" when filters are active.
    local menu_title
    if n_active > 0 then
        menu_title = T(_("%1 (%2 of %3) — filtered"), title,
            tostring(#view_result), tostring(#base_set))
    else
        menu_title = T(_("%1 (%2)"), title, tostring(#view_result))
    end

    -- Create the top-level widget first so Menu can capture it as
    -- show_parent at init time. Menu:init passes show_parent down to
    -- its page-navigation buttons, so late assignment won't work — the
    -- page buttons must see the correct parent when they're built, or
    -- their setDirty calls won't find a widget in UIManager's window
    -- stack and the screen won't refresh on next/prev page.
    self.book_list_widget = InputContainer:new{
        dimen = Geom:new{ w = screen_w, h = screen_h },
    }

    local book_menu = Menu:new{
        show_parent = self.book_list_widget,
        title = menu_title,
        item_table = item_table,
        width = screen_w,
        height = menu_h,
        covers_fullscreen = false,
        is_borderless = true,
        is_popout = false,
        onMenuChoice = function(menu_instance, item)
            navigated = true
            if item.is_viewopts then
                UIManager:close(self.book_list_widget)
                self:showViewOptions(base_set, title, back_callback)
            elseif item.book_data then
                UIManager:close(self.book_list_widget)
                self:showBookDetail(item.book_data)
            end
        end,
        close_callback = function()
            UIManager:close(self.book_list_widget)
            if not navigated and back_callback then
                back_callback()
            end
        end,
    }

    -- Stack top bar + menu vertically
    local layout = VerticalGroup:new{
        align = "left",
        top_bar,
        book_menu,
    }

    table.insert(self.book_list_widget, layout)

    UIManager:show(self.book_list_widget)
    UIManager:setDirty("all", "ui")
end

-- ─── View options: Sort, Filter, Clear ───────────────────────────────

function BookLore:showViewOptions(base_set, parent_title, back_callback)
    local navigated = false

    self.view_options_widget = InputContainer:new{
        dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() },
    }

    local item_table = {
        {
            text = _("Sort…"),
            mandatory = "",
            callback = function()
                navigated = true
                UIManager:close(self.view_options_widget)
                self:showSortMenu(base_set, parent_title, back_callback)
            end,
        },
        {
            text = _("Filter…"),
            mandatory = "",
            callback = function()
                navigated = true
                UIManager:close(self.view_options_widget)
                self:showFilterMenu(base_set, parent_title, back_callback)
            end,
        },
    }

    local view_options_menu = Menu:new{
        show_parent = self.view_options_widget,
        title = _("View Options"),
        item_table = item_table,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        close_callback = function()
            UIManager:close(self.view_options_widget)
            if not navigated then
                self:showBookList(base_set, parent_title, back_callback)
            end
        end,
    }

    table.insert(self.view_options_widget, view_options_menu)
    UIManager:show(self.view_options_widget)
end

-- ─── Sort menu ───────────────────────────────────────────────────────

function BookLore:showSortMenu(base_set, parent_title, back_callback)
    local navigated = false

    self.sort_menu_widget = InputContainer:new{
        dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() },
    }

    local cur_key = self.view_state.sort and self.view_state.sort.key or "title"
    local cur_dir = self.view_state.sort and self.view_state.sort.dir or "asc"

    -- All sort keys in one flat list (essentials first, then the rest).
    local ordered_keys = {
        "title", "title_series", "author", "author_series", "last_read",
        "added_on", "personal_rating", "pages", "file_name", "file_size",
        "publisher", "published_date", "amazon_rating", "amazon_count",
        "goodreads_rating", "goodreads_count", "hardcover_rating",
        "hardcover_count", "random", "locked",
    }

    local item_table = {}
    for ki = 1, #ordered_keys do
        local k = ordered_keys[ki]
        local sd = BookLoreView.SORTS[k]
        -- Locked is conditional: only list it if the data carries the field.
        if sd and not (k == "locked"
                and not BookLoreView.isDimensionPresent(base_set, "locked")) then
            local is_active = (k == cur_key)
            local dir_arrow = ""
            if is_active then
                dir_arrow = cur_dir == "asc" and " ↑" or " ↓"
            end
            item_table[#item_table+1] = {
                text      = (is_active and "●" or "○") .. " " .. _(sd.label),
                mandatory = dir_arrow,
                sort_key  = k,
            }
        end
    end

    local sort_menu = Menu:new{
        show_parent = self.sort_menu_widget,
        title = _("Sort By"),
        item_table = item_table,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        onMenuChoice = function(_, item)
            if item.sort_key then
                local new_key = item.sort_key
                local new_dir
                if new_key == cur_key then
                    -- Toggle direction on already-selected sort
                    new_dir = cur_dir == "asc" and "desc" or "asc"
                else
                    new_dir = "asc"
                end
                self.view_state.sort = { key = new_key, dir = new_dir }
                -- Assign fresh seed when switching to random
                if new_key == "random" then
                    self.view_state.sort._seed = math.floor(os.time() * 1000 + math.random(9999))
                end
                self.settings:saveSetting("view_sort_key", new_key)
                self.settings:saveSetting("view_sort_dir", new_dir)
                self.settings:flush()
                navigated = true
                UIManager:close(self.sort_menu_widget)
                self:showBookList(base_set, parent_title, back_callback)
            end
        end,
        close_callback = function()
            UIManager:close(self.sort_menu_widget)
            if not navigated then
                self:showViewOptions(base_set, parent_title, back_callback)
            end
        end,
    }

    table.insert(self.sort_menu_widget, sort_menu)
    UIManager:show(self.sort_menu_widget)
end

-- ─── Filter menu (dimension list) ────────────────────────────────────

function BookLore:showFilterMenu(base_set, parent_title, back_callback)
    local navigated = false

    self.filter_menu_widget = InputContainer:new{
        dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() },
    }

    -- All filter dimensions in one flat list.
    local ordered_keys = {
        "author", "genre", "series", "readStatus", "publisher", "language",
        "personal_rating", "published_year", "book_type", "shelf_status",
        "file_size", "page_count", "amazon_rating", "goodreads_rating",
        "metadata_match_score",
    }

    local filter_menu  -- forward declaration so callbacks can refresh in place

    local function build_item_table()
        local rows = {}
        -- Pinned: Combine toggle (controls AND/OR across active dimensions).
        rows[#rows+1] = {
            text      = _("Combine: ") .. (self.view_state.combine or "AND"),
            mandatory = "",
            is_combine = true,
        }
        -- Pinned: Clear all filters (only while something is active).
        if BookLoreView.activeFilterCount(self.view_state) > 0 then
            rows[#rows+1] = {
                text      = _("Clear all filters"),
                mandatory = "",
                is_clear_all = true,
            }
        end
        for ki = 1, #ordered_keys do
            local k = ordered_keys[ki]
            local dd = BookLoreView.DIMENSIONS[k]
            -- metadata_match_score is conditional on the data carrying it.
            if dd and not (k == "metadata_match_score"
                    and not BookLoreView.isDimensionPresent(base_set, k)) then
                local dim_filters = self.view_state.filters[k]
                local n_selected = 0
                if dim_filters then
                    for _, v in pairs(dim_filters) do
                        if v then n_selected = n_selected + 1 end
                    end
                end
                rows[#rows+1] = {
                    text      = _(dd.label),
                    mandatory = n_selected > 0 and tostring(n_selected) or "",
                    dim_key   = k,
                }
            end
        end
        return rows
    end

    -- Refresh the menu in place (no close/reshow). Reshowing this same widget
    -- would let its deferred close_callback fire AFTER the new menu is shown,
    -- closing it and dropping to the home screen — so we mutate item_table
    -- instead, mirroring the multi-select value picker.
    local function refresh_in_place()
        if filter_menu.switchItemTable then
            local cur_item = (filter_menu.page - 1) * (filter_menu.perpage or 10) + 1
            filter_menu:switchItemTable(nil, build_item_table(), cur_item)
        end
    end

    filter_menu = Menu:new{
        show_parent = self.filter_menu_widget,
        title = _("Filter By"),
        item_table = build_item_table(),
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        onMenuChoice = function(_, item)
            if item.is_combine then
                self.view_state.combine = (self.view_state.combine == "AND") and "OR" or "AND"
                self.settings:saveSetting("view_combine", self.view_state.combine)
                self.settings:flush()
                refresh_in_place()
                return
            end
            if item.is_clear_all then
                self.view_state.filters = {}
                refresh_in_place()
                return
            end
            if item.dim_key then
                navigated = true
                UIManager:close(self.filter_menu_widget)
                self:showFilterValues(base_set, parent_title, back_callback, item.dim_key)
            end
        end,
        close_callback = function()
            UIManager:close(self.filter_menu_widget)
            if not navigated then
                self:showViewOptions(base_set, parent_title, back_callback)
            end
        end,
    }

    table.insert(self.filter_menu_widget, filter_menu)
    UIManager:show(self.filter_menu_widget)
end

-- ─── Filter values (multi-select checkmark picker) ───────────────────

function BookLore:showFilterValues(base_set, parent_title, back_callback, dim_key)
    local navigated = false

    local dd = BookLoreView.DIMENSIONS[dim_key]
    if not dd then
        UIManager:show(InfoMessage:new{ text = _("Unknown filter dimension.") })
        self:showFilterMenu(base_set, parent_title, back_callback)
        return
    end

    -- Ensure dim entry exists in view_state.filters
    if not self.view_state.filters[dim_key] then
        self.view_state.filters[dim_key] = {}
    end

    local function build_value_rows()
        local facets = BookLoreView.computeFacetCounts(base_set, self.view_state, dim_key)
        local rows = {}

        -- Pinned: Select all / Clear
        rows[#rows+1] = {
            text      = _("Select all"),
            mandatory = "",
            is_select_all = true,
        }
        rows[#rows+1] = {
            text      = _("Clear (this filter)"),
            mandatory = "",
            is_clear_dim = true,
        }

        for _, entry in ipairs(facets.ordered) do
            local selected = self.view_state.filters[dim_key][entry.value] == true
            rows[#rows+1] = {
                text      = (selected and "☑ " or "☐ ") .. entry.label,
                mandatory = tostring(entry.count),
                value_key = entry.value,
            }
        end

        if #rows == 2 then
            -- Only the two pinned rows, no values available
            rows[#rows+1] = {
                text      = _("(No values available)"),
                mandatory = "",
                is_empty  = true,
            }
        end

        return rows
    end

    local filter_values_menu
    self.filter_values_widget = InputContainer:new{
        dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() },
    }

    filter_values_menu = Menu:new{
        show_parent = self.filter_values_widget,
        title = _(dd.label),
        item_table = build_value_rows(),
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        onMenuChoice = function(_, item)
            if item.is_empty then return end
            if item.is_select_all then
                -- Select all values currently visible in facets
                local facets = BookLoreView.computeFacetCounts(base_set, self.view_state, dim_key)
                for _, entry in ipairs(facets.ordered) do
                    self.view_state.filters[dim_key][entry.value] = true
                end
            elseif item.is_clear_dim then
                self.view_state.filters[dim_key] = {}
            elseif item.value_key then
                local cur = self.view_state.filters[dim_key][item.value_key]
                self.view_state.filters[dim_key][item.value_key] = not cur
            end

            -- Refresh picker in-place (preserves scroll position; no close/reopen).
            -- Falls back gracefully if switchItemTable is not available.
            local new_rows = build_value_rows()
            if filter_values_menu.switchItemTable then
                local cur_item = (filter_values_menu.page - 1) * (filter_values_menu.perpage or 10) + 1
                filter_values_menu:switchItemTable(nil, new_rows, cur_item)
            else
                -- Fallback: close and reopen (scroll jump accepted)
                navigated = true
                UIManager:close(self.filter_values_widget)
                self:showFilterValues(base_set, parent_title, back_callback, dim_key)
            end
        end,
        close_callback = function()
            UIManager:close(self.filter_values_widget)
            if not navigated then
                -- Apply-on-close: heavy book-list re-render happens here.
                self:showFilterMenu(base_set, parent_title, back_callback)
            end
        end,
    }

    table.insert(self.filter_values_widget, filter_values_menu)
    UIManager:show(self.filter_values_widget)
end

-- ─── Search ──────────────────────────────────────────────────────────

function BookLore:showSearchWithin(books, parent_title, back_callback)
    self.search_dialog = InputDialog:new{
        title = T(_("Search in %1"), parent_title),
        input_hint = _("Title, author, or series…"),
        buttons = {{
            {
                text = _("Cancel"), id = "close",
                callback = function()
                    UIManager:close(self.search_dialog)
                    self:showBookList(books, parent_title, back_callback)
                end,
            },
            {
                text = _("Search"), is_enter_default = true,
                callback = function()
                    local query = self.search_dialog:getInputText()
                    UIManager:close(self.search_dialog)
                    if not query or query == "" then
                        self:showBookList(books, parent_title, back_callback)
                        return
                    end
                    local q = query:lower()
                    local results = {}
                    for _, book in ipairs(books) do
                        local meta = book.metadata or {}
                        local t = (meta.title or book.fileName or ""):lower()
                        local a = ""
                        if type(meta.authors) == "table" then
                            a = table.concat(meta.authors, " "):lower()
                        end
                        local s = (meta.seriesName or ""):lower()
                        if t:find(q, 1, true) or a:find(q, 1, true) or s:find(q, 1, true) then
                            table.insert(results, book)
                        end
                    end
                    if #results == 0 then
                        UIManager:show(InfoMessage:new{
                            text = T(_("No results for: %1"), query),
                        })
                        self:showBookList(books, parent_title, back_callback)
                    else
                        self:showBookList(results, T(_("Search: %1"), query), function()
                            self:showBookList(books, parent_title, back_callback)
                        end)
                    end
                end,
            },
        }},
    }
    UIManager:show(self.search_dialog)
    self.search_dialog:onShowKeyboard()
end

function BookLore:showSearch()
    self:showSearchWithin(
        self.cached_books,
        _("All Books"),
        function() self:showDashboard() end
    )
end

-- ─── Download infrastructure ─────────────────────────────────────────

-- Registry + destination-path logic lives in downloads.lua (the registry is
-- the contract booklore_sync reads to map file paths back to book ids);
-- these thin delegates keep the existing call sites unchanged.
function BookLore:buildDestPath(book)
    return self.downloads:destPath(book)
end

function BookLore:getLocalPath(book)
    return self.downloads:localPath(self.server_url, book)
end

function BookLore:registerDownload(book, path)
    self.downloads:register(self.server_url, book, path)
end

function BookLore:refreshDetailView(book)
    -- Preserve scroll position across a same-book rebuild (Show more / Reveal),
    -- so the reader doesn't get bounced to the top. showBookDetail clamps and
    -- only restores when the book is unchanged.
    if self.detail_widget and self.detail_widget.cropping_widget
            and self.detail_widget.cropping_widget.getScrolledOffset then
        local off = self.detail_widget.cropping_widget:getScrolledOffset()
        self._detail_scroll_y = off and off.y or 0
    end
    if self.detail_widget then
        UIManager:close(self.detail_widget)
    end
    self:showBookDetail(book)
    UIManager:setDirty(self.detail_widget, "ui")
end

function BookLore:downloadBook(book)
    if not self.session:isLoggedIn() then
        UIManager:show(InfoMessage:new{ text = _("Not logged in.") })
        return
    end
    if not NetworkMgr:isWifiOn() then NetworkMgr:turnOnWifi() end

    local dest = self:buildDestPath(book)

    self._downloading_id = book.id
    self:refreshDetailView(book)

    UIManager:scheduleIn(0.1, function()
        local ok, err = self:apiCall("downloadBook", book.id, dest, book.fileSizeKb)
        self._downloading_id = nil
        if ok then
            self:registerDownload(book, dest)
            self:refreshDetailView(book)
        elseif not (err and (err:match("^HTTP 401") or err == "refresh-in-progress" or err == "not-logged-in")) then
            -- Suppress double dialog when apiCall already surfaced auth
            -- errors. Auto-login (DL-009, rejected) would interrupt the
            -- reader; silent refresh in apiCall is preferred. (ref: DL-001, DL-006, DL-009)
            UIManager:show(InfoMessage:new{
                text = T(_("Download failed:\n%1"), tostring(err)),
            })
            self:refreshDetailView(book)
        end
    end)
end

function BookLore:openBook(file_path)
    if self.detail_widget then
        UIManager:close(self.detail_widget)
        self.detail_widget = nil
    end
    if self.book_menu then
        UIManager:close(self.book_menu)
        self.book_menu = nil
    end
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(file_path)
end

-- ─── Book detail ─────────────────────────────────────────────────────

--- Format a Float-ish value, dropping a trailing ".0" (e.g. 1.0 -> "1").
local function fmtNum(x)
    if x == nil then return nil end
    return (tostring(x):gsub("%.0$", ""))
end

local READ_STATUS_LABEL = nil
local function readStatusLabel(status)
    if not READ_STATUS_LABEL then
        READ_STATUS_LABEL = {
            UNREAD = _("Unread"),
            READING = _("Reading"),
            RE_READING = _("Re-reading"),
            READ = _("Read"),
            PARTIALLY_READ = _("Partially read"),
            PAUSED = _("Paused"),
            WONT_READ = _("Won't read"),
            ABANDONED = _("Abandoned"),
        }
    end
    return READ_STATUS_LABEL[status] or status
end

--- Render an enriched, scrollable book-detail page (mirrors the BookLore web
--- details page, reformatted for a grayscale e-ink Paperwhite).
---
--- Layout: fixed top bar + a single vertical ScrollableContainer + a fixed
--- bottom action bar. All metadata is flattened into one scroll (no tabs).
--- Read Status / Personal Rating / Shelves are DISPLAY-ONLY: api.lua exposes
--- no write endpoints, so editing is deliberately out of scope here.
--- "More in Series" / "More by Author" / "Reviews" are derived with ZERO extra
--- network from self.cached_books and meta.bookReviews. Every field is
--- nil-guarded; absent fields drop their row/section rather than error.
function BookLore:showBookDetail(book)
    local meta = book.metadata or {}
    book.metadata = meta   -- ensure enrichment below persists on the cached book

    -- The list endpoint (getBooks) omits the description, so fetch the full
    -- record once to get the blurb (and any other heavy fields the list view
    -- drops), merging it into the cached book so reopens are instant. Guarded
    -- by _enriched so Show more / Reveal rebuilds don't refetch.
    if book.id and not meta._enriched and not self.offline_mode and self.session:isLoggedIn() then
        local full = self:apiCall("getBook", book.id)
        if type(full) == "table" and type(full.metadata) == "table" then
            for k, v in pairs(full.metadata) do
                if meta[k] == nil then meta[k] = v end
            end
            -- Mark enriched only on success, so a transient fetch failure
            -- retries on the next open instead of permanently hiding the blurb.
            meta._enriched = true
        end
    end

    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local padding = Size.padding.large
    -- Scroll body geometry: the vertical scrollbar eats getScrollbarWidth() on
    -- the right, so the content area is screen_w minus that. We pad only on the
    -- left (the scrollbar gives the right side its own visual margin); without
    -- reserving the scrollbar width the content would overflow and add a
    -- spurious horizontal scrollbar.
    local scrollbar_w = ScrollableContainer:getScrollbarWidth()
    local body_left_pad = padding
    local inner_w = screen_w - scrollbar_w
    local content_w = inner_w - body_left_pad

    -- Per-open transient view state. Preserved across a same-book rebuild
    -- (Show more / Reveal go through refreshDetailView), reset when the book
    -- changes (tapping a series/author sibling).
    local prev_book = self._detail_book
    self._detail_book = book
    if not prev_book or prev_book.id ~= book.id then
        self._detail_desc_expanded = false
        self._detail_spoilers = {}
        self._detail_scroll_y = 0
        self._detail_recs = nil
        self._detail_recs_id = nil
    end

    -- Create the page widget early so the horizontally-scrollable cover strips
    -- built below can reference it as their show_parent. cropping_widget and
    -- the page scroll are attached near the end of this function.
    self.detail_widget = InputContainer:new{
        dimen = Geom:new{ w = screen_w, h = screen_h },
    }

    -- ── Local render helpers ────────────────────────────────────────
    local content = VerticalGroup:new{ align = "left" }
    local prev_rendered = false

    local function tbox(text, size, opts)
        opts = opts or {}
        return TextBoxWidget:new{
            text = text,
            width = opts.width or content_w,
            face = Font:getFace(opts.font or "cfont", size),
            fgcolor = opts.gray and Blitbuffer.gray(opts.gray) or nil,
            bold = opts.bold,
        }
    end
    local function add(widget) table.insert(content, widget) end
    local function gap(n) add(VerticalSpan:new{ width = padding * (n or 1) }) end
    -- Horizontal separator, only between two sections that both rendered.
    local function rule()
        if not prev_rendered then return end
        gap(1)
        add(LineWidget:new{
            dimen = Geom:new{ w = content_w, h = Size.line.thin },
            background = Blitbuffer.gray(0.7),
        })
        gap(1)
    end
    -- Section header sized to content_w (the global buildSectionHeader is
    -- full screen_w and self-padded; nesting it inside the padded scroll
    -- body would double-pad it).
    local function sectionHeader(text)
        return FrameContainer:new{
            width = content_w,
            bordersize = 0,
            padding = 0,
            padding_top = padding,
            padding_bottom = Size.padding.small,
            background = Blitbuffer.COLOR_WHITE,
            TextWidget:new{
                text = text,
                face = Font:getFace("tfont", 22),
                bold = true,
            },
        }
    end
    -- Horizontal cover strip sized to content_w (mirrors buildCoverRow but
    -- computes card width from content_w, reusing buildCoverCard per card).
    -- Cards are sized on a fixed 3-column basis (~3 visible at once); ALL books
    -- are laid out in one horizontal row, wrapped in a horizontally-scrollable
    -- container so the reader can swipe sideways through the whole list (like
    -- the web "More in Series" / "Similar Books" strips). If everything already
    -- fits, the plain row is returned so no scrollbar is drawn.
    local function scrollStrip(books, on_tap)
        if not books or #books == 0 then return nil end
        local gapw = Size.padding.default
        local card_w = math.floor((content_w - gapw * 2) / 3)
        local row = HorizontalGroup:new{ align = "top" }
        for i, b in ipairs(books) do
            if i > 1 then table.insert(row, HorizontalSpan:new{ width = gapw }) end
            -- buildCoverCard returns (card, height); keep only the card, else
            -- the extra return turns this into table.insert(row, card, height).
            local card = self:buildCoverCard(b, card_w, on_tap)
            table.insert(row, card)
        end
        local sz = row:getSize()
        if sz.w <= content_w then
            return row
        end
        -- Horizontal scroller. It only claims a pan that STARTS inside its area
        -- (onScrollablePan checks ges.pos against its dimen) and children handle
        -- events before the page's vertical scroller, so sideways swipes here
        -- scroll the strip while swipes elsewhere scroll the page.
        -- Add scrollbar_w to the height: ScrollableContainer reserves that much
        -- height for the horizontal scrollbar, and without the extra room the
        -- row would no longer fit vertically and a spurious vertical scrollbar
        -- would appear alongside the horizontal one.
        return ScrollableContainer:new{
            dimen = Geom:new{ w = content_w, h = sz.h + scrollbar_w },
            show_parent = self.detail_widget,
            row,
        }
    end

    -- ── 1. Header: cover (left) + identity column (right) ───────────
    local cover_w = math.floor(screen_w * 0.34)
    local cover_h = math.floor(cover_w * 1.45)
    local cover_widget = nil
    local cover_path
    if self.offline_mode then
        cover_path = self:cachedCoverPath(book)
    elseif book.id and self.cover_cache_dir then
        cover_path = self:apiCall("downloadCover", book.id, book.coverUpdatedOn, self.cover_cache_dir)
    end
    if cover_path then
        local ok, img = pcall(ImageWidget.new, ImageWidget, {
            file = cover_path,
            width = cover_w,
            height = cover_h,
            scale_factor = 0,
        })
        if ok and img then cover_widget = img end
    end
    if not cover_widget then
        cover_widget = FrameContainer:new{
            width = cover_w,
            height = cover_h,
            background = Blitbuffer.gray(0.85),
            bordersize = 1,
            CenterContainer:new{
                dimen = Geom:new{ w = cover_w - 4, h = cover_h - 4 },
                TextBoxWidget:new{
                    text = meta.title or book.fileName or _("Untitled"),
                    width = cover_w - 20,
                    face = Font:getFace("cfont", 16),
                },
            },
        }
    end

    local id_w = content_w - cover_w - padding
    local ident = VerticalGroup:new{ align = "left" }
    local function ident_add(w) table.insert(ident, w) end
    local function ident_gap() ident_add(VerticalSpan:new{ width = Size.padding.small }) end

    ident_add(TextBoxWidget:new{
        text = meta.title or book.fileName or _("Untitled"),
        width = id_w,
        face = Font:getFace("tfont", 22),
        bold = true,
    })
    -- Subheading: series name with "#X of Y" folded in (replaces the old
    -- standalone bold series line below the cover).
    if meta.seriesName and meta.seriesName ~= "" then
        local num, tot = fmtNum(meta.seriesNumber), fmtNum(meta.seriesTotal)
        local s = meta.seriesName
        if num and tot then
            s = s .. " #" .. num .. " of " .. tot
        elseif num then
            s = s .. " #" .. num
        end
        ident_gap()
        ident_add(tbox(s, 18, { width = id_w, gray = 0.35 }))
    end
    -- Subtitle only if it adds something the title/series don't already say
    -- (avoids the "Title / Title" duplicate seen for series-named books).
    if meta.subtitle and meta.subtitle ~= ""
            and meta.subtitle ~= (meta.title or "")
            and meta.subtitle ~= meta.seriesName then
        ident_gap()
        ident_add(tbox(meta.subtitle, 18, { width = id_w, gray = 0.4 }))
    end
    if type(meta.authors) == "table" and #meta.authors > 0 then
        ident_gap()
        ident_add(tbox(T(_("By: %1"), table.concat(meta.authors, ", ")), 18, { width = id_w }))
    end
    if book.libraryName and book.libraryName ~= "" then
        ident_gap()
        ident_add(tbox(T(_("in %1"), book.libraryName), 14, { width = id_w, gray = 0.5 }))
    end
    -- Personal rating (display-only): filled stars up to the rating, empty
    -- (outline) stars for the rest; "?/10" when unrated.
    do
        local n = math.max(0, math.min(10, book.personalRating or 0))
        local stars = string.rep("★", n) .. string.rep("☆", 10 - n)
        local num = (n == 0) and "?" or tostring(n)
        ident_gap()
        ident_add(tbox(T(_("Your rating:  %1  %2/10"), stars, num), 18, { width = id_w }))
    end
    -- External ratings, directly under "Your rating", each on its own row with
    -- a bundled SVG brand icon to the left of the name. No googleRating field
    -- exists in the BookLore payload, so Google is not shown (only a googleId
    -- link, which is admin/non-reader).
    do
        local icon_sz = Screen:scaleBySize(22)
        local function pct(r) return math.floor(r / 5 * 100 + 0.5) end
        local function cnt(c)
            if not c then return "" end
            if c >= 1000 then return " (" .. fmtNum(math.floor(c / 100) / 10) .. "k)" end
            return " (" .. tostring(c) .. ")"
        end
        -- Letter-badge fallback if the SVG asset is missing or fails to render.
        local function badge(letter)
            return FrameContainer:new{
                bordersize = Size.border.default,
                radius = Size.radius.default,
                padding_top = Size.padding.tiny,
                padding_bottom = Size.padding.tiny,
                padding_left = Size.padding.small,
                padding_right = Size.padding.small,
                margin = 0,
                background = Blitbuffer.COLOR_WHITE,
                TextWidget:new{ text = letter, face = Font:getFace("cfont", 15), bold = true },
            }
        end
        local function icon(name, letter)
            local path = PLUGIN_DIR .. "icons/" .. name .. ".svg"
            if lfs.attributes(path, "mode") == "file" then
                local ok, img = pcall(ImageWidget.new, ImageWidget, {
                    file = path,
                    width = icon_sz,
                    height = icon_sz,
                    scale_factor = 0,
                    -- Honor the SVG's transparent background: without alpha the
                    -- straight-alpha SVG blits its transparent pixels as solid
                    -- black (the whole icon renders as a black tile). With it,
                    -- the icon composites over the white page — so any dropped-in
                    -- brand SVG renders correctly without editing the file.
                    alpha = true,
                })
                if ok and img then return img end
            end
            return badge(letter)
        end
        local function ratingRow(name, letter, label)
            local ic = icon(name, letter)
            local iw = ic:getSize().w
            ident_gap()
            ident_add(HorizontalGroup:new{
                align = "center",
                ic,
                HorizontalSpan:new{ width = Size.padding.default },
                TextWidget:new{
                    text = label,
                    face = Font:getFace("cfont", 16),
                    max_width = math.max(40, id_w - iw - Size.padding.default),
                },
            })
        end
        if meta.amazonRating then
            ratingRow("amazon", "a", "Amazon  " .. pct(meta.amazonRating) .. "%" .. cnt(meta.amazonReviewCount))
        end
        if meta.goodreadsRating then
            ratingRow("goodreads", "G", "Goodreads  " .. pct(meta.goodreadsRating) .. "%" .. cnt(meta.goodreadsReviewCount))
        end
        if meta.hardcoverRating then
            ratingRow("hardcover", "H", "Hardcover  " .. pct(meta.hardcoverRating) .. "%" .. cnt(meta.hardcoverReviewCount))
        end
        if meta.rating then
            ratingRow("booklore", "B", "BookLore  " .. fmtNum(meta.rating) .. "/5")
        end
    end

    add(HorizontalGroup:new{
        align = "top",
        cover_widget,
        HorizontalSpan:new{ width = padding },
        ident,
    })
    prev_rendered = true

    -- (Series number and external ratings now live in the identity column
    -- above, grouped with the title and personal rating.)

    -- ── Genres (categories + tags, de-duped) as wrapped pill chips ──
    do
        local cats, seen = {}, {}
        local function collect(arr)
            if type(arr) ~= "table" then return end
            for _, c in ipairs(arr) do
                if type(c) == "string" and c ~= "" and not seen[c:lower()] then
                    seen[c:lower()] = true
                    table.insert(cats, c)
                end
            end
        end
        collect(meta.categories)
        collect(meta.tags)
        if #cats > 12 then
            local t = {}
            for i = 1, 12 do t[i] = cats[i] end
            cats = t
        end
        if #cats > 0 then
            -- One bordered, rounded pill per genre, packed left-to-right and
            -- wrapped to new rows when the next pill would exceed content_w.
            local function chip(text)
                return FrameContainer:new{
                    bordersize = Size.border.default,
                    radius = Size.radius.button,
                    padding_top = Size.padding.small,
                    padding_bottom = Size.padding.small,
                    padding_left = Size.padding.default,
                    padding_right = Size.padding.default,
                    margin = 0,
                    background = Blitbuffer.COLOR_WHITE,
                    TextWidget:new{ text = text, face = Font:getFace("cfont", 15) },
                }
            end
            local hgap, vgap = Size.padding.small, Size.padding.small
            local flow = VerticalGroup:new{ align = "left" }
            -- First row leads with an inline "Genres" label, then the pills;
            -- wrapped rows are pills only.
            local label = TextWidget:new{
                text = _("Genres"),
                face = Font:getFace("cfont", 15),
                fgcolor = Blitbuffer.gray(0.45),
            }
            local row = HorizontalGroup:new{ align = "center" }
            table.insert(row, label)
            local row_w = label:getSize().w
            local first = false   -- label holds the row start; first pill adds a gap
            for _, name in ipairs(cats) do
                local c = chip(name)
                local cw = c:getSize().w
                local addw = first and cw or (hgap + cw)
                if not first and row_w + addw > content_w then
                    table.insert(flow, row)
                    table.insert(flow, VerticalSpan:new{ width = vgap })
                    row = HorizontalGroup:new{ align = "center" }
                    row_w, first, addw = 0, true, cw
                end
                if not first then table.insert(row, HorizontalSpan:new{ width = hgap }) end
                table.insert(row, c)
                row_w = row_w + addw
                first = false
            end
            if #row > 0 then table.insert(flow, row) end

            gap(1)
            add(flow)
        end
    end

    -- ── 5. Info grid (two-column label / value) ─────────────────────
    do
        local label_w = math.floor(content_w * 0.34)
        local value_w = content_w - label_w - padding
        local rows = {}
        local function infoRow(label, value)
            if value == nil or value == "" then return end
            table.insert(rows, HorizontalGroup:new{
                align = "top",
                FrameContainer:new{
                    width = label_w,
                    bordersize = 0,
                    padding = 0,
                    TextWidget:new{
                        text = label,
                        face = Font:getFace("cfont", 16),
                        fgcolor = Blitbuffer.gray(0.45),
                        max_width = label_w,
                    },
                },
                HorizontalSpan:new{ width = padding },
                tbox(value, 16, { width = value_w }),
            })
        end

        if book.readStatus then
            infoRow(_("Read Status"), readStatusLabel(book.readStatus))
        end
        -- Progress shape varies by BookLore version: usually an object with a
        -- numeric .percentage, but some payloads return a bare number. Coerce
        -- defensively — never pass a non-number to string.format.
        local prog = book.epubProgress or book.pdfProgress
            or book.cbxProgress or book.audiobookProgress
        local pct_val
        if type(prog) == "table" and type(prog.percentage) == "number" then
            pct_val = prog.percentage
        elseif type(prog) == "number" then
            pct_val = prog
        end
        if pct_val then
            infoRow(_("Progress"), string.format("%.2f%%", pct_val))
        end
        if meta.publisher and meta.publisher ~= "" then
            if meta.publishedDate and meta.publishedDate ~= "" then
                infoRow(_("Publisher"), meta.publisher .. " (" .. meta.publishedDate .. ")")
            else
                infoRow(_("Publisher"), meta.publisher)
            end
        elseif meta.publishedDate and meta.publishedDate ~= "" then
            infoRow(_("Published"), meta.publishedDate)
        end
        if meta.pageCount then infoRow(_("Pages"), tostring(meta.pageCount)) end
        if meta.language and meta.language ~= "" then infoRow(_("Language"), meta.language) end
        local isbn = meta.isbn13 or meta.isbn10
        if isbn and isbn ~= "" then infoRow(_("ISBN"), tostring(isbn)) end
        if book.bookType then infoRow(_("Format"), tostring(book.bookType)) end
        if book.fileSizeKb then
            infoRow(_("Size"), string.format("%.1f MB", book.fileSizeKb / 1024))
        end
        if type(book.shelves) == "table" and #book.shelves > 0 then
            local sn = {}
            for _, sh in ipairs(book.shelves) do
                table.insert(sn, type(sh) == "table" and (sh.name or sh.shelfName or "?") or tostring(sh))
            end
            infoRow(_("Shelves"), table.concat(sn, ", "))
        end

        if #rows > 0 then
            gap(1)
            for i, r in ipairs(rows) do
                if i > 1 then add(VerticalSpan:new{ width = Size.padding.small }) end
                add(r)
            end
        end
    end

    -- ── 6. Description with Show more / Show less ───────────────────
    do
        local desc = meta.description
        -- BookLore descriptions are HTML (<br />, <p>, entities, …); flatten to
        -- plain text with real line breaks so TextBoxWidget renders them.
        if type(desc) == "string" and desc ~= "" then
            desc = util.htmlToPlainTextIfHtml(desc)
        end
        if desc and desc ~= "" then
            rule()
            local long = #desc > 400
            if long and not self._detail_desc_expanded then
                add(tbox(util.fixUtf8(desc:sub(1, 400):gsub("%s+%S*$", ""), "") .. "…", 18))
                add(Button:new{
                    text = _("Show more") .. "  ▼",
                    radius = Size.radius.button,
                    padding = Size.padding.button,
                    callback = function()
                        self._detail_desc_expanded = true
                        self:refreshDetailView(self._detail_book)
                    end,
                })
            else
                add(tbox(desc, 18))
                if long then
                    add(Button:new{
                        text = _("Show less") .. "  ▲",
                        radius = Size.radius.button,
                        padding = Size.padding.button,
                        callback = function()
                            self._detail_desc_expanded = false
                            self:refreshDetailView(self._detail_book)
                        end,
                    })
                end
            end
        end
    end

    -- Tapping a related cover opens that book's detail, chaining Back so it
    -- returns to the book we came from (mirrors the dashboard on_tap pattern).
    local this_book = book
    local on_tap_detail = function(b)
        local prev = self._back_from_detail
        self._back_from_detail = function()
            self._back_from_detail = prev
            self:showBookDetail(this_book)
        end
        self:refreshDetailView(b)
    end

    -- ── 7. More in Series (zero network, from cached_books) ─────────
    if self.cached_books and meta.seriesName and meta.seriesName ~= "" then
        local sib = {}
        for _, b in ipairs(self.cached_books) do
            local bm = b.metadata
            if bm and bm.seriesName == meta.seriesName and b.id ~= book.id then
                table.insert(sib, b)
            end
        end
        table.sort(sib, function(a, c)
            local an = tonumber((a.metadata or {}).seriesNumber) or 0
            local cn = tonumber((c.metadata or {}).seriesNumber) or 0
            return an < cn
        end)
        if #sib > 0 then
            rule()
            add(sectionHeader(_("More in Series")))
            local r = scrollStrip(sib, on_tap_detail)
            if r then add(r) end
        end
    end

    -- ── 8. Similar Books (recommendations endpoint, horizontal scroll) ──
    -- Mirrors the web "Similar Books" strip. Fetched once per book and cached
    -- so Show more / Reveal rebuilds don't refetch. series_ids is unused now
    -- that this is server-driven rather than derived from the cached list.
    if book.id and not self.offline_mode and self.session:isLoggedIn() then
        if not self._detail_recs or self._detail_recs_id ~= book.id then
            local recs = self:apiCall("getRecommendations", book.id)
            local list = {}
            if type(recs) == "table" then
                for _, r in ipairs(recs) do
                    if type(r) == "table" and type(r.book) == "table" then
                        table.insert(list, r.book)
                    end
                end
            end
            self._detail_recs = list
            self._detail_recs_id = book.id
        end
        if #self._detail_recs > 0 then
            rule()
            add(sectionHeader(_("Similar Books")))
            local r = scrollStrip(self._detail_recs, on_tap_detail)
            if r then add(r) end
        end
    end

    -- ── 9. Reviews (zero network, from meta.bookReviews) ────────────
    if type(meta.bookReviews) == "table" and #meta.bookReviews > 0 then
        rule()
        add(sectionHeader(_("Reviews")))
        local nshow = math.min(3, #meta.bookReviews)
        for i = 1, nshow do
            local rv = meta.bookReviews[i]
            local who = rv.reviewerName or rv.metadataProvider or _("Anonymous")
            local head = who
            if rv.rating then head = head .. "  " .. fmtNum(rv.rating) .. "/5" end
            if i > 1 then gap(1) end
            add(tbox(head, 16, { bold = true }))
            if rv.spoiler == true and not self._detail_spoilers[i] then
                add(tbox(T(_("[spoiler] %1"), rv.title or ""), 16))
                local idx = i
                add(Button:new{
                    text = _("Reveal"),
                    callback = function()
                        self._detail_spoilers[idx] = true
                        self:refreshDetailView(self._detail_book)
                    end,
                })
            else
                add(tbox(util.fixUtf8((rv.body or ""):sub(1, 300), ""), 16))
            end
        end
        if #meta.bookReviews > 3 then
            gap(1)
            add(tbox(T(_("+%1 more reviews"), #meta.bookReviews - 3), 14, { gray = 0.5 }))
        end
    end
    gap(2)

    -- ── Fixed bottom action bar ─────────────────────────────────────
    local back_action = function()
        if self.detail_widget then
            UIManager:close(self.detail_widget)
            self.detail_widget = nil
        end
        if cover_widget and cover_widget.free then cover_widget:free() end
        self._detail_book = nil
        self._detail_desc_expanded = false
        self._detail_spoilers = {}
        self._detail_scroll_y = 0
        -- Schedule navigation on next tick so close fully completes
        UIManager:scheduleIn(0.1, function()
            if self._back_from_detail then self._back_from_detail() end
        end)
    end

    local local_path = self:getLocalPath(book)
    local is_downloading = (self._downloading_id == book.id)
    local action_btn
    if local_path then
        action_btn = Button:new{
            text = _("Read"),
            radius = Size.radius.button,
            padding = Size.padding.button,
            callback = function() self:openBook(local_path) end,
        }
    elseif is_downloading then
        action_btn = Button:new{
            text = _("Downloading…"),
            radius = Size.radius.button,
            padding = Size.padding.button,
            enabled = false,
        }
    elseif self.offline_mode then
        action_btn = Button:new{
            text = _("Unavailable offline"),
            radius = Size.radius.button,
            padding = Size.padding.button,
            enabled = false,
        }
    else
        local dl_label
        if book.fileSizeKb then
            dl_label = T(_("Download (%1 MB)"), string.format("%.1f", book.fileSizeKb / 1024))
        else
            dl_label = _("Download")
        end
        action_btn = Button:new{
            text = dl_label,
            radius = Size.radius.button,
            padding = Size.padding.button,
            callback = function() self:downloadBook(book) end,
        }
    end

    local back_btn = Button:new{
        text = _("← Back"),
        radius = Size.radius.button,
        padding = Size.padding.button,
        callback = back_action,
    }

    local btn_row = HorizontalGroup:new{
        align = "center",
        back_btn,
        HorizontalSpan:new{ width = padding * 2 },
        action_btn,
    }
    local action_bar = FrameContainer:new{
        width = screen_w,
        bordersize = 0,
        padding = padding,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = screen_w - padding * 2, h = btn_row:getSize().h },
            btn_row,
        },
    }
    local action_h = action_bar:getSize().h

    -- ── Top bar (☰ sidebar, search, ✕ close plugin) ─────────────────
    local top_bar = self:buildTopBar(
        function() self:showSidebar() end,
        function()
            if self.detail_widget then
                UIManager:close(self.detail_widget)
                self.detail_widget = nil
            end
            self:showSearch()
        end,
        function() self:closeAllViews() end
    )

    -- ── Scrollable body between the two fixed bars ──────────────────
    local scroll_h = screen_h - top_bar:getSize().h - action_h
    local scroll_inner = FrameContainer:new{
        width = inner_w,
        bordersize = 0,
        padding = 0,
        padding_left = body_left_pad,
        padding_top = padding,
        background = Blitbuffer.COLOR_WHITE,
        content,
    }

    -- (self.detail_widget was created near the top so the cover strips could
    -- use it as show_parent.)
    -- ScrollableContainer must be exposed as cropping_widget on the widget
    -- passed to UIManager:show() (see KOReader bookmapwidget). Inner widget
    -- is self[1]; never give scroll_inner a fixed height or it would clip.
    local scroll = ScrollableContainer:new{
        dimen = Geom:new{ w = screen_w, h = scroll_h },
        show_parent = self.detail_widget,
        scroll_inner,
    }
    self.detail_widget.cropping_widget = scroll
    -- Restore scroll position on a same-book rebuild (set in refreshDetailView).
    -- Clamp to the new content height in case it shrank (Show less). initState
    -- computes maxes lazily on first paint and won't clobber a pre-set offset.
    if self._detail_scroll_y and self._detail_scroll_y > 0 and scroll.setScrolledOffset then
        local max_y = math.max(0, scroll_inner:getSize().h - scroll_h)
        scroll:setScrolledOffset(Geom:new{ x = 0, y = math.min(self._detail_scroll_y, max_y) })
    end

    local frame = FrameContainer:new{
        width = screen_w,
        height = screen_h,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        VerticalGroup:new{
            align = "left",
            top_bar,
            scroll,
            action_bar,
        },
    }
    table.insert(self.detail_widget, frame)
    UIManager:show(self.detail_widget)
    UIManager:setDirty("all", "ui")
end

return BookLore