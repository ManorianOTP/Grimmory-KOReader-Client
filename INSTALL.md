# Installing BookLore KOReader Client

You install both plugins once. After that, updates happen in-app
(**Menu ▸ BookLore ▸ Check for updates**) — you won't need to copy files again.

Both plugins must end up here on the device:

```
koreader/plugins/booklore.koplugin/
koreader/plugins/booklore_sync.koplugin/
```

On a Kindle that's `/mnt/us/koreader/plugins/`.

Pick whichever method suits you. **Method A needs no command line.**

---

## Method A — USB copy (recommended, no command line)

1. Download this project (the green **Code ▸ Download ZIP** button on GitHub, or
   a release ZIP) and unzip it on your computer.
2. On the Kindle, **exit KOReader back to the normal Kindle home screen** — the
   USB drive only appears when KOReader isn't holding it.
3. Connect the Kindle to your computer with a USB cable. It mounts as a drive.
4. Copy the two folders `booklore.koplugin` and `booklore_sync.koplugin` into
   the `koreader/plugins/` folder on that drive.
5. Eject the drive, unplug, and start KOReader.
6. Enable them if needed: **Menu ▸ ⚙ (Settings) ▸ Plugin management**, make sure
   both BookLore plugins are checked, then restart KOReader.

That's it — go to [the README quick start](README.md#quick-start) to log in.

---

## Method B — via the community AppStore plugin (on-device)

If you already use [`appstore.koplugin`](https://github.com/omer-faruq/appstore.koplugin),
it can discover and install BookLore on-device (this repo is tagged with the
`koreader-plugin` GitHub topic). Open **Tools ▸ App Store**, find BookLore,
and install. The AppStore can also keep it updated.

---

## Method C — scp / Wi-Fi (advanced, for tinkerers)

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
   scp -r booklore.koplugin      root@<kindle-ip>:/mnt/us/koreader/plugins/
   scp -r booklore_sync.koplugin root@<kindle-ip>:/mnt/us/koreader/plugins/
   ```
3. Restart KOReader on the device.

> The Kindle's IP often changes between sessions; re-check it each time.

---

## Setting up Tailscale (only if your server isn't on the same network)

If the Kindle and your BookLore server are **not** on the same Wi-Fi/LAN, use
Tailscale to put them on the same private network:

1. Make a free [Tailscale](https://tailscale.com/) account and add your BookLore
   server to your tailnet.
2. On the Kindle: **Menu ▸ BookLore ▸ Tailscale ▸ Install** (needs Wi-Fi;
   downloads ~30 MB).
3. **Menu ▸ BookLore ▸ Tailscale ▸ Connect**, then scan the QR code with your
   phone to authorize the device.
4. Use your server's Tailscale IP (or MagicDNS name) as the server URL when you
   log in.
5. Optional: enable **Autostart on KOReader start** so it reconnects on boot.

---

## Logs

If something goes wrong, the KOReader crash/debug log on the device is at
`/mnt/us/koreader/crash.log`. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
