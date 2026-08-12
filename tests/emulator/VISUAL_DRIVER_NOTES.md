# Grimmory emulator visual driver

This directory contains a test-only KOReader plugin. It is deliberately outside
both production `.koplugin` directories, so release packaging cannot include it.

## Contract

Copy these three directories into an isolated KOReader emulator's `plugins/`
directory:

- `grimmory.koplugin`
- `grimmory_sync.koplugin`
- `tests/emulator/visual_driver.koplugin`

Launch KOReader with:

```sh
GRIMMORY_VISUAL_SCENARIO=wifi_badge_1 \
GRIMMORY_VISUAL_OUTPUT=/absolute/path/to/artifacts \
./kodev run
```

The driver waits for the real Grimmory plugin, builds the named screen using
Grimmory's real widget methods, takes `<scenario>.png` with KOReader's
`Screen:shot`, writes `<scenario>.json`, and exits KOReader. Exit code 0 means
all direct checks passed; exit code 1 means setup, capture, or a direct check
failed. The JSON result is written through a temporary file and renamed only
when complete, so a runner never reads a partial result.

The output directory must be unique to a run. The emulator should also use a
fresh KOReader data/settings directory and fixed language, DPI, fonts, and
KOReader revision.

SDL reports desktop keyboard, key, and D-pad capabilities that a modern touch
Kindle does not have. While each scenario is active, the driver applies a
touch-Kindle capability profile and disables KOReader Menu's cached keyboard
shortcut default. This prevents desktop-only Q/W/E shortcut tiles from changing
the UI under test. Every overridden value is restored before KOReader exits.

## Scenarios

`visual_scenarios.lua` is the executable catalogue. It covers these production
widget families:

- Wi-Fi badge and connection/sync menu, including offline, error, detail and
  long-title states.
- Dashboard, scrollable sidebar, populated/paginated library, filtered empty
  state, view options, sort, filter dimensions and long selected values.
- Search with the touch keyboard, plus a long-query results title.
- Rich book detail at the top, middle and bottom of its real scroll body;
  downloaded/offline actions; and a mixed local/remote format chooser.
- Login, account switcher, download-folder settings, signed-in main menu,
  settings menu, update, sign-out and both uninstall choices.
- Tailscale menu, explicit install prompt, connected status and first-login QR
  instructions.
- Real KOReader EPUB view, the production sync-conflict dialog, sync main-menu
  status, Wi-Fi enable prompt, 50% download progress, QR screen and a long
  production error message.

The records are synthetic but deliberately use the same IDs and DTO shape as
the local fixture server. No description or cover is extracted from supplied
ebooks. A server-backed runner can replace the injected records without
changing any production screen builder or scenario name.

Optional environment seams:

- `GRIMMORY_VISUAL_COVERS_JSON` points to a JSON object mapping string book IDs
  to absolute deterministic image paths (or `null`). This is the preferred CI
  route. The driver otherwise writes three temporary synthetic SVG covers and
  deliberately leaves book `1007` on the placeholder path.
- `GRIMMORY_VISUAL_LIBRARY_JSON` points to a normalized private snapshot shaped
  as `{ "books": [...], "libraries": [...], "shelves": [...] }`. Each book is
  the same normalized DTO returned to the plugin and may carry
  `cover: { path: "/absolute/private/image" }`. This is strictly an opt-in local
  gallery seam; it is never the default and its outputs must remain ignored.
- `GRIMMORY_VISUAL_EPUB` points to the tracked, copyright-safe synthetic EPUB
  used by `reader_download_open`, `reader_epub_open`, and
  `reader_sync_conflict`.
- `reader_download_open` is a full data-path journey. The runner starts the
  fixture API on a random local port; Grimmory downloads through its production
  Session/API code, publishes and registers the file, reconciles its canonical
  path into a real KOReader collection, and opens it through the application's
  normal ReaderUI delegate. Assertions cover exact SHA-256 bytes, registry and
  sync-plugin identity, collection idempotence/user-member preservation, page
  count, and document-derived navigation positions.
- `reader_sync_conflict` is a production-hook journey over the rendered EPUB,
  not merely a dialog fixture. It uses real KOReader positions for Jump Ahead
  and Sync Here, then records a reading session and exercises annotation
  create/adopt and both-edited conflict behavior in the same ReaderUI.

`scripts/run-real-epub-companions.sh` is the supported way to set the private
seams together. It substitutes the complete scenario record before building a
screen; replacing only `cached_books` is forbidden because callbacks and
assertions would continue using synthetic `scenario.books`. Generated results
identify the realism class, source book/file IDs, exact EPUB digest, fixture
mode, and pinned KOReader revision. See `GRIMMORY_FIXTURE_SERVER.md` for the
command and privacy boundary.

Run the same scenario set twice, once with portrait dimensions and once with
the dimensions reversed for landscape. The driver records the actual width,
height, and orientation in each JSON result; screen configuration belongs to
the emulator runner rather than the plugin.

Direct checks cover badge text, presence, fixed icon bounds, circular geometry,
top-right placement, connection row counts, titles, device/server labels,
screen and scroll bounds, reachability of the final dashboard/sidebar content,
menu row models, fixed detail actions, and real callback routing into injected
boundary spies.
The PNG remains the authority for visual qualities those measurements cannot
express, including balance, spacing, clipping, wrapping, and font rendering.

Connection scenes enter through the real Wi-Fi button's `onTap` callback, and
the error scene selects the real Sync menu item. The driver also asserts that
the tap gesture and menu callback are registered. It replaces only three
volatile boundaries while a scenario is active:
pending-book input, Wi-Fi state, and (for the error scenario) the sync callback.
It restores all three before exiting.

`connection_offline` captures the still-open offline menu first, then selects
its real first item against a no-network spy. The JSON result asserts that the
production callback invoked `tryGoOnline` exactly once without sacrificing the
useful menu screenshot.

Application-wide scenes additionally replace cache lookup, local-file lookup,
session identity, deferred network work, updater/Tailscale subprocess results,
and final navigation targets. The replacement boundary is documented in the
JSON assertions, and the UI itself is always constructed by the production
plugin. Static layout scenes do not make network requests. The dedicated
`reader_download_open` journey is intentionally different: it uses the
production Session/API path against an ephemeral fixture server and updates the
real KOReader collection store inside that run's isolated, disposable profile.
