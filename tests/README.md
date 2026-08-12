# tests/

## Overview

The test suite has three complementary layers. Fast Lua tests isolate logic such
as CFI translation, API framing, sync state, token lifecycle, downloads, and
Tailscale. The visual suite runs the production widgets inside a pinned KOReader
desktop release and compares screenshots with explicitly approved references.
Finally, a private companion lane repeats every relevant synthetic scene with
gitignored real EPUBs, including full reader, sync, annotation, session,
download, registry, and shelf-collection journeys.

## Architecture

Each spec file maps to one subsystem:

- `cfi_spec.lua` drives `cfi.lua` via an injectable directory-tree Reader. Each `describe` block targets one documented CFI pitfall using a committed synthetic EPUB fixture.
- `api_spec.lua` drives `grimmory.koplugin/api.lua` against a local Python `http.server` that serves canned JSON responses from `tests/support/canned_responses/`. Real `socket.http` is used; no mocking.
- `sync_spec.lua` drives `grimmory_sync.koplugin/main.lua` by calling plugin methods directly (`sync:onReaderReady()`, `sync:onPageUpdate()`). A virtual clock drives UIManager's `scheduleIn` queue synchronously so the 30s debounce is exercisable without sleep.
- `session_spec.lua` drives `grimmory.koplugin/session.lua` (token lifecycle: pre-emptive refresh, 401 silent-renewal retry, token clearing, single-flight guard) against a scripted API double — the wire contract is api_spec's job.
- `downloads_spec.lua` drives `grimmory.koplugin/downloads.lua` and pins the registry key format and entry shape grimmory_sync's `lookupBookId` reads — the only runtime contract between the two plugins.
- `tailscale_spec.lua` drives `grimmory.koplugin/tailscale.lua`. The install pipeline runs for real: the spec builds a genuine `.tgz` with the system tar, serves it from the local HTTP fixture, and the module's default shell exec runs real tar/cp/chmod against a per-test tmp dir. Daemon/up/down/autostart flows use a scripted fake exec because no tailscaled can run in the harness.
- `library_cache_spec.lua` and `view_spec.lua` cover the offline snapshot and the sort/filter model.
- `emulator/visual_driver.koplugin` supplies deterministic, named UI scenes to a real KOReader desktop process. It records direct layout assertions and screenshots, then exits; it is test-only and cannot enter a release archive.
- `visual/` contains the approved screenshots and tests for the strict comparison and review workflow.

KOReader runtime modules (`UIManager`, `ffi/archiver`, `logger`, `datastorage`, `socket.http`, `ltn12`, `json`, `gettext`, `optmath`, KOReader widget classes) are shimmed under `tests/stubs/` and injected by prepending that directory to `package.path` in `tests/run.lua` before any plugin `require()`.

## Design Decisions

**Use the smallest suitable layer.** Text, state, storage, and HTTP behavior stays in the fast Lua suite because a graphical process would add time without increasing confidence. UI behavior uses a pinned KOReader desktop release because mocked widgets cannot prove that spacing, wrapping, clipping, and icon placement look right. The visual suite is deliberately separate, so it does not make ordinary logic tests slower or harder to diagnose.

**Deterministic server by default; pinned real server when needed.** Fast tests
and screenshot approval use a local ephemeral-port fixture because its stable
IDs and responses make failures reproducible. The private download companion
streams the exact selected EPUB bytes through that server. A slower optional
lane starts the official pinned Grimmory image plus MariaDB and imports the
private books for API compatibility checks; it does not approve screenshots.
See `emulator/GRIMMORY_FIXTURE_SERVER.md`.

### One-command private full-server acceptance

Prerequisites are a running Docker engine, Python 3, Node.js 20+ with the checked-in
Playwright dependencies, WSL on Windows for the pinned KOReader desktop build,
and the eight explicitly named private EPUBs in the source directory. The
provider metadata cache must already have been captured through Grimmory's web
metadata-selection flow; the run replays it without contacting providers.

From PowerShell at the repository root:

```powershell
python scripts/grimmory-real-stack.py run `
  --source-dir (Join-Path $env:USERPROFILE 'Downloads') `
  --output build/grimmory-compatibility/full-suite `
  --metadata-cache build/grimmory-compatibility/private-metadata-cache `
  --node (Get-Command node).Source `
  --keep-on-failure `
  -- python scripts/run-grimmory-compatibility-suite.py `
       --runtime '{runtime}' `
       --output build/grimmory-compatibility/full-suite/results
```

