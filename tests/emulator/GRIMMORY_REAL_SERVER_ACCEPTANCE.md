# Full Grimmory acceptance stack

This lane runs the actual Grimmory web application and MariaDB. It complements
the fast Python protocol fixture; it does not replace deterministic Lua tests
or pixel baselines.

## What the lifecycle guarantees

Every run:

1. matches and validates the eight private EPUBs by the exact SHA-256 identities
   in the ignored metadata cache, without tracking their names, and generates
   the same long-form, copyright-safe synthetic EPUB used by the reader tests;
2. resolves the configured Grimmory and MariaDB tags to immutable
   `repository@sha256` image references and starts those exact references;
3. creates a unique Compose project, random loopback-only host port, random
   application account, random database credentials, and fresh bind-mounted
   application/database directories;
4. completes setup through Grimmory's public setup API, creates an
   `EMBEDDED`-metadata library through the public library API, and lets the real
   scanner import all nine books;
5. maps stable test aliases (`synthetic`, `real-1001` ... `real-1008`) to the
   database-generated book IDs without assuming their order;
6. supplies `runtime.json` to browser and KOReader journeys; and
7. captures redacted Docker logs, stops only the uniquely named project, and
   deletes the disposable database, application data, and staged EPUBs.

It never edits the database, mounts a user's Grimmory data, or connects to a
pre-existing Grimmory server. Original private EPUBs are hard-linked when
possible and copied otherwise. Everything derived from them remains below the
Git-ignored `build/grimmory-compatibility/` directory.

For the first metadata capture, before source hashes exist in a cache, pass
`--private-source-map` with an ignored JSON file containing eight neutral
fixture IDs and paths. Normal acceptance commands already pass
`--metadata-cache`, so later runs rediscover the same files by bytes even when
the source directory contains unrelated EPUBs or duplicate filenames.

## One-command test lifecycle

From PowerShell:

```powershell
python scripts/grimmory-real-stack.py run `
  --source-dir (Join-Path $env:USERPROFILE 'Downloads') `
  --output build/grimmory-compatibility/my-run `
  --node (Get-Command node).Source `
  -- node tests/compatibility/run-web-reader.js `
       --runtime '{runtime}'
```

From WSL:

```bash
python3 scripts/grimmory-real-stack.py run \
  --source-dir /mnt/c/Users/<windows-user>/Downloads \
  --output build/grimmory-compatibility/my-run \
  --metadata-cache build/grimmory-compatibility/private-metadata-cache \
  --node "$(command -v node)" \
  -- node tests/compatibility/run-web-reader.js \
       --runtime '{runtime}'
```

The literal `{runtime}` argument is replaced with the absolute path to the
descriptor. The same path is also exported as `GRIMMORY_COMPAT_RUNTIME`.
`--node` must be Node.js 20 or newer. It is resolved and executed before books are staged or Docker starts;
the exact executable and version are recorded and passed to the child. A WSL
launch therefore needs native Linux Node.js and must not point at `node.exe`.
Successful runs are always torn down. Failed runs are also torn down unless
`--keep-on-failure` is supplied; in that case the descriptor prints the exact
follow-up commands needed for inspection and teardown.

`grimmory-real-stack.py run` deliberately owns one child process, not a hidden
list of test tools. Metadata replay is a pre-child lifecycle step when
`--metadata-cache` is present. The short command above deliberately runs only
the web-reader journey. For the complete lane, pass the suite controller shown
below as the one child command. It runs browser journeys, the final browser
checkpoint producer, KOReader, and fixture parity sequentially against
`GRIMMORY_COMPAT_RUNTIME`, and returns non-zero if any lane fails. This clean
boundary lets those consumers evolve independently while the stack controller
still guarantees a single shared server and one final teardown.

For manual diagnosis:

```bash
python3 scripts/grimmory-real-stack.py up \
  --source-dir /mnt/c/Users/<windows-user>/Downloads \
  --output build/grimmory-compatibility/debug-run \
  --offline

python3 scripts/grimmory-real-stack.py status \
  --runtime build/grimmory-compatibility/debug-run/runtime.json

python3 scripts/grimmory-real-stack.py logs \
  --runtime build/grimmory-compatibility/debug-run/runtime.json

python3 scripts/grimmory-real-stack.py down \
  --runtime build/grimmory-compatibility/debug-run/runtime.json
