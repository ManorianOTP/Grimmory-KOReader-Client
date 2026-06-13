# tests/

## Overview

Off-device test harness that exercises the highest-pain subsystems (CFI translation, API HTTP contract, sync state machine, token lifecycle, download registry, Tailscale install pipeline) without a Kindle or real BookLore server. The suite runs under luajit in seconds; on-device SCP verification remains the final gate for runtime-coupled UI flows.

## Architecture

Each spec file maps to one subsystem:

- `cfi_spec.lua` drives `cfi.lua` via an injectable directory-tree Reader. Each `describe` block targets one documented CFI pitfall using a committed synthetic EPUB fixture.
- `api_spec.lua` drives `booklore.koplugin/api.lua` against a local Python `http.server` that serves canned JSON responses from `tests/support/canned_responses/`. Real `socket.http` is used; no mocking.
- `sync_spec.lua` drives `booklore_sync.koplugin/main.lua` by calling plugin methods directly (`sync:onReaderReady()`, `sync:onPageUpdate()`). A virtual clock drives UIManager's `scheduleIn` queue synchronously so the 30s debounce is exercisable without sleep.
- `session_spec.lua` drives `booklore.koplugin/session.lua` (token lifecycle: pre-emptive refresh, 401 silent-renewal retry, token clearing, single-flight guard) against a scripted API double — the wire contract is api_spec's job.
- `downloads_spec.lua` drives `booklore.koplugin/downloads.lua` and pins the registry key format and entry shape booklore_sync's `lookupBookId` reads — the only runtime contract between the two plugins.
- `tailscale_spec.lua` drives `booklore.koplugin/tailscale.lua`. The install pipeline runs for real: the spec builds a genuine `.tgz` with the system tar, serves it from the local HTTP fixture, and the module's default shell exec runs real tar/cp/chmod against a per-test tmp dir. Daemon/up/down/autostart flows use a scripted fake exec because no tailscaled can run in the harness.
- `library_cache_spec.lua` and `view_spec.lua` cover the offline snapshot and the sort/filter model.

KOReader runtime modules (`UIManager`, `ffi/archiver`, `logger`, `datastorage`, `socket.http`, `ltn12`, `json`, `gettext`, `optmath`, KOReader widget classes) are shimmed under `tests/stubs/` and injected by prepending that directory to `package.path` in `tests/run.lua` before any plugin `require()`.

## Design Decisions

**Pure-Lua stubs, not the KOReader desktop emulator.** The emulator is heavyweight under WSL2, hard to script deterministically against, and provides no advantage for the three target subsystems: `cfi.lua` is text-in/text-out, `api.lua` is HTTP, and the sync state machine is plain method calls. On-device SCP verification is still required regardless, so emulator coverage would be largely redundant.

**No real BookLore server.** A local Python `http.server` with ephemeral-port binding catches real HTTP framing bugs (Content-Length, ltn12 sink behavior, header casing) that module-level mocking would miss. Docker integration with a real BookLore server was rejected: it violates the no-server-at-test-time constraint and is incompatible with hobby-project iteration speed.

**ffi/archiver replaced by an injectable Reader parameter.** `ffi/archiver` is a minizip FFI wrapper that cannot run off-device without C deps. `cfi.lua` accepts an optional `reader` parameter in `initBook`; when nil, it falls back to the real `ffi/archiver` (production path unchanged). Tests pass `tests/support/epub_reader.lua` which reads from an unzipped EPUB directory tree, including the iterate-then-extractToMemory drain pattern that `cfi.lua` relies on.

**Committed synthetic fixtures, gitignored recorded fixtures.** Synthetic minimal EPUBs targeting each documented CFI pitfall are committed and form the CI gate. A gitignored `tests/fixtures/recorded/` lane holds real-book EPUBs for local realism (tables, ruby, footnotes) but carries licensing/size constraints. See `tests/fixtures/recorded_README.md` for population instructions.

**luajit, not PUC-Lua.** KOReader's runtime VM is LuaJIT 2.1. Running under luajit ensures FFI-free plugin code paths execute under the same VM as on device.

**No line-coverage threshold, no CI.** The three covered subsystems account for every regression in recent commit history. KOReader UI widgets and the Tailscale onboarding flow are out of scope: they require extensive widget mocking for marginal value and are cheaply verified on device. A numeric coverage target would incentivize testing trivial getters over high-value scenarios. CI is explicitly deferred until contributor count or regression rate justifies the infrastructure.

## Invariants

**Run `scripts/test.sh` before every SCP deploy.** The suite is the off-device gate. On-device verification remains required after that for UI-coupled flows.

**SLAXML v0.8 is pinned.** `booklore_sync.koplugin/slaxml.lua` must not be updated without re-running the full `cfi_spec.lua` suite and manually verifying the `whitespace` fixture round-trip. The `whitespace` fixture fails if `stripWhitespace=true` behavior changes, which would silently break every saved CFI for every user. Upgrade procedure: bump `slaxml.lua`, run `scripts/test.sh`, verify the whitespace describe block passes, then SCP.

**Canned responses are snapshots, not schemas.** Fixtures under `tests/support/canned_responses/` encode the BookLore server contract at capture time. When an on-device regression is traced to a server-contract change (new field, renamed key, reshaped error envelope), recapture the affected fixture from the live server, commit it alongside the test update, and note the BookLore version in the commit message.

**Push waits for pull to complete.** `onReaderReady` sets a `_pull_complete` flag; `onPageUpdate` is a no-op until that flag is set. Without this gate, opening a book pushes a stale local position and overwrites server progress on every open. `sync_spec.lua` tests this ordering explicitly.

**CFI char offsets are UTF-16 code units.** epub.js CFI offsets count UTF-16 code units; XPointer offsets are UTF-8 bytes. A 4-byte UTF-8 character (e.g. emoji) spans 2 UTF-16 code units. The `utf16_surrogate` fixture covers this conversion.

**Body CFI step is not assumed to be `/4`.** `cfi.lua` walks `<html>` children to find `<body>`; it does not assume body is always at index 2 or 4. The `body_index` fixture has a `<head>` element before `<body>`, shifting the step.

**Reverse CFI requires explicit `/text()[N]`.** When converting CFI back to XPointer, the text node selector must be emitted before the char offset. Without it, crengine positions at the element, not the character. The `text_node` fixture covers this.
