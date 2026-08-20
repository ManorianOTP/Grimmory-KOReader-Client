# Installing Grimmory KOReader Client

Install both archives from the public
[v2.0.0 release](https://github.com/ManorianOTP/Grimmory-KOReader-Client/releases/tag/v2.0.0).
Grimmory v2 and later can then update in-app with
**Menu ▸ Grimmory ▸ Check for updates**.

The two plugins are one versioned product. Install, update, and remove them as
a pair; mixing versions is unsupported.

Both plugins must end up here on the device:

```
koreader/plugins/grimmory.koplugin/
koreader/plugins/grimmory_sync.koplugin/
```

On a Kindle that's `/mnt/us/koreader/plugins/`.

The documented installation paths are USB copy and, for advanced users, scp.
**Method A needs no command line.**

The directory names above must be directly below `plugins/`. A common archive
extraction mistake is leaving an extra nesting level such as
`plugins/v2.0.0/grimmory.koplugin`; KOReader will not discover the plugin there.

## Replacing the old BookLore plugins

This is a clean installation, not an in-place update from BookLore. The old
updater cannot safely rename the plugin pair, and KOReader can load both pairs
if the old directories are left installed.

Before copying Grimmory, exit KOReader and remove exactly these two old plugin
code directories from the Kindle:

```
/mnt/us/koreader/plugins/booklore.koplugin
/mnt/us/koreader/plugins/booklore_sync.koplugin
```

Do not use a wildcard and do not remove the broader
`/mnt/us/koreader/plugins` directory. Removing the two paths above only removes
the old plugin code. It does not delete downloaded books or server-side data.

Legacy client state is intentionally not migrated. You will log in again, and
old BookLore settings, cache, download-registry, and queued-progress files are
not consumed by Grimmory. Leave those data files in place unless you separately
choose to remove them after verifying the new installation.

---

## Method A — USB copy (recommended, no command line)

1. Open the
   [v2.0.0 release](https://github.com/ManorianOTP/Grimmory-KOReader-Client/releases/tag/v2.0.0)
   and download these two assets:

   - [`grimmory.koplugin-2.0.0.tar.gz`][release-library]
   - [`grimmory_sync.koplugin-2.0.0.tar.gz`][release-sync]

   Extract both archives on your computer. Each must produce one matching
   `*.koplugin` folder. Do not install the historical v1.0.0 assets or GitHub's
   automatically generated **Source code** archives. `manifest.json` belongs to
   the updater and is not copied into KOReader's plugin directory.
2. On the Kindle, **exit KOReader back to the normal Kindle home screen** — the
   USB drive only appears when KOReader isn't holding it.
3. Connect the Kindle to your computer with a USB cable. It mounts as a drive.
4. Copy the two folders `grimmory.koplugin` and `grimmory_sync.koplugin` into
   the `koreader/plugins/` folder on that drive.
5. Eject the drive, unplug, and start KOReader.
6. Enable them if needed: **Menu ▸ ⚙ (Settings) ▸ Plugin management**, make sure
   both Grimmory plugins are checked, then restart KOReader.

That's it — go to [the README quick start](README.md#quick-start) to log in.

### Verify the USB installation

After restarting KOReader:

1. Open **Menu ▸ ⚙ (Settings) ▸ Plugin management** and confirm that
   **Grimmory** and **Grimmory Sync** are both enabled.
2. Confirm that **Menu ▸ Grimmory** contains **Login**, **Browse Library**,
   **Settings**, **Tailscale**, and **Check for updates**.
3. If either plugin is absent, re-check the two exact directory paths and make
   sure each contains its own `_meta.lua` and `main.lua`.

---

## Method B — scp / Wi-Fi (advanced, for tinkerers)

If your jailbroken Kindle runs an SSH server (e.g. via USBNetwork / a network
KUAL extension), extract both v2.0.0 release assets into the same local
directory and push the plugin folders over Wi-Fi.

1. Find the Kindle's IP address (your router's device list, or the SSH
   extension's status screen).
2. From the directory containing both extracted plugin folders:

   ```bash
   scp -r grimmory.koplugin      root@<kindle-ip>:/mnt/us/koreader/plugins/
   scp -r grimmory_sync.koplugin root@<kindle-ip>:/mnt/us/koreader/plugins/
   ```

   If you have a full source checkout, its helper performs those two copies and
   accepts an optional destination directory:

   ```bash
   scripts/deploy.sh <kindle-ip>
   scripts/deploy.sh <kindle-ip> /mnt/us/koreader/plugins
   ```
3. Restart KOReader on the device.

> The Kindle's IP often changes between sessions; re-check it each time.

## Updating

Use **Grimmory ▸ Check for updates** for normal updates. It installs the
checksum-verified pair and asks for a restart. If power is lost during the
replacement, leave the plugin directories in place and restart KOReader; the
updater uses its transaction marker and retained backups to complete or roll
back the pair.

For a manual update, download both archives from the newer release, exit
KOReader, and replace both plugin directories together using Method A or Method
B. Do not copy only changed files: deleted or renamed files from an older
version can otherwise remain installed. Installing unreleased `main` snapshots
is for development and testing, not the normal upgrade path.

---

## Setting up Tailscale (only if your server isn't on the same network)

If the Kindle and your Grimmory server are **not** on the same Wi-Fi/LAN, use
Tailscale to put them on the same private network:

1. Make a free [Tailscale](https://tailscale.com/) account and add your Grimmory
   server to your tailnet.
2. On the Kindle: **Menu ▸ Grimmory ▸ Tailscale ▸ Install Tailscale** (needs Wi-Fi;
   downloads ~30 MB).
3. **Menu ▸ Grimmory ▸ Tailscale ▸ Connect**, then scan the QR code with your
   phone to authorize the device.
4. Use your server's Tailscale IP (or MagicDNS name) as the server URL when you
   log in.
5. Optional: enable **Autostart on KOReader start** so it reconnects on boot.

---

## Logs

If something goes wrong, the KOReader crash/debug log on the device is at
`/mnt/us/koreader/crash.log`. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

Crash logs can contain server addresses, usernames, book metadata, and file
paths. Redact private information before sharing one publicly; see
[SECURITY.md](SECURITY.md).

[release-library]: https://github.com/ManorianOTP/Grimmory-KOReader-Client/releases/download/v2.0.0/grimmory.koplugin-2.0.0.tar.gz
[release-sync]: https://github.com/ManorianOTP/Grimmory-KOReader-Client/releases/download/v2.0.0/grimmory_sync.koplugin-2.0.0.tar.gz
