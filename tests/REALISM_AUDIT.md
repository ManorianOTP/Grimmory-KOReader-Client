# Test Realism Audit

Status: complete (reviewed 2026-08-13)

This audit answers one narrow question for every test: does the test exercise
the behavior its name appears to claim, and, where a synthetic EPUB or injected
book state is useful for diagnosis, is there a real-EPUB companion guarding the
same production boundary?

The machine-readable source of truth is [`realism_policy.json`](realism_policy.json).
[`check-test-realism.py`](../scripts/check-test-realism.py) discovers every
top-level Lua `it(...)` case and every visual scenario. It fails if a case is
unmapped, multiply mapped, renamed, silently added to a broad file rule, or if
the visual catalogue, book map, and class partition differ. Private paths,
titles, covers, hashes, and EPUB bytes remain in ignored build output.
The deterministic fixture and approved references use fictional metadata;
only neutral numeric slots are shared with private companion runs.

## Allowed dispositions

- `real-epub-behavior`: the companion opens or downloads the selected EPUB and
  asserts facts derived from the actual document.
- `real-metadata-layout`: the companion renders the exact provider-persisted
  metadata and cover captured through Grimmory's visible web selection for the
  selected EPUB's SHA-256. This is sufficient for list/search/detail layout,
  but not for reader, download, CFI, annotation, or session behavior.
- `fixture-independent-control`: the route is provably book-independent and has
  a tracked rationale.
- `synthetic-pathology-with-real-companion`: a minimal fixture isolates a hard
  edge case and a real ReaderUI journey covers ordinary messy EPUB structure.
- `pure-logic-not-epub-dependent`: the isolated algorithm or persistence rule
  does not inspect EPUB structure and has a tracked rationale.
- `real-server-contract` and `non-epub-format-contract`: explicit, narrow
  exemptions for the pinned server lane and PDF/CBX behavior respectively.

## Lua and integration audit

