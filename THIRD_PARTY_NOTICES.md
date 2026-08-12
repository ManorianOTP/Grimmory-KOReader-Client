# Third-party notices

## Distributed code

`grimmory_sync.koplugin/slaxml.lua` combines upstream `slaxml.lua` with the
`dom()` builder from upstream `slaxdom.lua` at
[SLAXML v0.8](https://github.com/Phrogz/SLAXML/tree/8a3e0c90325aa6d84ad23a7c13bf77247cb7f94e),
commit `8a3e0c90325aa6d84ad23a7c13bf77247cb7f94e`, by Gavin Kistner. The serializer
portion is not included. SLAXML is distributed under the MIT License, and its
upstream copyright and license notice are retained in the file.

## Artwork, names, and visual marks

All SVG artwork distributed in `grimmory.koplugin/icons/` is original generic
artwork created for this repository: a library/book symbol, three neutral
rating-source symbols, and Wi-Fi state symbols. It may be redistributed under
this repository's MIT License. Earlier Amazon, Goodreads, Hardcover, and
Grimmory logo files had no documented redistribution permission and have been
removed; no third-party brand artwork is included in release archives.

The Grimmory, Amazon, Goodreads, and Hardcover names remain in interface labels
solely to identify the services and metadata fields with which the client
integrates. Those names and any associated trademarks belong to their
respective owners; this project is not endorsed by them.

All text in `tests/fixtures/synthetic/`, including the Unicode offset phrases,
was written specifically for this test suite and contains no third-party book
extracts.

## Development and runtime integrations

KOReader, Grimmory, Foliate/epub.js, Playwright, MariaDB, Tailscale, LuaRocks
packages, Pillow, and Docker images are used as runtimes, development tools, or
external services. They are not copied into this repository's plugin release
archives, except for the SLAXML file identified above. Their own licenses and
terms continue to apply.
