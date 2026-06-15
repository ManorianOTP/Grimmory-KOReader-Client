# Changelog

All notable changes to BookLore KOReader Client are documented here. This
project follows [Semantic Versioning](https://semver.org/). Both plugins
(`booklore.koplugin` and `booklore_sync.koplugin`) share a single version per
release.

## [1.0.0] - 2026-06-15

Initial public release: a pair of KOReader plugins that turn a jailbroken Kindle
into a client for a self-hosted [BookLore](https://github.com/booklore-app/booklore)
server.

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

- Bidirectional reading-progress sync with BookLore via the kosync protocol,
  translating between KOReader XPointer and BookLore CFI positions.
- Push is gated on the initial pull so opening a book never overwrites the
  server; a prompt appears when the server is ahead of the device.
- Offline progress queue that flushes once connectivity returns.

[1.0.0]: https://github.com/ManorianOTP/BookLore-KOReader-Client/releases/tag/v1.0.0