| Area and exact test boundary | Synthetic shortcut found | Disposition |
|---|---|---|
| `tests/cfi_spec.lua`; `cfi.initBook`, `xpointerToCFI`, `cfiToXPointer`, range conversion | Unpacked minimal directory trees and an injected archiver replace real ZIP/CREngine behavior. The former recorded lane was a pending placeholder. | **Fixed and paired.** Minimal fixtures remain for whitespace, body-index, UTF-16, nested-inline, empty-element, self-closing-anchor, and multi-spine pathologies. `reader_sync_conflict` now generates and consumes genuine KOReader positions on all eight private EPUBs. The recorded lane now discovers `samples.json` files and checks every exact XPointer/CFI pair in both directions instead of pending. |
| `tests/sync_spec.lua`; `onReaderReady`, `onPageUpdate`, pull/push gates, conflict callbacks | Fake ReaderUI, virtual time, deterministic API results, and selected-file tables isolate races and decisions. | **Paired.** The production `reader_sync_conflict` journey opens each real EPUB, derives two document positions, exercises Jump Ahead and Sync Here, then proves a repeat pull is clean and pending state is cleared. PDF/CBX parameterized cases are explicitly `non-epub-format-contract`. |
| `tests/annotations_spec.lua`; annotation conversion and three-way plan | Annotation tables and callback boundaries are injected; no ReaderUI highlight exists in the unit test. | **Paired.** The real reader journey creates a highlight from live rendered text through KOReader's actual Save Highlight action, uploads through production hooks, and proves a fresh isolated reader adopts the exact server ID/CFI/text. It then leaves the device annotation for Grimmory's visible Highlights UI: a row click navigates with the device-origin CFI, pinned Foliate independently resolves a non-collapsed DOM Range, and its complete `Range.toString()` must equal both complete KOReader and server text byte-for-byte before visible web deletion. The synthetic EPUB and all eight private EPUBs are mandatory; selected text must exercise smart quotes/apostrophes, and `real-1002` is a required non-ASCII regression. The unit cases remain pure planning tests. |
| `tests/sessions_state_spec.lua`; session validation, threshold, retry and queue ownership | Clock, positions, and durable state are injected. | **Paired.** The real reader journey starts a production session with a document-derived CFI, moves to a second rendered position, crosses the duration threshold, drains it, checks exact positions/identity/duration, and clears pending state. |
| `tests/downloads_spec.lua`; filename sanitization and registry persistence | Payload bytes are the literal string `epub-bytes`; the tests prove ownership and durability, not readability. | **Fixed and paired.** The units remain narrow registry/safety tests. `reader_download_open` downloads each of the eight real EPUBs through the production Session/API task and local HTTP boundary, requires the final file with no `.part`, matches source and downloaded SHA-256, checks exact server/file/type/path registry identity, and opens the published destination through the application's production ReaderUI delegate. The attached sync plugin must then resolve that new registry entry to the exact book/file/path. |
| `tests/shelf_collections_spec.lua`; `reconcile`, injected `ReadCollection` and `realpath` | The safety algorithm uses an in-memory collection adapter and injected path canonicalizer so it cannot mutate a developer's KOReader data. | **Fixed and paired.** The unit remains the exhaustive safety algorithm test. In `reader_download_open`, production `registerDownload` feeds the actual downloaded path through `ffi/util.realpath` and KOReader `ReadCollection` inside a fresh isolated KO_HOME. The journey reloads persisted collection state, repeats reconciliation with zero changes, and proves both the managed real-EPUB path and an unrelated manual member survive. |
| `tests/api_spec.lua`; socket HTTP framing and DTO/error parsing | Local canned JSON and byte streams replace the live Grimmory service. | **Justified isolation plus server lane.** Real `socket.http`, headers, length, sinks, and parsing run locally. The pinned Grimmory compatibility fixture validates live endpoint shape separately. Canned bytes do not count as a readable EPUB. |
| `tests/async_spec.lua`; FIFO, cancellation, result delivery and sanitization | Tasks, failures, and JSON values are scripted. | **Justified exemption:** pure executor behavior; EPUB contents cannot enter the path. |
| `tests/connection_sync_ui_spec.lua`; gettext shadowing guard | Source text is scanned instead of opening UI. | **Justified exemption:** a source-safety regression independent of books. |
| `tests/library_cache_spec.lua`; account snapshots and migration | Cached DTOs and settings are synthetic. | **Justified exemption:** persistence ownership and migration are EPUB-independent; real metadata layout is paired visually. |
| `tests/session_spec.lua`; auth token lifecycle | API calls, accounts, tokens, and time are scripted. | **Justified exemption:** authentication dispatch and token rotation do not inspect a document. |
| `tests/sync_status_spec.lua`; badge aggregation/geometry model | Queue states and counts are injected. | **Justified exemption:** presentation-model behavior is independent of EPUB bytes. |
| `tests/tailscale_spec.lua`; install and daemon orchestration | Daemon commands are scripted because `tailscaled` cannot run in the harness. | **Justified mixed isolation:** archive download/extract/copy/chmod runs against a real temporary filesystem; daemon state is a platform/network concern, not an EPUB concern. |
| `tests/updater_spec.lua`; archive validation, swap, rollback and uninstall | Release responses and failure points are controlled. | **Justified isolation:** real temporary files and shell boundaries exercise the pipeline; EPUB data is irrelevant. |
| `tests/view_spec.lua`; sort, filter, facets, buckets and registry helpers | Normalized DTO rows are constructed in memory. | **Paired at the appropriate boundary.** Algorithms stay pure; list, filter, search, detail, long-text, and cover layout consume exact Grimmory provider metadata and cover bytes bound to each real EPUB's SHA-256 in the private companion lane. |
| `tests/visual/test_visual_regression.py`; image comparison/report tooling | Tiny generated RGBA images replace screenshots. | **Justified exemption:** these cases test pixel comparison, thresholds, missing-reference handling, provenance, and report generation rather than application or EPUB behavior. Real KOReader captures are the tool's inputs in the visual jobs. |
| `tests/visual/test_realism_policy.py`; policy failure modes | Temporary mutated JSON policies and synthetic Lua snippets are used. | **Justified exemption:** these are meta-tests proving the audit gate rejects growth, renames, zero/overlapping rules, incomplete visual maps, and commented-out Lua calls. |

