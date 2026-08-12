# Grimmory library fixture

The visual suite has two server lanes. They intentionally solve different
problems.

## Deterministic fixture server

This is the default for screenshot baselines and CI. It implements the exact
Grimmory v3 endpoints used by the plugins, starts in under a second, resets to
the same state every time, and allocates a free local port.

From WSL:

```bash
bash scripts/grimmory-visual-fixture.sh prepare /mnt/c/path/to/your/epubs
bash scripts/grimmory-visual-fixture.sh start
bash scripts/grimmory-visual-fixture.sh check
bash scripts/grimmory-visual-fixture.sh status
bash scripts/grimmory-visual-fixture.sh stop
```

`prepare` is optional. Without it, CI-safe synthetic EPUB and cover bytes are
served. With it, the server extracts covers into ignored `build/` storage and
streams downloads from the original EPUB paths. It does not add EPUBs, covers,
descriptions, or other copyrighted book content to Git.

The tracked fixture contains fictional titles, authors, series, shelves, and
filenames. Private EPUB slots are resolved at preparation time by matching the
exact source SHA-256 values in the ignored metadata cache. Before that cache
exists, pass an ignored `schemaVersion: 1` source map through
`GRIMMORY_PRIVATE_EPUB_MAP`; its `books[]` rows contain only a neutral fixture
`id` and a relative or absolute `path`. Neither route commits the user's
filenames or bibliographic metadata.

The selected URL is written atomically to
`build/grimmory-fixture/server-ready.json`. The visual runner applies the same
lifecycle inside each isolated run: it selects a free port, exports
`GRIMMORY_VISUAL_SERVER_URL`, and stops only its own server from a shell trap.
Ports are never hard-coded. This is what lets `reader_download_open` exercise
the real HTTP download path in CI and stream the exact private EPUB bytes in a
companion run.

Scenarios that inject DTOs without networking can generate matching
copyright-safe cover files with:

```bash
python3 tests/emulator/export_synthetic_covers.py
```

The resulting ignored `build/grimmory-fixture/synthetic-covers/covers.json`
maps book IDs to absolute PNG paths; book `1007` deliberately maps to `null`.
After real-book preparation, `build/grimmory-fixture/library.json` contains
each locally extracted original at `book.cover.path`. Preparation also writes
`build/grimmory-fixture/cover-map.json`, pointing at bounded local thumbnails
that behave like Grimmory's cover endpoint without exhausting KOReader's image
cache. To make a private, ignored gallery with the real covers while retaining
the suite's stressful deterministic records:

```bash
GRIMMORY_VISUAL_COVERS_JSON="$PWD/build/grimmory-fixture/cover-map.json" \
  bash scripts/run-koreader-visual-tests.sh --capture-only
```

For an auditable synthetic-versus-real run, use the companion runner:

```bash
bash scripts/run-real-epub-companions.sh \
  --source-dir /mnt/c/path/to/your/epubs \
  --output build/visual/real-epub-companions \
  --orientation both
```

It prepares actual OPF metadata and bounded covers in ignored `build/`, runs
the deterministic scenario, runs its mapped private companion, and writes a
side-by-side `report/index.html`. The tracked `real_epub_companions.json`
contains book IDs only. Absolute paths, asset digests, source filenames,
extracted descriptions, real bibliographic metadata, covers, and private
screenshots remain local and ignored. Approved CI screenshots use only the
fictional deterministic fixture.

Every scenario has one explicit realism class:

- `real-epub-behavior` opens and reads the exact validated bytes and asserts
  facts derived from the document;
- `real-metadata-layout` renders actual EPUB metadata and covers through the
  production UI without retaining synthetic title, author, or size assumptions;
- `fixture-independent-control` records why the behavior does not consume EPUB
  data, such as authentication or Wi-Fi routing.

The runner recomputes each EPUB's SHA-256, requires meaningful multi-document
and spine structure, and records the source book/file IDs, digest, fixture
mode, source fingerprint, and pinned KOReader version/commit. CI continues to
use only the copyright-safe synthetic baseline.

Credentials are `visual` / `grimmory-visual`. Stable IDs are:

- books `1001` through `1008`;
- primary files `5001` through `5008`;
- libraries `41` and `42`;
- shelves `71` through `75`.

The fixture includes multiple series and reading states, a long shelf name,
progress at zero/partial/complete, one missing cover, a synthetic alternative
PDF, recommendations, a review, and mutable progress/annotation/session
endpoints. `POST /__fixture/reset` restores all mutable state. `GET
/__fixture/state` exposes a small readiness/debug summary.

The implemented client contract covers health, version, login, refresh,
libraries, shelves, paginated books, book details, files, recommendations,
covers, downloads, progress, annotations, and reading sessions. The contract
was checked against Grimmory's official server source at develop commit
`e88de1a495be98ac70543c80d52b62fc3be70a6c` and the plugin's recorded v3.3.1
responses.

The local full-server lane additionally executes these mutable contracts
against both implementations and compares the results. Run it while a
disposable full-stack runtime is ready:

```bash
python3 tests/compatibility/server_contract_parity.py \
  --runtime build/grimmory-compatibility/my-run/runtime.json \
  --output build/grimmory-compatibility/my-run/parity/report.json
```

This comparison intentionally ignores data that should differ (generated IDs,
timestamps, titles, paths, and bytes). It requires recursive shape equality for
mutable/auth contracts and a canonical required-field projection for library,
shelf, book, detail, and file DTOs; production normalization of their optional
rich fields is separately covered by Lua and live KOReader metadata tests. It
runs the full-server side once for the synthetic control and once for each of
the eight private real EPUBs.

## Real Grimmory compatibility lane

This slower local lane uses the official `ghcr.io/grimmory-tools/grimmory:v3.3.1`
image with MariaDB 11.4.8. It is valuable for occasional API compatibility
checks, but it is not used to approve screenshots: database-generated IDs,
scanner timing, and metadata extraction make it less reproducible.

The commands below are retained as a small manual smoke-test shortcut. The
acceptance suite uses the safer isolated lifecycle documented in
[`GRIMMORY_REAL_SERVER_ACCEPTANCE.md`](GRIMMORY_REAL_SERVER_ACCEPTANCE.md): it
adds immutable image digests, random ports, unique Compose projects, fresh
databases, synthetic-plus-real pairing, sanitised artifacts, and automatic
teardown.

```bash
bash scripts/grimmory-visual-fixture.sh real-up /mnt/c/path/to/your/epubs
bash scripts/grimmory-visual-fixture.sh real-status
bash scripts/grimmory-visual-fixture.sh real-down
```

`real-up` stages exactly the eight named books under ignored
`build/grimmory-real/books` (hard links where the filesystem supports them),
starts the pinned containers, creates the local fixture account and library,
and waits until all eight imports appear. `real-down` stops the services but
keeps their ignored local database. It never touches a user's existing
Grimmory installation.

## Automated checks

```bash
python3 -m unittest tests.emulator.test_grimmory_fixture_server -v
python3 -m unittest tests.emulator.test_server_contract_parity -v
python3 -m unittest tests.emulator.test_real_epub_companions -v
docker compose -f tests/emulator/grimmory-real-server.compose.yml config --quiet
```

The unit test exercises authentication, stable identities, rich DTOs, the
missing-cover and alternative-format cases, plus progress, annotation, and
session round trips.
