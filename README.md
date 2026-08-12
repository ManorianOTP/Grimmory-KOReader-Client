# Grimmory KOReader Client

A pair of [KOReader](https://koreader.rocks/) plugins that turn a jailbroken
Kindle into a client for a self-hosted [Grimmory](https://github.com/grimmory-tools/grimmory)
library server: browse and download your books, and sync your reading position
back to the server automatically.

> Two plugins, one install:
> - **`grimmory.koplugin`** — log in, browse/search/filter your library, download books, and (optionally) get on your network over Tailscale.
> - **`grimmory_sync.koplugin`** — syncs progress and, when enabled, EPUB annotations and reading sessions.

## Features

- **Library browser** — covers, 19 sort options, 14 filter dimensions with live
  facet counts, and full-text search over title/author/series. Every page of a
  paginated Grimmory library is loaded before the local sorts and filters run.
- **Native book files** — choose the exact KOReader-compatible primary or
  alternative format to download. Physical-only, audiobook, and unsupported
  records stay visible but are not offered as readable Kindle downloads.
- **Reading-progress sync** — your position pushes to Grimmory as you read and
  pulls when you open a book, using the same selected-file progress fields as
  Grimmory's web reader. A conflict prompt appears when the server is ahead.
  EPUB uses our exact CFI converter, PDF/CBX use exact pages, and FB2/MOBI/AZW3
  sync percentage without mislabelling KOReader positions as EPUB CFI.
- **EPUB annotation sync (opt in)** — highlights and notes use a durable
  three-way merge. Concurrent edits are kept as visible pending conflicts
  instead of silently overwriting either copy. Bookmarks and alternate EPUB
  files are deliberately excluded because Grimmory annotations are book-scoped.
  KOReader Unicode-scalar positions are translated to the UTF-16 units used by
  epub.js, including around smart punctuation and emoji. A visibly truncated
  annotation uploaded by an older build must be deleted and recreated: Grimmory
  CFIs are immutable, so the plugin will flag but not silently rewrite it.
- **Reading-session sync (opt in)** — reading time, progress and locations are
  recorded with the book's real format. Short opens are discarded and retries
  search server history first to avoid duplicate sessions after a lost response.
- **Shelf collections** — fresh online Grimmory shelves are mirrored into
  clearly namespaced KOReader collections. Only plugin-managed memberships are
  removed; manually added books and collections are preserved.
- **Connection & Sync panel** — tap the top-bar Wi-Fi icon to turn Wi-Fi on and
  try the configured server, change sync options, or inspect every pending book
  with its current device and last-known server position. A badge shows the
  number of pending books (capped at `9+`).
- **Works offline** — the last library view is cached, so the app still opens
  and your progress is queued and pushed when you're back online.
- **Multiple accounts** — switch between saved logins without retyping a
  password (shared/household devices).
- **Tailscale onboarding** — install and connect Tailscale from inside the app
  to reach a server that isn't on your local network. The installer verifies
  the pinned archive and extracted executables and rejects unsafe archive paths,
  links, unexpected members, or bytes that do not match their checksums.
- **In-app updates** — after a public Grimmory release is available,
  **Grimmory ▸ Check for updates** downloads, checksum-verifies, and installs
  the complete two-plugin release as one lockstep update.

## Prerequisites

You need all four of these before installing:

1. **A jailbroken Kindle running KOReader.** Developed and used on a Kindle
   Paperwhite; other KOReader-capable Kindles should work but are untested.
   See [KindleModding](https://kindlemodding.org/) for jailbreak + KOReader.
2. **A running Grimmory server** you can sign into. This client is contract-
   tested against Grimmory v3.3.1; older releases may not provide the App
   progress, pagination, and selected-file APIs used here. See the
   [Grimmory project](https://github.com/grimmory-tools/grimmory).
3. **Network access from the Kindle to that server** — either both on the same
   Wi-Fi/LAN, or over Tailscale (which the app can set up for you).
4. **A few minutes for a one-time install** (USB copy — no command line needed).

## Quick start

1. **Install the plugins** — see [INSTALL.md](INSTALL.md). The simplest path is
   USB drag-and-drop: copy the two `*.koplugin` folders into
   `koreader/plugins/` on the Kindle and restart KOReader.
2. **Log in** — in KOReader: **Menu ▸ Grimmory ▸ Login**. Enter your server URL
   (e.g. `192.168.1.50:6060` — `http://` is added for you) and your Grimmory
   username and password.
3. **Browse** — **Menu ▸ Grimmory ▸ Browse Library**. Tap a book to see details
   and download its primary file, or choose a format when the book has several.
   Open the downloaded book to read; your progress syncs automatically.

This client intentionally makes its direct App-API sync the sole writer for
Kindle-to-web-reader progress. Do not also enable Grimmory's native KOReader /
KOSync web-reader bridge for the same books: two writers can race and produce
conflicting prompts or positions.

Not on the same network as your server? Set up Tailscale first:
**Menu ▸ Grimmory ▸ Tailscale ▸ Install → Connect** and scan the QR code with
your phone to authenticate.

## Updating

After installing Grimmory v2 or later, and once a public release is available:
**Menu ▸ Grimmory ▸ Check for updates**. If a newer version is published it is
downloaded, verified, and installed for both plugins; restart KOReader to apply.

The old BookLore updater is not a supported route to Grimmory. Existing
BookLore users must follow the exact clean-install transition in
[INSTALL.md](INSTALL.md#replacing-the-old-booklore-plugins) so KOReader does not
load both plugin pairs.

## Settings

**Menu ▸ Grimmory ▸ Settings** lets you see who you're signed in as, switch
accounts, change the download folder, sign out, or uninstall both plugins
(with the option to keep your saved settings for an easy reinstall).

Tap the Wi-Fi icon in any Grimmory view for **Connection & Sync**. Shelf
collections are enabled by default. Annotation and reading-session sync are
opt-in; their switches live in that panel alongside **Sync all now** and the
per-book pending list.

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for the common issues
(login failures, "offline" library, Tailscale, update problems).

## For developers

The off-device test harness is documented in [tests/README.md](tests/README.md).
Run the tests with `scripts/test.sh` or the complete CI gate with
`scripts/ci-check.sh`. Run `bash scripts/run-koreader-visual-tests.sh` for the real
KOReader UI checks; its first run downloads and verifies the pinned desktop
release, then all later runs capture and compare 47 scenarios in portrait and
landscape (94 approved screenshots). On Windows, run that command through WSL.
Reference images can only be changed by the explicit workflow documented in
[tests/visual/README.md](tests/visual/README.md).
The device-to-web annotation regression creates highlights through KOReader's
real reader UI, then independently resolves the resulting CFI with Foliate and
requires the complete DOM range to match KOReader and Grimmory byte-for-byte.
It runs on the synthetic Unicode fixture and all eight configured real EPUBs.
To build and validate exactly two release artifacts, run
`scripts/release.sh <version>`.

## License

[MIT](LICENSE).