Every Lua rule above is pinned by both a case count and a SHA-256 digest of its
exact stable `file :: first-it-argument` inventory. A new or renamed case
therefore fails before it can inherit a broad exemption.

## Visual scenario audit

The visual catalogue contains 47 scenarios and partitions as follows. The exact scenario-to-book
matrix (book IDs 1001-1008) is tracked in
[`real_epub_companions.json`](emulator/real_epub_companions.json).

### Real document behavior

- `reader_download_open`: downloads, hashes, registers, shelf-reconciles, opens,
  renders, and navigates each of the eight real EPUBs. Its completed private
  report records 8/8 passing companions with no failed assertions.
- `reader_epub_open`: opens, renders, and navigates all eight EPUBs; requires
  multiple rendered pages, so a one-page synthetic file cannot satisfy it.
- `reader_sync_conflict`: full real ReaderUI progress round trip plus the
  annotation and reading-session journeys described above, on all eight EPUBs.

### Real provider-metadata and cover layout

`connection_pending`, `connection_pending_detail`, `connection_long_title`,
`connection_error`, `dashboard_real_library`,
`dashboard_real_library_offline`, `sidebar_populated`, `book_list_populated`,
`book_list_filtered_empty`, `view_options`, `sort_menu_active`,
`filter_menu_active`, `filter_values_selected_long`, `search_dialog_keyboard`,
`search_results_long_query`, `book_detail_rich_top`,
`book_detail_rich_middle`, `book_detail_rich_bottom`,
`book_detail_spoiler_revealed`, `book_detail_offline`,
`book_detail_downloaded`, `download_format_mixed`, and `download_progress_50`.

These scenes load every provider-persisted native metadata field and the exact
provider cover bytes from the ignored cache. The cache manifest, native metadata
projection, cover bytes/visual fingerprint, visible-selection evidence, and
source EPUB identity are verified before capture; absent provider fields remain
absent. Fictional libraries, shelves, progress, read status, and personal rating
remain a separately labelled local-catalogue stress overlay and are never
claimed as provider results. These are legitimate layout companions, not claims
of end-to-end download behavior. In particular, the 50% progress scene
deliberately creates a bounded `.part` state; the open download gap above must
be closed by a separate real behavior journey.

### Fixture-independent controls

`wifi_badge_absent`, `wifi_badge_1`, `wifi_badge_9_plus`, `connection_empty`,
`connection_offline`, `login_dialog`, `account_switcher_mixed`,
`download_folder_dialog`, `main_menu_signed_in`, `settings_menu`,
`tailscale_menu`, `sign_out_confirm`, `uninstall_choices`, `update_available`,
`tailscale_install_prompt`, `tailscale_status_connected`,
`tailscale_auth_instructions`, `tailscale_auth_qr`,
`sync_main_menu_pending`, `offline_wifi_prompt`, and `long_error_message`.

Each control has an individual rationale in the companion map. Adding a control
without a rationale, or putting any scenario in zero or two classes, fails CI.

## Real-book selection and nuisance coverage

The ignored manifest exposes only stable IDs to tracked files. The eight-book
matrix intentionally distributes work rather than using a single convenient
novel:

- 1001: smallest baseline and fast session/open checks.
- 1002: image/font-heavy metadata, large download/hash pressure, and the known
  non-ASCII KOReader-to-Foliate exact-range regression input.
- 1003: EPUB 3 navigation and alternate format presentation.
- 1004: hundreds of self-closing anchors; annotation and collection stress.
- 1005: whitespace/mixed-content and progress behavior.
- 1006: EPUB 3 navigation plus progress/session/collection coverage.
- 1007: compact multi-document EPUB and small-file behavior; its real companion
  honors the provider's actual cover-presence contract rather than borrowing
  the synthetic missing-cover case.
- 1008: largest book, many spine documents and anchors; multi-document CFI,
  long-list/search, session, and large-file download pressure.

No licensed bytes, private title, path, cover, or SHA is committed. The private
runner verifies each selected asset's SHA and structural profile before KOReader
starts and records the KOReader version/commit in results.

