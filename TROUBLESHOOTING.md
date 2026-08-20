# Troubleshooting

The device log is at `/mnt/us/koreader/crash.log` on the Kindle — check it if a
symptom below doesn't match. Redact server addresses, usernames, book details,
and local paths before sharing it.

## Grimmory is missing from the KOReader menu

- Open **Menu ▸ ⚙ (Settings) ▸ Plugin management** and make sure both
  **Grimmory** and **Grimmory Sync** are enabled, then restart KOReader.
- Verify the exact paths
  `/mnt/us/koreader/plugins/grimmory.koplugin/_meta.lua` and
  `/mnt/us/koreader/plugins/grimmory_sync.koplugin/_meta.lua`. An extra folder
  created while unzipping prevents KOReader from discovering them.
- Install both folders from the same source snapshot. A mixed plugin pair is
  unsupported.

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
- New downloads are disabled while offline. Already-downloaded alternative
  formats remain available through **Choose format**.

## Tailscale won't connect

- **Install fails partway.** It needs Wi-Fi and ~30 MB. A transient drop is
  retried once; if it still fails, retry **Tailscale ▸ Install Tailscale**.
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
- The client writes the same selected-file progress used by Grimmory's web
  reader: exact CFI for EPUB, exact page for PDF/CBX, and percentage for
  FB2/MOBI/AZW3. A failed exact-position capture stays queued rather than
  clearing a valid web-reader position.
- Do not run Grimmory's native KOReader/KOSync-to-web bridge for the same books
  at the same time. This plugin's direct sync is authoritative; enabling both
  creates two independent writers.

## Annotation sync is missing or stays pending

- Annotation sync is opt-in. Open **Connection & Sync** from a Grimmory Wi-Fi
  icon and enable **Sync annotations**, then use **Sync all now**.
- Only highlights and notes in the primary EPUB downloaded through Grimmory are
  eligible. Bookmarks, alternative EPUB files, PDFs, CBX files, and sideloaded
  books are deliberately excluded.
- A pending annotation conflict means both copies changed, an immutable CFI no
  longer matches, or a server operation failed. The plugin fails closed and
  does not choose a winner. Preserve any text you need from both copies before
  deleting and recreating a damaged highlight.
- If an older build uploaded visibly truncated text around smart punctuation or
  emoji, delete and recreate that highlight. Grimmory CFIs are immutable, so a
  later build cannot safely rewrite the existing record in place.

## Reading sessions are absent

- Reading-session sync is opt-in under **Connection & Sync**. Enabling it does
  not reconstruct sessions from before it was enabled.
- A session shorter than 30 seconds is discarded. A qualifying session is
  finalized when the document closes or KOReader suspends or powers off.
  Activity separated by more than 30 idle minutes starts a new session rather
  than inventing continuous reading time.
- Sessions are queued offline. Use **Sync all now** after reconnecting; a retry
  checks recent server history before posting so an accepted session is not
  duplicated after a lost response.

## Grimmory shelves are not appearing as KOReader collections

- **Mirror shelves into KOReader collections** is enabled by default but can be
  changed under **Connection & Sync**.
- Browse the library while online to fetch fresh shelf membership. Only books
  downloaded through this plugin can be added to a local collection.
- Mirrored names start with `Grimmory — `. User-added members are preserved.
  When a shelf disappears from the server, its local collection is retained
  rather than deleted automatically.

## "Check for updates" problems

- **"Couldn't check for updates."** The Kindle couldn't reach the update server.
  Check Wi-Fi / Tailscale and try again.
- **"Update failed."** The download or install didn't complete (for example,
  the connection dropped). Restart KOReader first so any transaction marker is
  reconciled, confirm both plugins still report the same version, then retry on
  a stronger connection.
- **After updating, the new version isn't active.** Restart KOReader (or the
  Kindle). Updates only take effect on the next start.
- **An update was interrupted (power loss mid-install).** It self-heals: the
  plugin finishes or rolls back the swap automatically the next time KOReader
  starts.

## scp install problems (Method B)

- **`connection refused` / `no route to host`.** The Kindle isn't running an SSH
  server or the IP is wrong/changed. Re-check the IP and that your SSH (e.g.
  USBNetwork) extension is enabled. Or just use the USB method in
  [INSTALL.md](INSTALL.md) — it needs no networking.

## Starting fresh

**Settings ▸ Uninstall Grimmory** removes both plugins. Choose **Keep settings**
to keep your server URL, accounts, downloads, and Tailscale installation for a
quick reinstall, or **Erase all** for a clean wipe. Restart KOReader afterward.

"Erase all" also removes the configured Grimmory download directory,
cached library/cover data, the download registry, and pending sync state. Back
up any downloaded books you want to keep before choosing it. It also removes
the plugin-managed Tailscale installation and state.