```

`--offline` skips registry pulls but still requires locally cached images with
resolvable repository digests. Normal release runs should omit it so a moved
tag cannot silently reuse stale local content. `--preserve-data` on `down` is
for debugging only and deliberately disables disposable-data cleanup.

## Runtime contract

`runtime.json` is private, ignored test state. Consumers may use:

- `baseUrl`, `username`, and `password` for the real web/API login;
- `runRoot` for their own ignored artifacts;
- `sourceManifest` for original path/hash validation;
- `books[].alias`, `kind`, `sourceSha256`, `stagedName`, and `serverBookId`;
- `syntheticBook` for the copyright-safe control;
- `library` for the generated server library;
- `images.*.resolvedReference` and `images.*.imageId` for provenance;
- `docker` for Docker Engine and Compose versions; and
- `keepOnFailure` to follow the outer runner's diagnostic policy.

Consumers must not retain the application password or access/refresh tokens in
their reports. The stack's own `artifacts/docker.log` replaces all generated
passwords and bearer tokens before it is written.

## Test realism policy

The stack provides infrastructure, not permission to take shortcuts. A
book-related acceptance journey must run first with `synthetic` and then with
at least one appropriate `real-*` alias; format/import/open coverage runs over
all eight. User workflows should operate through Grimmory's web reader,
KOReader, or public APIs exposed by those UIs. Direct database edits and
mutating fixture files are not valid acceptance-test actions.

The suite controller's final consumer is a behavioural parity check between
this stack and the fast Python fixture:

```bash
python3 tests/compatibility/server_contract_parity.py \
  --runtime build/grimmory-compatibility/my-run/runtime.json \
  --output build/grimmory-compatibility/my-run/parity/report.json
```

It performs the same authentication, library, book/file, primary EPUB
download, progress, annotation, and reading-session workflows against the
fixture, the synthetic full-server control, and all eight private real EPUBs.
It compares exact HTTP outcomes and recursive key/type/body shapes for auth,
health, version, libraries, shelves, files, progress, annotations, and reading
sessions. Book page and detail responses must use the exact Grimmory 3.3.1
outer envelope, page/link records, nested file records, detail lock flags, and
the same production-consumer semantics on the fixture, the synthetic control,
and all eight real EPUBs. Only an enumerated set of per-user catalogue state
(progress, reading dates/status, personal rating and shelf membership) is
normalized. Provider-owned metadata values and legitimate missing provider
fields are deliberately excluded from fixture equality: the browser and
KOReader metadata lanes compare those exact values and absences with the
ignored SHA-bound provider cache instead. Negative unit fixtures prove that an
added/removed outer field, a malformed nested file/page/shelf record, a missing
metadata object, or an unknown provider field fails closed. Generated IDs,
timestamps, titles, paths, credentials, and binary hashes are never published.
This is what makes the fixture safe to keep using for fast deterministic
screenshots: contract drift such as Grimmory's `204` annotation delete, empty
`202` session response, or a DTO-key change cannot pass silently.

Metadata import starts with `metadataSource=EMBEDDED`. A separate ignored cache
may replay previously captured real provider results through Grimmory's public
metadata and cover APIs. This avoids external provider rate limits while still
testing exactly what the real UI and API consume; sidecars and database writes
are intentionally not used. Passing `--metadata-cache PATH` makes replay and
verification a mandatory post-scan lifecycle step. The canonical `runtime.json`
is then enriched with the expected metadata and cached-cover provenance before
any wrapped acceptance command starts.

Private real-book cache identity is the exact EPUB SHA-256. The generated
synthetic control uses a stable `synthetic:<alias>` identity so body-only or
privacy-text generator edits do not require a pretend provider recapture. This
does not weaken its semantic gate: before the first replay PUT, the harness
reads the freshly imported synthetic book through Grimmory's public detail API
and requires its complete stable metadata projection to equal the cached
projection. The enriched runtime records the old/current source hashes,
projection hash, endpoint, and successful pre-replay comparison. Any title,
author, language, category, tag, mood, or other persisted metadata drift fails
before replay can overwrite it.

## Complete suite and KOReader lane

Use the shared controller as the full stack's one child command:

```powershell
python scripts/grimmory-real-stack.py run `
  --source-dir (Join-Path $env:USERPROFILE 'Downloads') `
  --output build/grimmory-compatibility/full-suite `
  --metadata-cache build/grimmory-compatibility/private-metadata-cache `
  --node (Get-Command node).Source `
  -- python scripts/run-grimmory-compatibility-suite.py `
       --runtime '{runtime}' `
       --output build/grimmory-compatibility/full-suite/results
```

It uses the same disposable server in a strict order. First it runs every
ordinary browser journey except the KOReader checkpoint producer. It then runs
the producer alone, immediately compares its artifact with the server through
read-only GETs, starts pinned KOReader without another mutating browser step,
and runs fixture parity last. This matters because reading-session journeys can
legitimately change progress; running them after the producer would make the
checkpoint stale. The producer must leave one progress CFI and one highlight
CFI for the synthetic EPUB and every one of the eight real EPUBs. The
controller rejects a missing alias, source hash, physical-drag marker, or real
CFI before starting KOReader.