## Completion evidence

The deterministic public gate was rerun on 2026-08-13: 339 Lua examples passed
with 0 failures/errors/pending; 331 top-level Lua cases, 47 visual scenarios,
34 JavaScript tests, and 120 Python tests were mapped exactly once; all 30
visual Python tests, 90 emulator/tooling Python tests, and 22 public Node.js
oracle tests passed. Every Lua file compiled and the packaged-source branding
check passed. The 12 remaining JavaScript cases are the private full-server
Playwright journeys; they are inventoried by the policy but are not counted as
executed by the public Node unit-test command.

The private release-audit evidence was refreshed on 2026-08-13. The ignored
paired report used schema v2 and passed all 136
real-EPUB captures (68 mapped scenario/book pairs in both orientations), while
its deterministic control matched all 94 approved references. The full-server
lane also passed 10 browser journeys, the isolated producer and consumer,
9/9 exact progress/annotation checkpoints, all 19 KOReader journeys, unchanged
source provenance, and 14 workflows across all 9 server books. Private source
files and generated evidence remain ignored and are not part of this audit
commit.

- `reader_download_open` private companion report: 8 pairs passed, 0 failed;
  every real result used `real-epub-behavior`, `direct-private-epub`, the mapped
  book/file IDs, the validated asset SHA, and pinned KOReader provenance.
- Historical pre-hardening local CI: 286 Lua successes, 0
  failures/errors/pending; 282 statically discovered Lua cases and 47 visual
  scenarios mapped exactly once; 22 visual Python tests and 56
  emulator/tooling Python tests passed; every Lua file compiled and the
  branding gate passed.
- Privacy-safe reference refresh: all 94 current captures passed. Sixty-six
  references remained pixel-identical; the 28 intentional changes were exactly
  the 14 fictional book/content scenarios in portrait and landscape. Each was
  reviewed at original resolution before targeted approval, then a fresh strict
  run matched all 94 approved references.
- Artwork-provenance refresh: all 94 public scenarios executed successfully;
  the six portrait/landscape detail references affected by the three generic
  rating glyphs were inspected at original resolution and approved explicitly,
  after which all 94 captures matched pixel-for-pixel.
- Provider-overlay companion run: 94 synthetic captures matched the approved
  references exactly and 136 real-EPUB captures passed (68 mapped
  scenario/book pairs in both orientations), for 230/230 total. Every real
  result records the exact EPUB/cache identity, cache-manifest and native
  metadata-projection hashes, visible Grimmory selection method, offline replay,
  and non-provider catalogue boundary. Eighteen intentionally changed real
  images were reviewed at original resolution; a separate repeated-run compare
  matched all 136 real images pixel-for-pixel. Final visual source fingerprint:
  `sha256:e7538ae10c5cc4e83f3a06e8bc9b979f578c1a508e8eb1f7d0925a7a0cdf55cd`.
- The checker regression tests deliberately exercise silent case growth, name
  changes, missing rules, overlapping rules, incomplete visual maps, and Lua
  comment masking.

## Remaining limitations

1. Private EPUB behavior cannot run in public CI without the ignored assets.
   Public CI enforces exact coverage declarations; the private runner produces
   the real evidence.
2. The real download journey executes the production Session/API task and its
   completion callback inline for deterministic emulator timing. It covers real
   HTTP bytes, `.part` publication, hash, registry, collection, and ReaderUI
   behavior, but not child-process scheduling latency or kill timing; the
   deterministic progress/cancel scene covers that control path separately.
3. Desktop KOReader cannot prove Kindle-only touch, suspend/wake, or e-ink refresh
   behavior. Those remain physical-device release checks and are not disguised
   as emulator coverage.
4. The full-server outcome manifest pins every Playwright journey, its reviewed
   comment-insensitive executable-body digest, and its required semantic outcome
   names. Successful journeys emit the exact named boolean set at runtime; the
   controller rejects missing, false, duplicate, stale, or invented outcomes
   before continuing. Journey-specific verifiers still provide the independent
   value-level oracle behind those completion records.
