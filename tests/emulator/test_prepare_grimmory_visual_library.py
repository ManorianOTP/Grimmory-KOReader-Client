from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from typing import Callable


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "prepare_grimmory_visual_library",
    ROOT / "scripts" / "prepare-grimmory-visual-library.py",
)
prepare = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(prepare)


def expected_metadata(*, cover: bool = True) -> dict:
    return {
        "title": "Provider title",
        "subtitle": None,
        "authors": ["Provider Author"],
        "series": {"name": None, "number": None, "total": None},
        "publisher": "Provider Press",
        "publishedDate": "2020-02-03",
        "pageCount": 321,
        "language": "English",
        "genres": ["Provider genre"],
        "tags": [],
        "moods": [],
        "description": None,
        "identifiers": {
            "isbn10": None,
            "isbn13": "9780000000002",
            "Amazon": None,
            "GoodReads": "provider-item-7",
        },
        "ratings": {
            "amazon": None,
            "amazonReviewCount": None,
            "goodreads": 4.25,
            "goodreadsReviewCount": 17,
            "hardcover": None,
            "hardcoverReviewCount": None,
        },
        "reviews": [],
        "coverPresent": cover,
        "coverSourceSha256": "c" * 64 if cover else None,
        "coverVisualFingerprint": "visual-proof" if cover else None,
        "providerSelection": {
            "provider": "GoodReads",
            "providerItemId": "provider-item-7",
        },
    }


def provider_entry(source_sha: str, cover_path: Path | None = None) -> dict:
    expected = expected_metadata(cover=cover_path is not None)
    native_metadata = {
        "title": expected["title"],
        "subtitle": expected["subtitle"],
        "authors": copy.deepcopy(expected["authors"]),
        "seriesName": expected["series"]["name"],
        "seriesNumber": expected["series"]["number"],
        "seriesTotal": expected["series"]["total"],
        "publisher": expected["publisher"],
        "publishedDate": expected["publishedDate"],
        "pageCount": expected["pageCount"],
        "language": expected["language"],
        "categories": copy.deepcopy(expected["genres"]),
        "tags": copy.deepcopy(expected["tags"]),
        "moods": copy.deepcopy(expected["moods"]),
        "description": expected["description"],
        "isbn10": expected["identifiers"]["isbn10"],
        "isbn13": expected["identifiers"]["isbn13"],
        "asin": expected["identifiers"]["Amazon"],
        "goodreadsId": expected["identifiers"]["GoodReads"],
        "amazonRating": expected["ratings"]["amazon"],
        "amazonReviewCount": expected["ratings"]["amazonReviewCount"],
        "goodreadsRating": expected["ratings"]["goodreads"],
        "goodreadsReviewCount": expected["ratings"]["goodreadsReviewCount"],
        "hardcoverRating": expected["ratings"]["hardcover"],
        "hardcoverReviewCount": expected["ratings"]["hardcoverReviewCount"],
        "bookReviews": copy.deepcopy(expected["reviews"]),
        "narrator": None,
        "ageRating": None,
    }
    cover = None
    if cover_path is not None:
        cover_bytes = cover_path.read_bytes()
        digest = hashlib.sha256(cover_bytes).hexdigest()
        expected["coverSourceSha256"] = digest
        cover = {
            "file": cover_path.name,
            "path": str(cover_path),
            "contentType": "image/jpeg",
            "sha256": digest,
            "bytes": len(cover_bytes),
            "visualFingerprint": "visual-proof",
        }
    return {
        "kind": "private-real-epub",
        "cacheKey": source_sha,
        "sourceSha256": source_sha,
        "metadataProjectionSha256": prepare.sha256_bytes(
            prepare.canonical_json(native_metadata)
        ),
        "captureEvidence": {
            "captureMethod": "grimmory-web-metadata-selection",
            "provider": "GoodReads",
            "providerItemId": "provider-item-7",
        },
        "expectedMetadata": expected,
        "metadata": native_metadata,
        "cover": cover,
    }


class PrepareGrimmoryVisualLibraryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source_sha = "a" * 64
        self.visual_cover = self.root / "provider.jpg"
        self.visual_cover.write_bytes(b"exact provider cover")
        self.fixture = {
            "library": {"id": 1, "name": "Local stress library"},
            "libraries": [{"id": 1, "name": "Local stress library"}],
            "shelves": [{
                "id": 3,
                "name": "Local stress shelf",
                "bookIds": [1001],
            }],
            "books": [{
                "id": 1001,
                "title": "Fictional fixture title",
                "authors": ["Fictional Fixture Author"],
                "seriesName": "Fictional Fixture Series",
                "seriesNumber": 9,
                "seriesTotal": 12,
                "publisher": "Fixture Publisher",
                "publishedDate": "2099-01-01",
                "pageCount": 999,
                "categories": ["Fixture category"],
                "tags": ["fixture-tag"],
                "fileId": 5001,
                "fileName": "fictional-fixture.epub",
                "personalRating": 5,
                "sourcePath": str(self.root / "private.epub"),
                "sourceSha256": self.source_sha,
                "sourceBytes": 123456,
                "sourceFileName": "private.epub",
                "visualCoverPath": str(self.visual_cover),
                "epubProfile": {
                    "contentDocuments": 3,
                    "spineItems": 3,
                    "contentBytes": 15000,
                },
            }],
        }
        self.provider = provider_entry(self.source_sha, self.visual_cover)
        self.cache_provenance = {
            "manifestSha256": "e" * 64,
            "providerNetworkUsed": False,
            "identityRule": "exact private EPUB SHA-256",
        }

    def tearDown(self):
        self.temp.cleanup()

    def test_every_provider_field_replaces_tracked_fixture_metadata(self):
        library = prepare.visual_library(
            self.fixture,
            {self.source_sha: self.provider},
            self.cache_provenance,
        )
        book = library["books"][0]
        metadata = book["metadata"]
        expected = self.provider["expectedMetadata"]

        self.assertEqual(expected["title"], book["title"])
        self.assertEqual(expected["title"], metadata["title"])
        self.assertEqual(expected["authors"], metadata["authors"])
        self.assertEqual(expected["series"]["name"], metadata["seriesName"])
        self.assertEqual(expected["genres"], metadata["categories"])
        self.assertEqual(expected["tags"], metadata["tags"])
        self.assertIsNone(metadata["description"])
        self.assertEqual([], metadata["bookReviews"])
        self.assertIsNone(metadata["hardcoverRating"])
        self.assertEqual(4.25, metadata["goodreadsRating"])
        self.assertEqual(expected["ratings"]["goodreads"], book["goodreadsRating"])
        self.assertEqual(expected["reviews"], book["bookReviews"])
        self.assertEqual(self.provider["cover"]["sha256"], book["cover"]["sha256"])

        serialized_provider_fields = json.dumps({
            "title": book["title"],
            "metadata": metadata,
            "ratings": {
                "goodreads": book["goodreadsRating"],
                "hardcover": book["hardcoverRating"],
            },
            "reviews": book["bookReviews"],
        })
        for fictional in (
            "Fictional fixture title",
            "Fictional Fixture Author",
            "Fictional Fixture Series",
            "Fixture category",
            "fixture-tag",
            "Deterministic visual-test summary",
            "Visual Fixture Reader",
        ):
            self.assertNotIn(fictional, serialized_provider_fields)

        self.assertEqual("Local stress shelf", book["shelves"][0]["name"])
        self.assertEqual(5, book["personalRating"])
        self.assertFalse(
            book["metadataProvenance"]["catalogStressOverlay"]["providerMetadata"]
        )
        self.assertEqual(
            self.source_sha,
            book["metadataProvenance"]["provider"]["cacheKey"],
        )
        self.assertEqual(
            self.provider["cover"]["sha256"],
            book["metadataProvenance"]["provider"]["coverSourceSha256"],
        )
        verification = prepare.verify_provider_overlay(
            library, {self.source_sha: self.provider}, self.cache_provenance,
        )
        self.assertEqual("passed", verification["status"])
        self.assertTrue(verification["checks"][0]["nativeMetadataExact"])

    def test_exact_source_sha_is_mandatory(self):
        wrong = copy.deepcopy(self.fixture)
        wrong["books"][0]["sourceSha256"] = "b" * 64
        with self.assertRaisesRegex(ValueError, "no exact-SHA provider metadata"):
            prepare.visual_library(
                wrong, {self.source_sha: self.provider}, self.cache_provenance,
            )

    def write_cache(self, *, mutate: Callable[[dict], None] | None = None) -> Path:
        cache = self.root / "cache"
        cache.mkdir()
        cover = cache / "provider.jpg"
        cover.write_bytes(b"exact provider cover")
        item = provider_entry(self.source_sha, cover)
        item["cover"].pop("path")
        manifest = {"schemaVersion": 1, "books": [item]}
        if mutate:
            mutate(manifest)
        manifest["manifestSha256"] = prepare.sha256_bytes(
            prepare.canonical_json(manifest)
        )
        (cache / "manifest.json").write_text(
            json.dumps(manifest), encoding="utf-8",
        )
        return cache

    def test_cache_loader_validates_manifest_identity_and_cover_bytes(self):
        cache = self.write_cache()
        entries, provenance = prepare.load_provider_cache(cache)
        self.assertEqual({self.source_sha}, set(entries))
        self.assertEqual(self.source_sha, entries[self.source_sha]["cacheKey"])
        self.assertRegex(provenance["manifestSha256"], r"^[0-9a-f]{64}$")
        self.assertFalse(provenance["providerNetworkUsed"])

        manifest = json.loads((cache / "manifest.json").read_text(encoding="utf-8"))
        manifest["books"][0]["cacheKey"] = "b" * 64
        manifest["manifestSha256"] = prepare.sha256_bytes(
            prepare.canonical_json({k: v for k, v in manifest.items() if k != "manifestSha256"})
        )
        (cache / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "exact source SHA identity"):
            prepare.load_provider_cache(cache)

    def test_cache_loader_rejects_cover_drift(self):
        cache = self.write_cache()
        (cache / "provider.jpg").write_bytes(b"changed provider cover")
        with self.assertRaisesRegex(ValueError, "cover byte count differs"):
            prepare.load_provider_cache(cache)


if __name__ == "__main__":
    unittest.main()
