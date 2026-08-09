# Changelog

All notable changes to Grimmory KOReader Client are documented here. This
project follows [Semantic Versioning](https://semver.org/). Both plugins
(`grimmory.koplugin` and `grimmory_sync.koplugin`) share a single version per
release.

## [2.0.0] - 2026-08-09

First Grimmory-native release.

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
- Hardened the two-plugin updater with exact manifest membership, fail-closed
  checksums, safe archive roots, retained backups, rollback, installed-version
  verification, reproducible release validation, and CI gates.
- Adopted the official Grimmory icon and upstream project links.
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
- In-app self-updater — **BookLore ▸ Check for updates** downloads, verifies
  (sha256), and swaps both plugins from a GitHub release, with crash-safe staging
  and boot-time reconciliation.

### booklore_sync.koplugin

- Bidirectional reading-progress sync with BookLore via the legacy progress API,
  translating between KOReader XPointer and BookLore CFI positions.
- Push is gated on the initial pull so opening a book never overwrites the
  server; a prompt appears when the server is ahead of the device.
- Offline progress queue that flushes once connectivity returns.

[2.0.0]: https://github.com/ManorianOTP/Grimmory-KOReader-Client/releases/tag/v2.0.0
[1.0.0]: https://github.com/ManorianOTP/Grimmory-KOReader-Client/releases/tag/v1.0.0
