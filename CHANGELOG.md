# Changelog

All notable changes to Grimmory KOReader Client are documented here. This
project follows [Semantic Versioning](https://semver.org/). Both plugins
(`grimmory.koplugin` and `grimmory_sync.koplugin`) share a single version per
release.

## [Unreleased]

- Stopped writing raw HTTP response bodies—and therefore possible access or
  refresh tokens and private library metadata—to KOReader's debug log.
- Added locked Node dependency installation and commit-pinned actions to CI,
  restored the complete 22-test JavaScript oracle gate, and made release
  validation reject links and other non-file archive members.
- Added security, contribution, release-status, and third-party provenance
  guidance for a future public release.
- Required SHA-256 for both updater downloads, rejected link and special-file
  archive members before extraction, and added paired interruption recovery at
  every replacement stage without claiming a filesystem-atomic swap.
- Preserved an existing downloaded book until its validated replacement rename
  succeeds, rejected substantially truncated files, and withheld failed
  downloads from the registry.
- Replaced undocumented Amazon, Goodreads, Hardcover, and Grimmory artwork with
  original generic icons and replaced unverified fixture prose with text written
  specifically for the Unicode regression cases.
- Added opt-in, conflict-safe EPUB highlight/note sync and opt-in durable
  reading-session sync.
- Added additive Grimmory shelf mirroring into scoped KOReader collections.
- Turned the top-bar Wi-Fi indicator into a Connection & Sync panel with an
  explicit connect attempt, sync settings, per-book device/server positions,
  and a distinct-book pending badge capped at `9+`.
- Made background bulk progress sync pull each closed book/alternate format
  before pushing, so newer server progress is retained as a pending conflict.
- Fixed progress identity after switching accounts by consistently using the
  active account rather than the legacy default username.
- Fixed EPUB annotation endpoints containing smart punctuation or other
  non-ASCII text by translating CREngine Unicode-scalar offsets to epub.js
  UTF-16 offsets instead of treating them as UTF-8 bytes. Existing uploaded
  annotations are not rewritten automatically: Grimmory CFIs are immutable
  and old records do not prove whether the device or web reader originated
  them; delete and recreate a visibly truncated annotation to repair it safely.
- Added a device-to-web regression that creates a highlight through KOReader's
  reader UI and independently resolves its CFI with Foliate, requiring the full
  KOReader, Grimmory, and DOM-range text to match byte-for-byte on the synthetic
  Unicode fixture and all eight configured real EPUBs.
- Hardened Tailscale installation by checksum-verifying the manifest-selected
  versioned archive and extracted binaries and rejecting traversal, links,
  unexpected members, and post-extraction byte mismatches before either
  executable is installed.

## 2.0.0 - 2026-08-09 (not yet published)

First Grimmory-native version.

- Renamed both plugin directories, IDs, Lua symbols, menus, settings files,
  caches, queues, update staging, release artifacts, documentation, and user
  agents to Grimmory conventions.
- Targeted and verified the client against Grimmory v3.3.1.
- Added canonical Grimmory Book/BookFile normalization, complete paginated
  library traversal, corrected date/lock sorting, version discovery, and exact
  primary/alternative file selection and downloads.
- Physical-only, audiobook, and unsupported records remain visible but cannot
  be downloaded as readable Kindle books; supplementary files are excluded
  from the format chooser.
- Moved progress to Grimmory's App progress API and selected-file identity so
  Kindle and web reader share the same field. EPUB retains the exact custom
  XPointer/CFI converter; PDF/CBX use exact pages; FB2/MOBI/AZW3 use percentage.
- Made queued progress account-, server-, book-, and file-aware, added safe
  background token rotation, and preserved credentials on transient failures.
- Hardened the two-plugin updater with exact manifest membership, manifest
  checksums, safe archive roots, retained backups, rollback, installed-version
  verification, release validation, and CI gates.
- Added upstream project links. Interface artwork is original generic artwork;
  no Grimmory or external rating-service logo is distributed.
- This is intentionally a clean install with no migration of older client
  settings or plugin data.

## [1.0.0] - 2026-06-15 (historical BookLore release)

Version 1.0.0 was published under the old `booklore.koplugin` and
`booklore_sync.koplugin` names. Its release assets are not Grimmory packages and
cannot be updated in place to v2; use the clean-install transition in
[INSTALL.md](INSTALL.md#replacing-the-old-booklore-plugins).

### booklore.koplugin

- Log in to a BookLore server (URL plus username/password) with multi-account
  support and silent access-token refresh.
- Browse, search, sort (19 options), and filter (14 dimensions with live facet
  counts) your library; covers are cached and versioned.
- Rich book-detail pages mirroring the BookLore web UI (blurb, genres, rating,
  series) and tuned for E Ink.
- Download books with a live, cancellable progress bar; opened books are matched
  back to their BookLore record for progress sync.
- Works offline: the last library view is cached and actions are queued, then
  flushed when you are back online.
- Settings menu: account status and switcher, download-folder editor, sign out,
  and a clean uninstall (optionally keeping saved settings for an easy reinstall).
- Tailscale onboarding (install, connect, status, update) to reach a server that
  is not on your local network.
- In-app self-updater — **BookLore ▸ Check for updates** downloaded, verified
  (sha256), and replaced both plugins from a GitHub release, with staging and
  boot-time reconciliation.

### booklore_sync.koplugin

- Bidirectional reading-progress sync with BookLore via the legacy progress API,
  translating between KOReader XPointer and BookLore CFI positions.
- Push is gated on the initial pull so opening a book never overwrites the
  server; a prompt appears when the server is ahead of the device.
- Offline progress queue that flushes once connectivity returns.

[1.0.0]: https://github.com/ManorianOTP/Grimmory-KOReader-Client/releases/tag/v1.0.0