The outer controller resolves that exact Node executable, runs `--version`
before Docker starts, records it in the private provenance, and requires the
child suite to validate and use the same binary. A WSL-native outer launch must
therefore supply native Linux Node.js rather than a Windows `node.exe` path.

Open `build/grimmory-compatibility/full-suite/results/index.html` to inspect the
ordinary browser and final browser-producer screenshots, KOReader screenshots,
exact server-effect checks, the device-to-web Foliate report, cover comparison,
fixture parity, and lane statuses from one page. The controller runs ordinary
browser journeys first, the nine-book browser producer, its exact read-only
server verifier, then KOReader. KOReader retains its genuine device-origin
annotation for a final visible Grimmory reader consumer, which resolves the
complete Foliate DOM Range and deletes only after exact KOReader/server/browser
text equality. Fixture parity is the final consumer. These artifacts contain
private book-derived UI and remain under ignored `build/`.

The pinned Grimmory 3.3.1 web reader has one known upstream progress-save loss
window. Its `BookPatchService` sends relocations through `exhaustMap`, so a
rapid page movement made while a slow progress POST is still in flight can be
dropped. The blocking acceptance journey models deliberate human reading: it
waits for the initial successful save, physically clicks the visible and
enabled **Next Section** control once, proves the rendered location changed,
requires a later successful POST with a different CFI and percentage, and then
checks the exact persisted value with a read-only GET. That strict journey
does not claim rapid input is lossless. The rapid-input case is retained as a
non-blocking pinned-upstream capability boundary and should be promoted to a
passing regression only when a future Grimmory release changes the save
operator or queues the latest relocation.

On success, the outer lifecycle stops and removes its uniquely named Grimmory
and MariaDB containers and deletes the disposable database, staged books, and
other mutable server state. `--keep-on-failure` retains that state only when a
lane fails and prints the exact status/log/down commands; run the printed `down`
command after diagnosis. Omitting `--keep-on-failure` tears down after failures
as well.

**ffi/archiver replaced by an injectable Reader parameter.** `ffi/archiver` is a minizip FFI wrapper that cannot run off-device without C deps. `cfi.lua` accepts an optional `reader` parameter in `initBook`; when nil, it falls back to the real `ffi/archiver` (production path unchanged). Tests pass `tests/support/epub_reader.lua` which reads from an unzipped EPUB directory tree, including the iterate-then-extractToMemory drain pattern that `cfi.lua` relies on.

**Committed synthetic fixtures, gitignored recorded fixtures.** Synthetic minimal EPUBs targeting each documented CFI pitfall are committed and form the CI gate. A gitignored `tests/fixtures/recorded/` lane holds real-book EPUBs for local realism (tables, ruby, footnotes) but carries licensing/size constraints. See `tests/fixtures/recorded_README.md` for population instructions.

**luajit, not PUC-Lua.** KOReader's runtime VM is LuaJIT 2.1. Running under luajit ensures FFI-free plugin code paths execute under the same VM as on device.

**No numeric line-coverage threshold; CI enforces functional gates.** A numeric coverage target would incentivize testing trivial getters over high-value scenarios. GitHub Actions runs `scripts/ci-check.sh`, which executes the complete fast suite, compiles every plugin Lua file with LuaJIT, and rejects stale BookLore branding. A separate job runs the pinned KOReader visual scenes and strict screenshot comparison. The workflow also builds both plugin archives and validates their manifest, checksums, sizes, roots, metadata versions, and required entry points.

## Visual workflow

Run `bash scripts/run-koreader-visual-tests.sh` on Linux or through WSL. It downloads
the checksum-pinned KOReader release into an external cache, starts every scene
with fresh settings, captures portrait and landscape PNGs, checks direct layout
facts, and compares the images with `tests/visual/references/`. A mismatch
produces a JSON report, HTML review page, and before/current/diff images. See
`tests/visual/README.md` for the deliberately separate reference-approval
commands.

To compare every synthetic scene with its mapped real-book companion, run
`bash scripts/run-real-epub-companions.sh --source-dir /path/to/epubs
--output build/visual/real-epub-companions --orientation both`. The private
paths, hashes, metadata, covers, downloads, and reports stay under ignored
`build/`; CI discovers Lua, JavaScript, Python, and visual cases and checks that
every test has exactly one pinned realism classification, so no new case can
silently inherit an exemption. Preparation requires the
ignored provider cache captured through Grimmory's visible web metadata
selection. Every real visual DTO is bound to the EPUB's exact SHA-256 and uses
the cache's complete native metadata projection and exact cover bytes;
fictional library/shelf/progress state is retained only as an explicitly
non-provider catalogue stress overlay. The paired report fails on missing or
mixed manifest, metadata, EPUB, cover, offline-replay, KOReader, or source-code
provenance.

