# Grimmory KOReader Client

A pair of [KOReader](https://koreader.rocks/) plugins that turn a jailbroken
Kindle into a client for a self-hosted [Grimmory](https://github.com/grimmory-tools/grimmory)
library server: browse and download your books, and sync your reading position
back to the server automatically.

> Two plugins, one install:
> - **`grimmory.koplugin`** — log in, browse/search/filter your library, download books, and (optionally) get on your network over Tailscale.
> - **`grimmory_sync.koplugin`** — syncs your reading progress to Grimmory in the background while you read.

## Features

- **Library browser** — covers, 19 sort options, 14 filter dimensions with live
  facet counts, and full-text search over title/author/series.
- **Downloads** — stream a book to the device with a live progress bar; opened
  books are matched back to their Grimmory record for sync.
- **Reading-progress sync** — your position pushes to Grimmory as you read and
  pulls when you open a book, with a conflict prompt when the server is ahead.
- **Works offline** — the last library view is cached, so the app still opens
  and your progress is queued and pushed when you're back online.
- **Multiple accounts** — switch between saved logins without retyping a
  password (shared/household devices).
- **Tailscale onboarding** — install and connect Tailscale from inside the app
  to reach a server that isn't on your local network.
- **In-app updates** — **Grimmory ▸ Check for updates** downloads and installs
  new versions of both plugins for you. No more scp after the first install.

## Prerequisites

You need all four of these before installing:

1. **A jailbroken Kindle running KOReader.** Developed and used on a Kindle
   Paperwhite; other KOReader-capable Kindles should work but are untested.
   See [KindleModding](https://kindlemodding.org/) for jailbreak + KOReader.
2. **A running Grimmory server** you can sign into. See the
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
   and **Download** it. Open the downloaded book to read; your progress syncs
   automatically.

Not on the same network as your server? Set up Tailscale first:
**Menu ▸ Grimmory ▸ Tailscale ▸ Install → Connect** and scan the QR code with
your phone to authenticate.

## Updating

After the first install, you never need to copy files again:
**Menu ▸ Grimmory ▸ Check for updates**. If a newer version is published it is
downloaded, verified, and installed for both plugins; restart KOReader to apply.

## Settings

**Menu ▸ Grimmory ▸ Settings** lets you see who you're signed in as, switch
accounts, change the download folder, sign out, or uninstall both plugins
(with the option to keep your saved settings for an easy reinstall).

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for the common issues
(login failures, "offline" library, Tailscale, update problems).

## For developers

The off-device test harness is documented in [tests/README.md](tests/README.md).
Run the tests with `scripts/test.sh`. To cut a release, see `scripts/release.sh`.

## License

[MIT](LICENSE).
