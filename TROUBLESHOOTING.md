# Troubleshooting

The device log is at `/mnt/us/koreader/crash.log` on the Kindle — check it if a
symptom below doesn't match.

## "Login failed"

- **Wrong address or port.** The URL is your Grimmory server, e.g.
  `192.168.1.50:6060`. You can leave off `http://` (it's added for you). Don't
  include a path. If your server uses HTTPS, type the full `https://…` URL.
- **Server not reachable from the Kindle.** Confirm the Kindle and the server
  are on the same network — or that Tailscale is connected
  (**Grimmory ▸ Tailscale ▸ Status**). From a phone on the same network, try
  opening the same URL in a browser to confirm the server is up.
- **Wrong username/password.** The message shows the server's response; a `401`
  means the credentials were rejected.
- **Blank URL.** If you tap Login with the server field empty, you'll be asked
  to enter the server URL — it won't send a doomed request.

## "Grimmory sign-in expired. Log in again."

Your saved session was rejected by the server (the token expired and couldn't be
renewed). Open **Grimmory ▸ Login** (or **Settings ▸** the account line) and sign
in again. Your server URL and username are still pre-filled.

## The library says it's offline / shows an old copy

- The app fell back to the last cached library because it couldn't reach the
  server. Check Wi-Fi, and that the server (and Tailscale, if used) is up.
- Tap **Browse Library** again to retry online; you'll be offered to turn Wi-Fi
  on if it's off.
- Downloads are disabled while offline (the button reads "Unavailable offline").

## Tailscale won't connect

- **Install fails partway.** It needs Wi-Fi and ~30 MB. A transient drop is
  retried once; if it still fails, retry **Tailscale ▸ Install**.
- **Stuck needing auth.** **Tailscale ▸ Connect** shows a QR code / URL — open it
  on your phone or computer and approve the device in your tailnet.
- **Connected but server still unreachable.** Make sure the Grimmory server is
  also in your tailnet, and use its Tailscale IP / MagicDNS name as the server
  URL.
- **Check state** any time with **Tailscale ▸ Status**.

## Reading progress isn't syncing

- Sync only runs for **books downloaded through the Grimmory app** — sideloaded
  files aren't matched to a server record. Download the book via
  **Browse Library** instead of copying it on manually.
- Open **Grimmory Sync** in the reader menu (while a book is open) to see the
  status: whether the server position was pulled, how many changes are queued,
  and the server it's using. Tap **Sync now** to push immediately.
- Push is paused until the first pull succeeds (so it never overwrites the
  server on open). If pull keeps failing, that's a connectivity/sign-in issue —
  see the login notes above.

## "Check for updates" problems

- **"Couldn't check for updates."** The Kindle couldn't reach the update server.
  Check Wi-Fi / Tailscale and try again.
- **"Update failed."** The download or install didn't complete (e.g. connection
  dropped). Nothing was changed — your current version still runs. Try again on
  a stronger connection.
- **After updating, the new version isn't active.** Restart KOReader (or the
  Kindle). Updates only take effect on the next start.
- **An update was interrupted (power loss mid-install).** It self-heals: the
  plugin finishes or rolls back the swap automatically the next time KOReader
  starts.

## scp install problems (Method C)

- **`connection refused` / `no route to host`.** The Kindle isn't running an SSH
  server or the IP is wrong/changed. Re-check the IP and that your SSH (e.g.
  USBNetwork) extension is enabled. Or just use the USB method in
  [INSTALL.md](INSTALL.md) — it needs no networking.

## Starting fresh

**Settings ▸ Uninstall Grimmory** removes both plugins. Choose **Keep settings**
to keep your server URL and accounts for a quick reinstall, or **Erase
everything** for a clean wipe. Restart KOReader afterward.
