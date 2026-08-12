# Synthetic EPUB Fixtures

Each subdirectory contains a minimal EPUB targeting one documented CFI
pitfall. These are the regression gate for cfi.lua. (ref: DL-003)

## Fixture index

| Directory | Pitfall |
|-----------|---------|
| `minimal/` | Happy-path round-trip baseline |
| `whitespace/` | Indentation-only DOM text must not shift child indices while meaningful inline boundary spaces remain intact |
| `body_index/` | Body CFI step is computed by walking `<html>` children; body is not always index 2 |
| `text_node/` | Reverse sync (CFI -> XPointer) must emit `/text()[1]` before the char offset |
| `utf16_surrogate/` | CREngine XPointer offsets count `lChar32` Unicode scalars; an astral scalar maps to 2 epub.js UTF-16 units |
| `unicode_offsets/` | Literal Kindle smart-punctuation failures plus emoji, decomposed combining marks, and flattened inline Unicode offsets |
| `mixed_siblings/` | Mixed text+element siblings: only element siblings count toward CFI step index |
| `self_closing_anchor/` | Empty page-landmark anchors remain element siblings during CFI/XPointer translation |
| `multi_docfragment/` | Multi-chapter EPUB where spine index > 1 requires correct SYNTHETIC element count |

## Adding a fixture

1. Create `tests/fixtures/synthetic/<name>/META-INF/container.xml`
2. Create `tests/fixtures/synthetic/<name>/OEBPS/content.opf` with a `<spine>`
3. Create one or more XHTML chapter files under `OEBPS/`
4. Add a `describe` block in `tests/cfi_spec.lua`

No zip step required: `tests/support/epub_reader.lua` reads the directory tree
directly, bypassing the minizip FFI. (ref: DL-002)

All prose in these fixtures was written specifically for this test suite. The
short phrases under `unicode_offsets/` deliberately contain smart quotes, a
curly apostrophe, emoji and a decomposed combining mark while retaining the
offset lengths required by the regression cases.