Real-companion results use visual result schema v2. Every assertion has a
`scenario` or `provenance` scope and a stable name. The tracked schema-v1
outcome contract pins the exact assertion-name inventories for the synthetic,
private, and shared sides of every scenario. The reporter recomputes those
inventories, the adjacent PNG hash/dimensions, the private EPUB digest, the
provider-cache manifest digest, and each native metadata-projection digest.
`status: passed`, a source-code marker, a missing assertion list, or invented
64-character hashes are not evidence. Older result-schema-v1 galleries remain
viewable history but cannot produce a green companion report.

Full-server Playwright journey names are likewise pinned to
`tests/compatibility/full_server_outcome_contracts.json`. The repository policy
checks that the contract and executable journey inventories are identical and
that every reviewed, comment-insensitive executable test-body digest still
matches. Each completed Playwright journey also emits schema-v1 named boolean
outcomes into `web-reader-checkpoints.json`; the controller requires the exact
selected journey and outcome sets, with every value `true`, before the next
consumer can run. A retained title, dead comment, no-op body, missing runtime
record, or invented outcome name therefore fails. Journey-specific checkpoint,
KOReader, parity, and provenance verifiers still own the underlying values.

The full-server lane also validates provider metadata through live Grimmory
APIs. It captures one browser-selected provider result per private EPUB,
replays it through supported Grimmory APIs on disposable stacks, and asserts
both populated and deliberately absent fields on every field rendered by the
integration surfaces it covers: the post-login Dashboard,
the shared book-browser grid/table renderer, Series browser/detail, Author
browser/detail, Metadata Manager, full book detail, ebook-reader header, and
Notebook book groups created through a real note journey. Routes that reuse the
same `BookBrowserComponent` are covered once instead of duplicating identical
tests for each library/shelf context. See
`compatibility/METADATA_REALISM.md`; private metadata,
provider IDs, covers and source identities remain below ignored `build/`.

## Invariants

**Run `scripts/test.sh` before every SCP deploy.** Run the visual suite as well whenever a change can affect a KOReader screen. Physical-device checks still matter for Kindle-specific behavior such as touch input, wake/suspend, and e-ink refresh, but ordinary layout regressions should be caught on the computer first.

**SLAXML v0.8 is pinned.** `grimmory_sync.koplugin/slaxml.lua` must not be updated without re-running the full `cfi_spec.lua` suite and manually verifying the `whitespace` fixture round-trip. The `whitespace` fixture fails if `stripWhitespace=true` behavior changes, which would silently break every saved CFI for every user. Upgrade procedure: bump `slaxml.lua`, run `scripts/test.sh`, verify the whitespace describe block passes, then SCP.

**Canned responses are snapshots, not schemas.** Fixtures under `tests/support/canned_responses/` encode the Grimmory server contract at capture time. When an on-device regression is traced to a server-contract change (new field, renamed key, reshaped error envelope), recapture the affected fixture from the live server, commit it alongside the test update, and note the Grimmory version in the commit message.

**Push waits for pull to complete.** Page updates are captured durably while a
pull is pending, but the current file cannot drain until the pull/decision gate
opens. Choosing **Jump Ahead** explicitly discards that file's pre-decision
queue entry; otherwise the next periodic flush could overwrite the server
position the user just chose. Choosing **Sync Here** replaces it with the
current position and pushes normally. `sync_spec.lua` tests this ordering.

**CFI char offsets are UTF-16 code units.** epub.js CFI offsets count
UTF-16 code units; CREngine XPointer offsets count Unicode scalar values
(code points), not UTF-8 bytes. An astral character such as emoji therefore
spans 2 epub.js units but 1 XPointer unit. The `utf16_surrogate` fixture covers
this conversion.

**Body CFI step is not assumed to be `/4`.** `cfi.lua` walks `<html>` children to find `<body>`; it does not assume body is always at index 2 or 4. The `body_index` fixture has a `<head>` element before `<body>`, shifting the step.

**Reverse CFI requires explicit `/text()[N]`.** When converting CFI back to XPointer, the text node selector must be emitted before the char offset. Without it, crengine positions at the element, not the character. The `text_node` fixture covers this.
