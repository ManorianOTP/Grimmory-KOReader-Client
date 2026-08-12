# Metadata realism contract

Metadata has two deliberately different test lanes. They must not be described
as interchangeable.

## Provider-real full-server lane

The acceptance harness imports one synthetic EPUB and the eight private EPUBs
through Grimmory's real scanner. A one-time browser journey opens each private
book's **Search Metadata** tab, searches using its real title and author,
selects the exact edition, copies the fetched fields into the current record,
and saves them using the visible Grimmory controls.

`scripts/grimmory-metadata-cache.py capture` then records the resulting server
metadata and cover below ignored `build/` storage. Capture requires evidence
from that browser selection for every private EPUB; persisted provider IDs are
not accepted as proof by default.

Ordinary test runs use `replay`. It writes the captured values with Grimmory's
supported metadata and cover endpoints, verifies the result, and emits
`runtime.with-metadata.json`. It does not edit MariaDB or EPUB files and does
not contact Amazon, Goodreads, Google Books, Hardcover, or any other provider.
The cache is matched to exact source EPUB digests, so a different or replaced
book cannot silently inherit an old record.

Grimmory decodes and re-encodes uploaded covers. The cache therefore retains a
byte SHA-256 as capture provenance, but replay verification uses decoded image
aspect ratio plus a 256-bit perceptual difference hash. This accepts harmless
JPEG rounding while rejecting a different cover.

The immutable cache and `expectedMetadata` include every provider-saved field
even when the real provider left it empty, plus the captured cover. They never
include recommendations, personal ratings, or match scores.
`expectedMetadata.presence` mirrors the provider-metadata shape with booleans,
so UI checks must verify absence instead of filling gaps with synthetic values.

The same runtime also carries `expectedKoreaderMetadata`, using the native DTO
names the production plugin receives (`categories`, `seriesName`,
`goodreadsRating`, `bookReviews`, and the other Grimmory fields). Its own
`presence` tree makes KOReader assertions check both rendered values and
deliberately omitted rows without duplicating a fragile browser-to-device field
translation in the test runner.

Recommendations are different from provider metadata: Grimmory derives them
from the other books currently present in that disposable library, and tied
scores may follow fresh database order. Replay therefore asks the local
Grimmory instance for its post-replay recommendation set and records that set
under each book's `serverDerivedAfterReplay.recommendations`, alongside an
explicit local-API source marker. Personal rating and metadata match score are
also recorded there because they come from Grimmory's live book-detail result,
not the immutable provider projection. The runtime records the exact local API
endpoint used for each field. The immutable cache does not contain these
server-derived values.
The UI must render those exact live results. This is still offline with respect
to metadata providers, but avoids treating a stale recommendation from an
older database as a fixed property of the EPUB.

The web acceptance journey checks every synthetic and private book on:

- the post-login Dashboard's enabled scrollers, exact rendered cards, covers,
  and honest empty states;
- the All Books grid card's rendered title and cover (plus author only on the
  no-cover placeholder, because covered Grimmory cards do not render author
  text) and every metadata field rendered in the table row;
- the distinct Series browser and Series detail/list renderers, including
  series identity, authors, publisher, language, every member and its cover;
- the distinct Author browser and Author detail renderer, including exact
  author identity, book count, every member and its cover;
- every aggregate value and affected-book count in all seven Metadata Manager
  tabs;
- the full book detail identity, author, series, genres and description;
- publisher, publication date, language and page count;
- provider identifiers, ratings and review counts;
- the rendered cover, its aspect ratio, and its decoded-pixel perceptual hash
  on Dashboard, grid, table, Series, Author, detail and recommendation cards;
- the reviews tab, including a genuinely empty result when no review bodies
  were returned;
- the Similar Books tab and each returned recommendation. Grimmory v3.3.1's
  compact recommendation card visibly exposes cover/title and sometimes a
  numeric series-position badge, but not author or series-name text; those
  fields remain asserted on its full book/Series/Author renderers.