At controller start, `source-provenance.json` records a canonical SHA-256
inventory of both production plugins and every browser, KOReader, parity and
lifecycle source used by the run. That exact fingerprint is propagated through
the browser checkpoints, each KOReader process result, the read-only verifier,
parity report and suite summary. The controller re-hashes the inventory after
all consumers finish and fails on a missing artifact fingerprint, a mixed
fingerprint, or any mid-run source change. This makes the suite's code freeze a
machine-checked property rather than a convention.

The KOReader runner gives every process a fresh `KO_HOME`, copies in the two
production plugins, and launches the official pinned desktop release. Its
test-only driver is not packaged. It opens, fills, and submits the real login
dialog; browses the real library; searches using the real dialog; opens detail
screens; downloads through the production callback; and opens those downloaded
bytes in ReaderUI. Each alias uses two separate processes. Fresh reader A
selects the real Jump Ahead action, adopts and deletes the browser highlight,
then derives a selection from two rendered document positions and crosses the
production Save highlight boundary (it does not synthesize a literal
long-press gesture). Fresh reader B navigates behind before its normal initial
pull, selects the real Sync Here action, adopts A's exact uploaded highlight,
and deletes it through KOReader's Delete highlight action. No test writes the
plugin's pull/decision gates or calls a private pull method to manufacture a
second conflict. A final read-only Grimmory API pass verifies the exact pushed
CFI, the deliberately absent href, and percentage after the same pinned
six-significant-digit MariaDB FLOAT/JDBC persistence used by the browser
checkpoint verifier (exact equality, never a tolerance), plus both deletions
and the expected sessions. Synthetic and first-real
session companions wait through real elapsed time and trigger the normal
ReaderUI Suspend lifecycle event; the production hooks do the finalization and
upload.

Desktop KOReader has no physical Wi-Fi adapter, so the driver reports Wi-Fi as
connected while retaining every real HTTP and authentication call. Enabling
annotations and sessions uses the same callback as the Settings checkboxes.
It never pre-seeds a token, download registry entry, progress, annotation, or
session in KOReader files.

Metadata is checked on dashboard, sidebar, all-books list, exact-title search,
and all nine detail pages. Scrollable details are captured at top, middle, and
bottom; the sparse synthetic detail must remain non-scrollable and emits only
its top capture. Native DTO values and real absence are compared exactly.
Every detail capture also proves that the model's menu, search, Wi-Fi, close,
Back, and action controls are wholly on-screen *and* that their borders/glyphs
exist in the saved framebuffer. The dashboard's synthetic author is checked
against both its production card layout and its actual saved pixels. Covers
fetched by the production plugin use the
cache's codec-stable visual fingerprint, because Grimmory legitimately
re-encodes JPEGs. Provider metadata and covers come from the immutable captured
cache. Recommendations are explicitly separate, server-derived catalog state
read from the local Grimmory recommendation endpoint after replay; they are not
claimed as independent provider truth. The HTML screenshots are private
visual-review artifacts, not strict full-screen pixel baselines; the targeted
paint checks reject incomplete frames without making async server pixels into
brittle golden images. Machine summaries use stable aliases only.

## Kept artifacts

After teardown, the run keeps:

- `runtime.json`, updated to `status: stopped`;
- `source-manifest.json` and `imported-books.json` for aliases and hashes;
- `artifacts/provenance.json` with both image digests and input fingerprints;
- `results/source-provenance.json` with the exact acceptance-code inventory and
  start/end equality check;
- `compose.yml`, the exact per-run Compose snapshot used for reliable later
  teardown;
- `artifacts/docker.log`, with credentials and bearer tokens redacted; and
- any reports written by the invoked test command.

The temporary `state/` directory and `input/books/` are deleted. If Docker
teardown itself fails, they are retained because deleting live bind mounts
would make diagnosis unsafe.

## Validation

```bash
python3 -m unittest tests.emulator.test_grimmory_real_stack -v
python3 -m unittest tests.emulator.test_grimmory_metadata_cache -v
python3 -m unittest tests.emulator.test_server_contract_parity -v
python3 -m unittest tests.emulator.test_koreader_acceptance_tools -v
docker compose -f tests/emulator/grimmory-real-server.compose.yml config --quiet
```

An actual lifecycle validation must additionally prove nine scanner imports,
inspect both healthy containers, run at least one authenticated journey, call
`down`, and verify that no container with that unique project remains.
