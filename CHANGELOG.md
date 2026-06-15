# Changelog

All notable changes to BookLore KOReader Client are documented here. This project
aims to follow [Semantic Versioning](https://semver.org/). Both plugins
(`booklore.koplugin` and `booklore_sync.koplugin`) share a single version per
release.

## [Unreleased]

### Added
- Version metadata in each plugin's `_meta.lua` (source of truth for the updater).
- In-app self-updater: **BookLore ▸ Check for updates** downloads, verifies, and
  swaps both plugins from a GitHub release, then prompts a restart. Crash-safe
  staging + rename swap with boot-time reconciliation.
- **Settings** submenu: account status, account switcher (resume saved logins
  without re-entering a password), download-folder editor, Sign out, and a clean
  Uninstall (with an option to keep saved settings for an easy reinstall).
- Login dialog now has a **Set as default** toggle so a one-off login to another
  server/account doesn't overwrite your saved defaults.
- Multi-account support: switch between saved BookLore accounts; expired sessions
  are flagged and re-prompt for a password.
- README, INSTALL (USB / AppStore / scp install paths), and TROUBLESHOOTING docs.
- `scripts/deploy.sh` (one-command scp deploy) and `scripts/release.sh`
  (test-gated release builder).
- **Tailscale ▸ Update Tailscale** menu item (Tailscale doesn't self-update here):
  checks the installed version against the latest and updates if newer.
- Uninstall (erase-everything) now also removes the app-installed Tailscale.

### Changed
- The login dialog no longer pre-fills a hardcoded personal server URL; the field
  starts from your saved value (empty on first run) with an example hint.
- Tailscale install now reads the version + exact filename from
  pkgs.tailscale.com's own manifest, fixing a download 404 caused by the GitHub
  release tag running ahead of the published static build. Retries a transient
  download failure once.
- Tailscale **Status** now shows a clean summary (connection state, this device,
  IP, peers online) instead of dumping every peer plus the health-check block.
- The Tailscale connect screen warns that the first connect can take up to ~30 s
  before the sign-in QR code appears.
- Library shows an explicit empty-state message when filters/search match nothing.
- Active filters now persist across restarts (like sort/order already did).

### Fixed
- Book downloads no longer cancel themselves partway. Updating the progress
  percentage swapped the on-screen message box, and closing the old box fired its
  "Tap to cancel" handler — silently aborting the transfer and leaving it stuck
  at the last shown percent. Downloads now run to completion.

## [1.0.0]

- Initial baseline: BookLore library client (auth with silent token refresh,
  offline snapshots, browse/sort/filter/search, cover cache, download manager,
  Tailscale onboarding) and the companion reading-progress sync plugin
  (CFI↔XPointer translation, push-after-pull gating, offline queue).
