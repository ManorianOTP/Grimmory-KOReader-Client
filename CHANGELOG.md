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
- Added normalization for Grimmory's current `primaryFile` book payload so
  filenames, formats, sizes, covers, downloads, sorting, and filtering work in
  KOReader.
- Adopted the official Grimmory icon and upstream project links.
- This is intentionally a clean install with no migration of older client
  settings or plugin data.

## [1.0.0] - 2026-06-15

Initial public release: a pair of KOReader plugins that turn a jailbroken Kindle
into a client for a self-hosted [Grimmory](https://github.com/grimmory-tools/grimmory)
server.

### grimmory.koplugin

- Log in to a Grimmory server (URL plus username/password) with multi-account
  support and silent access-token refresh.
- Browse, search, sort (19 options), and filter (14 dimensions with live facet
  counts) your library; covers are cached and versioned.
- Rich book-detail pages mirroring the Grimmory web UI (blurb, genres, rating,
  series) and tuned for E Ink.
- Download books with a live, cancellable progress bar; opened books are matched
  back to their Grimmory record for progress sync.
- Works offline: the last library view is cached and actions are queued, then
  flushed when you are back online.
- Settings menu: account status and switcher, download-folder editor, sign out,
  and a clean uninstall (optionally keeping saved settings for an easy reinstall).
- Tailscale onboarding (install, connect, status, update) to reach a server that
  is not on your local network.
- In-app self-updater — **Grimmory ▸ Check for updates** downloads, verifies
  (sha256), and swaps both plugins from a GitHub release, with crash-safe staging
  and boot-time reconciliation.

### grimmory_sync.koplugin

- Bidirectional reading-progress sync with Grimmory via the kosync protocol,
  translating between KOReader XPointer and Grimmory CFI positions.
- Push is gated on the initial pull so opening a book never overwrites the
  server; a prompt appears when the server is ahead of the device.
- Offline progress queue that flushes once connectivity returns.

[2.0.0]: https://github.com/ManorianOTP/Grimmory-KOReader-Client/releases/tag/v2.0.0
[1.0.0]: https://github.com/ManorianOTP/Grimmory-KOReader-Client/releases/tag/v1.0.0
