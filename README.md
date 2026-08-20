# Grimmory KOReader Client

A pair of [KOReader](https://koreader.rocks/) plugins that turn a jailbroken
Kindle into a client for a self-hosted [Grimmory](https://github.com/grimmory-tools/grimmory)
library server: browse and download your books, and sync your reading position
back to the server automatically.

The project is primarily an integration and reliability exercise: it translates
KOReader document positions into Grimmory/epub.js locations, preserves work
while offline, resolves concurrent progress and annotation changes, and ships a
reproducible emulator and compatibility-test harness around a constrained
e-ink client.

> Two plugins, one install:
> - **`grimmory.koplugin`** — log in, browse/search/filter your library, download books, and (optionally) get on your network over Tailscale.
> - **`grimmory_sync.koplugin`** — syncs progress and, when enabled, EPUB annotations and reading sessions.

> **Current release:** [v2.0.0](https://github.com/ManorianOTP/Grimmory-KOReader-Client/releases/tag/v2.0.0)
> is the first public Grimmory release. Install both version-matched plugin
> archives from that release as described in [INSTALL.md](INSTALL.md). The
> older `v1.0.0` release is the legacy BookLore client and is not a Grimmory
> package.

![Synthetic KOReader library dashboard used by the visual regression suite](tests/visual/references/portrait/dashboard_real_library.png)

*A deterministic, fictional library fixture—no private books or cover art.*

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
  the versioned archive selected by Tailscale's package manifest and the
  extracted executables, and rejects unsafe archive paths, links, unexpected
  members, or bytes that do not match their checksums. The selected Tailscale
  version is not pinned in this repository.
- **In-app updates** — **Grimmory ▸ Check for updates** downloads,
  checksum-verifies, and installs the complete two-plugin release together. A
  transaction marker and retained
  backups let startup recovery finish or roll back an interrupted replacement;
  the operation is not described as filesystem-atomic.

## Prerequisites

You need all four of these before installing:

1. **A jailbroken Kindle running KOReader.** Developed and used on a Kindle
   Paperwhite; other KOReader-capable Kindles should work but are untested.
   See [KindleModding](https://kindlemodding.org/) for jailbreak + KOReader.
2. **A running Grimmory server** you can sign into. The reproducible
   compatibility harness is pinned to Grimmory v3.3.1; that is the tested API
   baseline, not a recommendation to remain on an old server patch. Use a
   currently supported, security-patched Grimmory release. Older releases may
   not provide the App progress, pagination, selected-file, annotation, and
   reading-session APIs used here. See the
   [Grimmory project](https://github.com/grimmory-tools/grimmory).
3. **Network access from the Kindle to that server** — either both on the same
   Wi-Fi/LAN, or over Tailscale (which the app can set up for you).
4. **A few minutes for a one-time install** (USB copy — no command line needed).

## Quick start

1. **Install the plugins** — see [INSTALL.md](INSTALL.md). The simplest path is
   USB drag-and-drop: download and extract both v2.0.0 plugin archives, copy the
   two `*.koplugin` folders into `koreader/plugins/` on the Kindle, and restart
   KOReader.
2. **Log in** — in KOReader: **Menu ▸ Grimmory ▸ Login**. Enter your server URL
   and your Grimmory username and password. Prefer an HTTPS URL. A bare LAN
   address such as `192.168.1.50:6060` is accepted and gets `http://` added,
   but plain HTTP does not protect credentials or tokens from network observers.
3. **Browse** — **Menu ▸ Grimmory ▸ Browse Library**. Tap a book to see details
   and download its primary file, or choose a format when the book has several.
   Open the downloaded book to read; your progress syncs automatically.
4. **Choose optional sync features** — tap the Wi-Fi icon in a Grimmory screen
   to open **Connection & Sync**. Progress sync is always active for matched
   downloads; EPUB annotations and reading sessions are opt-in. Shelf-to-
   collection mirroring is on by default.

This client intentionally makes its direct App-API sync the sole writer for
Kindle-to-web-reader progress. Do not also enable Grimmory's native KOReader /
KOSync web-reader bridge for the same books: two writers can race and produce
conflicting prompts or positions.

Not on the same network as your server? Set up Tailscale first:
**Menu ▸ Grimmory ▸ Tailscale ▸ Install Tailscale**, then **Connect**, and scan
the QR code with your phone to authenticate.

## Updating

After installing v2.0.0 or later, use **Menu ▸ Grimmory ▸ Check for updates**.
If a newer version is published, it is downloaded, verified, and installed for
both plugins; restart KOReader to apply. If no newer release exists, the plugin
reports that you already have the latest version.

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
per-book pending list. Mirrored collections are named `Grimmory — <shelf>` and
contain only locally downloaded books. A deleted remote shelf is retained
locally rather than deleting a collection that may contain manual edits.

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for the common issues
(login failures, "offline" library, Tailscale, update problems).

For deployment assumptions and private vulnerability reporting, see
[SECURITY.md](SECURITY.md).

## Documentation

- [Installation and migration](INSTALL.md)
- [Troubleshooting](TROUBLESHOOTING.md)
- [Changelog](CHANGELOG.md)
- [Contributing](CONTRIBUTING.md)
- [Security policy and deployment assumptions](SECURITY.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)
- [Test architecture and commands](tests/README.md)
- [Test-realism audit](tests/REALISM_AUDIT.md)

## Engineering evidence

At the current source baseline, the public deterministic gate comprises 339
Lua examples, 120 Python harness/tooling tests, and 22 Node.js browser-oracle
unit tests. The
realism policy independently inventories 331 top-level Lua cases, all 47 visual
scenarios, those 120 Python tests, and 34 JavaScript cases (the 22 public unit
tests plus 12 private full-server Playwright journeys). These are deliberately
reported as separate categories rather than one inflated total.

The KOReader visual job captures every scenario in portrait and landscape and
compares all 94 images exactly. Private companion lanes add eight locally owned
EPUBs and a disposable Grimmory/MariaDB stack; their books, provider responses,
paths, hashes, logs, and reports are ignored and are not required to run the
meaningful public suite. Desktop KOReader cannot prove Kindle-only touch,
suspend/wake, or e-ink refresh behaviour, so those remain physical-device
release checks. See [tests/README.md](tests/README.md) and the
[test-realism audit](tests/REALISM_AUDIT.md) for the boundaries and commands.

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
It runs on the synthetic Unicode fixture and all eight configured private
EPUBs. The private release-audit lane was refreshed on 2026-08-13: its paired
schema-v2 report passed all 136 real-EPUB captures, and the full-server lane
passed its browser, KOReader, checkpoint, provenance, and parity gates. These
private reports remain ignored build artifacts and should be regenerated from
the release candidate before each publication.
To build and validate exactly two release archives plus their generated
release manifest, run `scripts/release.sh <version>`. The script updates both
plugin metadata versions in lockstep; review that version change and all three
generated release files before publishing.

## License

[MIT](LICENSE). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the
vendored SLAXML notice and artwork/trademark provenance.
