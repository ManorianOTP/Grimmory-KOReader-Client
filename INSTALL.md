# Installing Grimmory KOReader Client

You install both plugins once. Grimmory v2 and later can then update in-app
(**Menu ▸ Grimmory ▸ Check for updates**) after a public release is available.

Both plugins must end up here on the device:

```
koreader/plugins/grimmory.koplugin/
koreader/plugins/grimmory_sync.koplugin/
```

On a Kindle that's `/mnt/us/koreader/plugins/`.

The supported installation paths today are USB copy and, for advanced users,
scp. **Method A needs no command line.** The KOReader community App Store does
not currently offer this Grimmory client.

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

1. Download this project with the green **Code ▸ Download ZIP** button on
   GitHub and unzip it on your computer. There is not yet a published Grimmory
   release; the existing `v1.0.0` release belongs to the earlier BookLore
   client and must not be installed as Grimmory.
2. On the Kindle, **exit KOReader back to the normal Kindle home screen** — the
   USB drive only appears when KOReader isn't holding it.
3. Connect the Kindle to your computer with a USB cable. It mounts as a drive.
4. Copy the two folders `grimmory.koplugin` and `grimmory_sync.koplugin` into
   the `koreader/plugins/` folder on that drive.
5. Eject the drive, unplug, and start KOReader.
6. Enable them if needed: **Menu ▸ ⚙ (Settings) ▸ Plugin management**, make sure
   both Grimmory plugins are checked, then restart KOReader.

That's it — go to [the README quick start](README.md#quick-start) to log in.

---

## Method B — scp / Wi-Fi (advanced, for tinkerers)

If your jailbroken Kindle runs an SSH server (e.g. via USBNetwork / a network
KUAL extension) you can push the plugins over Wi-Fi.

1. Find the Kindle's IP address (your router's device list, or the SSH
   extension's status screen).
2. From this project's root on your computer:

   ```bash
   scripts/deploy.sh <kindle-ip>
   ```

   which runs, in effect:

   ```bash
   scp -r grimmory.koplugin      root@<kindle-ip>:/mnt/us/koreader/plugins/
   scp -r grimmory_sync.koplugin root@<kindle-ip>:/mnt/us/koreader/plugins/
   ```
3. Restart KOReader on the device.

> The Kindle's IP often changes between sessions; re-check it each time.

---

## Setting up Tailscale (only if your server isn't on the same network)

If the Kindle and your Grimmory server are **not** on the same Wi-Fi/LAN, use
Tailscale to put them on the same private network:

1. Make a free [Tailscale](https://tailscale.com/) account and add your Grimmory
   server to your tailnet.
2. On the Kindle: **Menu ▸ Grimmory ▸ Tailscale ▸ Install** (needs Wi-Fi;
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
