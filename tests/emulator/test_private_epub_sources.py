"""Privacy and identity tests for neutral private-EPUB source slots."""

from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "private_epub_sources.py"
SPEC = importlib.util.spec_from_file_location("private_epub_sources_test", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
sources = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sources)


def books() -> list[dict]:
    return [{"id": book_id} for book_id in range(1001, 1009)]


class PrivateEpubSourceTests(unittest.TestCase):
    def test_explicit_ignored_map_resolves_neutral_slots(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            rows = []
            for book_id in range(1001, 1009):
                name = f"private-{book_id}.epub"
                (root / name).write_bytes(str(book_id).encode("ascii"))
                rows.append({"id": book_id, "path": name})
            mapping = root / "map.json"
            mapping.write_text(
                json.dumps({"schemaVersion": 1, "books": rows}),
                encoding="utf-8",
            )

            result = sources.resolve_private_epubs(
                books(), root, source_map=mapping,
            )

            self.assertEqual(set(result), set(range(1001, 1009)))
            self.assertTrue(all(path.is_file() for path in result.values()))

    def test_metadata_cache_matches_by_bytes_not_filename(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cache = root / "cache"
            cache.mkdir()
            entries = []
            expected = {}
            for book_id in range(1001, 1009):
                payload = f"private bytes {book_id}".encode("ascii")
                path = root / f"arbitrary-name-{1009 - book_id}.epub"
                path.write_bytes(payload)
                digest = hashlib.sha256(payload).hexdigest()
                expected[book_id] = path.resolve()
                entries.append({
                    "alias": f"real-{book_id}",
                    "sourceSha256": digest,
                })
            manifest = {"schemaVersion": 1, "books": entries}
            manifest["manifestSha256"] = hashlib.sha256(
                sources._canonical_json(manifest)
            ).hexdigest()
            (cache / "manifest.json").write_text(
                json.dumps(manifest), encoding="utf-8",
            )

            result = sources.resolve_private_epubs(
                books(), root, metadata_cache=cache,
            )

            self.assertEqual(result, expected)

    def test_refuses_unverified_filename_discovery(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for book_id in range(1001, 1009):
                (root / f"book-{book_id}.epub").write_bytes(b"placeholder")
            with self.assertRaisesRegex(
                sources.SourceResolutionError, "filenames are intentionally not tracked",
            ):
                sources.resolve_private_epubs(books(), root)


if __name__ == "__main__":
    unittest.main()