The route inventory is deliberate. `/all-books`, `/library/:id/books`,
`/shelf/:id/books`, `/unshelved-books`, and `/magic-shelf/:id/books` all load
the exact same `BookBrowserComponent`; one exhaustive All Books run covers that
renderer without cloning identical tests for every filter context. Dashboard,
Series browser/detail, Author browser/detail, Metadata Manager, book detail and
the ebook-reader header are separate renderers and are each exercised. The
Notebook is annotation-derived rather than provider metadata; its book
identity/cover is exercised during the all-nine real note lifecycle. Stats
pages aggregate activity rather than rendering provider book metadata and are
covered by their own application/visual lanes.

The KOReader full-server journey consumes the same enriched runtime and real
server. It checks library cards/lists and full detail metadata after the cache
has been replayed into a fresh stack.

## Embedded-metadata visual companions

The fast KOReader screenshot companions extract OPF metadata and covers from
the user's EPUBs. They protect layout against messy real files on dashboard,
connection/sync rows, sidebar, lists, filtering, searching, details and
downloads. They do **not** prove provider fetching or full Grimmory persistence
and must be labelled `real-metadata-layout`, not provider-real acceptance.

## Synthetic stress cases

Provider-real data is allowed to be sparse. Synthetic fixtures retain the
otherwise hard-to-obtain layout cases: very long and missing values, no cover,
multiple authors, alternative formats, ratings from several providers,
reviews, spoiler reveal, recommendation overflow and null timestamps. A real
EPUB companion remains mandatory for every book-dependent journey, but a test
must never invent a real-book value merely to make the stress case richer.

## Commands

Normal runs never contact metadata providers. If the private cache genuinely
needs refreshing, first create an ignored plan at
`build/grimmory-compatibility/private/metadata-refresh-plan.json`:

```json
{
  "schemaVersion": 1,
  "books": [{
    "sourceSha256": "<exact EPUB SHA-256>",
    "query": {"title": "<private>", "author": "<private>", "isbn": "<optional>"},
    "provider": "<exact provider>",
    "providerItemId": "<exact edition/item ID>"
  }]
}
```

Validate coverage without opening a browser or making provider requests:

```bash
node tests/compatibility/run-metadata-refresh.js \
  --runtime build/grimmory-compatibility/<capture>/runtime.json \
  --plan build/grimmory-compatibility/private/metadata-refresh-plan.json \
  --validate-plan-only
```

The rare networked refresh must be opted into explicitly. It selects only the
planned provider in Grimmory, matches the result by provider URL item identity,
then uses the visible Copy All and Save Changes controls:

```bash
node tests/compatibility/run-metadata-refresh.js \
  --runtime build/grimmory-compatibility/<capture>/runtime.json \
  --plan build/grimmory-compatibility/private/metadata-refresh-plan.json \
  --evidence-output build/grimmory-compatibility/<capture>/metadata-selection-evidence.json \
  --allow-provider-network-refresh
```

The runner requires exactly one plan entry for every private source digest,
fails on a missing or ambiguous provider result, and prints only generated
`private-1`-style ordinal labels and counts. The plan, evidence, failure
screenshot and trace stay in
ignored storage. CI does not invoke this command.

Capture the values just saved through the browser:

```bash
python scripts/grimmory-metadata-cache.py capture \
  --runtime build/grimmory-compatibility/<capture>/runtime.json \
  --cache build/grimmory-compatibility/private-metadata-cache \
  --selection-evidence build/grimmory-compatibility/<capture>/metadata-selection-evidence.json
```

For normal isolated runs:

```bash
python scripts/grimmory-metadata-cache.py replay \
  --runtime build/grimmory-compatibility/<run>/runtime.json \
  --cache build/grimmory-compatibility/private-metadata-cache \
  --enriched-runtime build/grimmory-compatibility/<run>/runtime.with-metadata.json
```

The shareable coverage summary intentionally contains no title, author,
description, path, provider item ID, source digest, cover digest or review:

```bash
python scripts/grimmory-metadata-cache.py summary \
  --cache build/grimmory-compatibility/private-metadata-cache \
  --output build/grimmory-compatibility/metadata-cache-summary.json
```
