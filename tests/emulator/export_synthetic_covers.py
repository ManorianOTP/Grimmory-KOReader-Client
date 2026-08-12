#!/usr/bin/env python3
"""Export copyright-safe deterministic images and EPUB for emulator scenarios."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import grimmory_fixture_server


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", type=Path, default=HERE / "grimmory_library_fixture.json")
    parser.add_argument("--output", type=Path, default=ROOT / "build" / "grimmory-fixture" / "synthetic-covers")
    args = parser.parse_args()
    fixture = json.loads(args.fixture.read_text(encoding="utf-8"))
    args.output.mkdir(parents=True, exist_ok=True)
    exported = {}
    for book in fixture["books"]:
        if book.get("coverAvailable") is False:
            exported[str(book["id"])] = None
            continue
        path = (args.output / f"{book['id']}.png").resolve()
        path.write_bytes(grimmory_fixture_server.synthetic_cover(int(book["id"])))
        exported[str(book["id"])] = str(path)
    index = args.output / "covers.json"
    index.write_text(json.dumps(exported, indent=2) + "\n", encoding="utf-8")
    reader_epub = args.output / "synthetic-reader.epub"
    reader_epub.write_bytes(grimmory_fixture_server.synthetic_epub(fixture["books"][0]))
    print(index.resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
