from __future__ import annotations

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import threading
import unittest

from PIL import Image


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "grimmory-metadata-cache.py"
SPEC = importlib.util.spec_from_file_location("grimmory_metadata_cache", SCRIPT)
assert SPEC and SPEC.loader
cache_tool = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cache_tool)


RICH_METADATA = {
    "bookId": 901,
    "title": "A Real Title",
    "subtitle": None,
    "authors": ["An Author", "A Second Author"],
    "seriesName": "A Series",
    "seriesNumber": 2.5,
    "seriesTotal": 5,
    "publisher": "A Publisher",
    "publishedDate": "2021-03-02",
    "language": "en",
    "description": "<p>A real provider description.</p>",
    "categories": ["Fantasy", "Adventure"],
    "moods": ["Adventurous"],
    "tags": [],
    "pageCount": 381,
    "isbn13": "9781234567890",
    "googleId": "provider-item-123",
    "goodreadsRating": 4.25,
    "goodreadsReviewCount": 1200,
    "bookReviews": [{
        "id": 77,
        "metadataProvider": "GoodReads",
        "reviewerName": "A Reviewer",
        "rating": 4.0,
        "body": "A persisted review.",
        "spoiler": False,
    }],
    "thumbnailUrl": "https://provider.invalid/cover.jpg",
    "coverUpdatedOn": "2026-08-10T20:00:00Z",
}

def jpeg_cover() -> bytes:
    output = io.BytesIO()
    image = Image.new("RGB", (120, 180), "white")
    for y in range(20, 160):
        for x in range(15, 105):
            image.putpixel((x, y), ((x * 3) % 255, (y * 2) % 255, (x + y) % 255))
    image.save(output, "JPEG", quality=87)
    return output.getvalue()


COVER = jpeg_cover()


def reencode_jpeg(value: bytes, quality: int) -> bytes:
    output = io.BytesIO()
    with Image.open(io.BytesIO(value)) as image:
        image.convert("RGB").save(output, "JPEG", quality=quality)
    return output.getvalue()


def different_jpeg_cover() -> bytes:
    output = io.BytesIO()
    image = Image.new("RGB", (120, 180), "black")
    for y in range(10, 170):
        for x in range(10, 110):
            if (x // 8 + y // 8) % 2:
                image.putpixel((x, y), (245, 245, 245))
    image.save(output, "JPEG", quality=87)
    return output.getvalue()


class GrimmoryHandler(BaseHTTPRequestHandler):
    metadata = dict(RICH_METADATA)
    cover = COVER
    recommendations = [{
        "similarityScore": 0.9,
        "book": {"metadata": {"title": "Captured recommendation"}},
    }]

    def log_message(self, _format, *_args):
        return

    def _json(self, value, status=200):
        encoded = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_POST(self):
        if self.path == "/api/v1/auth/login":
            self._json({"accessToken": "secret-token", "refreshToken": "refresh"})
            return
        if self.path == "/api/v1/books/901/metadata/cover/upload":
            size = int(self.headers["Content-Length"])
            body = self.rfile.read(size)
            start = body.index(b"\xff\xd8")
            end = body.index(b"\r\n--", start)
            type(self).cover = body[start:end]
            self._json(None)
            return
        self._json({"error": "unknown"}, 404)

    def do_PUT(self):
        if self.path.startswith("/api/v1/books/901/metadata?"):
            size = int(self.headers["Content-Length"])
            wrapper = json.loads(self.rfile.read(size))
            type(self).metadata = wrapper["metadata"]
            self._json(type(self).metadata)
            return
        self._json({"error": "unknown"}, 404)

    def do_GET(self):
        if self.path.startswith("/api/v1/books/901?withDescription=true"):
            self._json({"id": 901, "metadata": type(self).metadata})
            return
        if self.path == "/api/v1/books/901/recommendations":
            self._json(type(self).recommendations)
            return
        if self.path.startswith("/api/v1/media/book/901/thumbnail?token="):
            self.send_response(200)
            self.send_header("Content-Type", "application/json")  # real server quirk
            self.send_header("Content-Length", str(len(type(self).cover)))
            self.end_headers()
            self.wfile.write(type(self).cover)
            return
        self._json({"error": "unknown"}, 404)


class MetadataCacheTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), GrimmoryHandler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=2)

    def setUp(self):
        GrimmoryHandler.metadata = dict(RICH_METADATA)
        GrimmoryHandler.cover = COVER
        GrimmoryHandler.recommendations = [{
            "similarityScore": 0.9,
            "book": {"metadata": {"title": "Captured recommendation"}},
        }]

    def test_projection_includes_absent_values_and_real_metadata(self):
        cover = {
            "sha256": "cover-sha",
            "visualFingerprint": cache_tool.cover_visual_fingerprint(COVER),
        }
        projected = cache_tool.project_metadata(RICH_METADATA, cover)
        self.assertIsNone(projected["subtitle"])
        self.assertEqual(projected["series"]["number"], 2.5)
        self.assertEqual(projected["genres"], ["Adventure", "Fantasy"])
        self.assertEqual(projected["ratings"]["goodreads"], 4.25)
        self.assertEqual(projected["reviews"][0]["body"], "A persisted review.")
        self.assertNotIn("id", projected["reviews"][0])
        self.assertEqual(projected["coverSourceSha256"], "cover-sha")
        self.assertEqual(projected["coverVisualFingerprint"]["width"], 120)
        presence = cache_tool.presence_contract(projected)
        self.assertFalse(presence["subtitle"])
        self.assertTrue(presence["series"]["name"])
        self.assertFalse(presence["ratings"]["amazon"])
        self.assertTrue(presence["ratings"]["goodreads"])

        koreader = cache_tool.project_koreader_metadata(
            RICH_METADATA,
            projected | {
                "personalRating": None,
                "metadataMatchScore": 0.94,
                "recommendations": [{"title": "A related book"}],
            },
        )
        self.assertEqual(koreader["categories"], ["Fantasy", "Adventure"])
        self.assertEqual(koreader["seriesName"], "A Series")
        self.assertEqual(koreader["goodreadsRating"], 4.25)
        self.assertEqual(koreader["bookReviews"][0]["body"], "A persisted review.")
        self.assertFalse(koreader["presence"]["personalRating"])
        self.assertTrue(koreader["presence"]["metadataMatchScore"])
        self.assertTrue(koreader["presence"]["recommendations"])

    def test_replay_payload_omits_transient_fields_and_database_ids(self):
        replay = cache_tool.replay_metadata(RICH_METADATA)
        self.assertNotIn("thumbnailUrl", replay)
        self.assertNotIn("coverUpdatedOn", replay)
        self.assertNotIn("bookId", replay)
        self.assertNotIn("id", replay["bookReviews"][0])
        self.assertEqual(replay["googleId"], "provider-item-123")

    def test_cover_fingerprint_tolerates_reencoding_but_rejects_wrong_art(self):
        original = cache_tool.cover_visual_fingerprint(COVER)
        reencoded = cache_tool.cover_visual_fingerprint(reencode_jpeg(COVER, 58))
        wrong = cache_tool.cover_visual_fingerprint(different_jpeg_cover())
        self.assertLessEqual(
            cache_tool.hash_distance(
                original["differenceHash256"], reencoded["differenceHash256"],
            ),
            20,
        )
        self.assertGreater(
            cache_tool.hash_distance(
                original["differenceHash256"], wrong["differenceHash256"],
            ),
            20,
        )

    def test_cache_refuses_a_tracked_repository_location(self):
        with self.assertRaises(cache_tool.CacheError):
            cache_tool.assert_private_cache_location(ROOT / "tests" / "private-metadata")

    def test_cache_rejects_a_modified_manifest(self):
        build = ROOT / "build"
        build.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="metadata-cache-hash-", dir=build) as temp:
            cache = Path(temp)
            unsigned = {"schemaVersion": 1, "books": []}
            manifest = dict(unsigned)
            manifest["manifestSha256"] = cache_tool.sha256_bytes(
                cache_tool.canonical_json(unsigned)
            )
            (cache / "manifest.json").write_text(
                json.dumps(manifest), encoding="utf-8",
            )
            self.assertEqual(cache_tool.load_cache(cache)["books"], [])
            manifest["books"] = [{"cacheKey": "tampered"}]
            (cache / "manifest.json").write_text(
                json.dumps(manifest), encoding="utf-8",
            )
            with self.assertRaisesRegex(cache_tool.CacheError, "integrity"):
                cache_tool.load_cache(cache)

    def test_synthetic_cache_identity_survives_generator_byte_changes(self):
        runtime = cache_tool.runtime_books({"books": [{
            "serverBookId": 1,
            "alias": "synthetic",
            "kind": "synthetic",
            "sourceSha256": "new-generated-epub-hash",
        }]})
        entries = cache_tool.cache_index({"books": [{
            "cacheKey": "old-generated-epub-hash",
            "sourceSha256": "old-generated-epub-hash",
            "alias": "synthetic",
            "kind": "synthetic",
        }]})
        self.assertEqual("synthetic:synthetic", runtime[0]["cacheKey"])
        self.assertEqual({"synthetic:synthetic"}, set(entries))
        self.assertEqual("new-generated-epub-hash",
                         runtime[0]["sourceSha256"])

        real = cache_tool.runtime_books({"books": [{
            "serverBookId": 2,
            "alias": "real-1001",
            "kind": "private-real-epub",
            "sourceSha256": "exact-private-source-hash",
        }]})
        self.assertEqual("exact-private-source-hash", real[0]["cacheKey"])

        metadata = {"title": "Synthetic control", "authors": ["Test"]}
        projection = cache_tool.stable_metadata(metadata)
        entries["synthetic:synthetic"].update({
            "metadata": projection,
            "metadataProjectionSha256": cache_tool.sha256_bytes(
                cache_tool.canonical_json(projection)),
        })

        class SyntheticClient:
            @staticmethod
            def book(_book_id):
                return {"metadata": dict(metadata)}

        checks = cache_tool.validate_synthetic_before_replay(
            runtime, entries, SyntheticClient())
        self.assertEqual(1, len(checks))
        self.assertTrue(checks[0]["matchedBeforeReplay"])
        self.assertEqual("old-generated-epub-hash",
                         checks[0]["cachedSourceSha256"])
        self.assertEqual("new-generated-epub-hash",
                         checks[0]["currentSourceSha256"])

        class DriftedSyntheticClient:
            @staticmethod
            def book(_book_id):
                return {"metadata": {"title": "Changed semantic fixture"}}

        with self.assertRaisesRegex(cache_tool.CacheError, "before replay"):
            cache_tool.validate_synthetic_before_replay(
                runtime, entries, DriftedSyntheticClient())

    def test_ui_evidence_item_must_match_the_persisted_provider_identity(self):
        book = {
            "alias": "private-book-1",
            "cacheKey": "a" * 64,
            "kind": "private",
        }
        supplied = {"a" * 64: {
            "provider": "Google",
            "providerItemId": "different-item",
        }}
        with self.assertRaisesRegex(cache_tool.CacheError, "does not match"):
            cache_tool.find_evidence(book, RICH_METADATA, supplied, False)

    def test_privacy_summary_contains_coverage_but_no_book_values(self):
        metadata = cache_tool.stable_metadata(RICH_METADATA)
        manifest = {
            "schemaVersion": 1,
            "serverProvenance": {"serverImageDigest": "sha256:pinned"},
            "books": [{
                "cacheKey": "a" * 64,
                "kind": "private",
                "alias": "secret-alias",
                "metadata": metadata,
                "captureEvidence": {
                    "captureMethod": "grimmory-web-metadata-selection",
                    "provider": "Google",
                    "providerItemId": "secret-provider-item",
                },
                "cover": {"sha256": "secret-cover-sha"},
            }],
        }
        summary = cache_tool.privacy_safe_summary(manifest)
        encoded = json.dumps(summary)
        self.assertEqual(summary["privateRealEpubCount"], 1)
        self.assertEqual(summary["providers"], {"Google": 1})
        self.assertEqual(summary["nonEmptyPersistedFieldCounts"]["title"], 1)
        self.assertNotIn("A Real Title", encoded)
        self.assertNotIn("secret-alias", encoded)
        self.assertNotIn("secret-provider-item", encoded)
        self.assertNotIn("secret-cover-sha", encoded)

    def test_capture_replay_and_verify_without_provider_requests(self):
        build = ROOT / "build"
        build.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="metadata-cache-test-", dir=build) as temp:
            directory = Path(temp)
            runtime = directory / "runtime.json"
            cache = directory / "cache"
            evidence = directory / "selection.json"
            enriched = directory / "runtime.with-metadata.json"
            runtime.write_text(json.dumps({
                "baseUrl": f"http://127.0.0.1:{self.server.server_port}",
                "username": "visual",
                "password": "secret",
                "provenance": {"grimmoryImageDigest": "sha256:pinned"},
                "books": [{
                    "serverBookId": 901,
                    "sourceSha256": "a" * 64,
                    "alias": "private-book-1",
                    "kind": "private",
                }],
            }), encoding="utf-8")
            evidence.write_text(json.dumps({"books": [{
                "sourceSha256": "a" * 64,
                "provider": "Google",
                "providerItemId": "provider-item-123",
                "query": "real title real author",
                "selectedAt": "2026-08-10T20:00:00Z",
            }]}), encoding="utf-8")

            capture_args = type("Args", (), {
                "runtime": runtime,
                "cache": cache,
                "selection_evidence": evidence,
                "allow_inferred_provenance": False,
            })()
            self.assertEqual(cache_tool.capture(capture_args), 0)
            manifest = cache_tool.load_cache(cache)
            self.assertEqual(len(manifest["books"]), 1)
            self.assertEqual(
                manifest["books"][0]["captureEvidence"]["captureMethod"],
                "grimmory-web-metadata-selection",
            )
            self.assertEqual(
                manifest["books"][0]["captureEvidence"]["providerItemId"],
                "provider-item-123",
            )
            self.assertNotIn(
                "recommendations", manifest["books"][0]["expectedMetadata"],
            )

            GrimmoryHandler.metadata = {"title": "Embedded fallback"}
            GrimmoryHandler.cover = jpeg_cover()
            GrimmoryHandler.recommendations = [{
                "similarityScore": 0.8,
                "book": {"metadata": {"title": "Fresh-stack recommendation"}},
            }]
            replay_args = type("Args", (), {
                "runtime": runtime,
                "cache": cache,
                "enriched_runtime": enriched,
            })()
            self.assertEqual(cache_tool.replay_or_verify(replay_args, True), 0)
            output = json.loads(enriched.read_text(encoding="utf-8"))
            expected = output["books"][0]["expectedMetadata"]
            self.assertEqual(expected["title"], "A Real Title")
            self.assertEqual(expected["coverSourceSha256"], cache_tool.sha256_bytes(COVER))
            self.assertTrue(expected["coverPresent"])
            self.assertEqual(
                output["books"][0]["serverDerivedAfterReplay"]
                ["recommendations"][0]["title"],
                "Fresh-stack recommendation",
            )
            self.assertEqual(
                output["books"][0]["serverDerivedAfterReplay"]["source"]["kind"],
                "grimmory-local-api-after-replay",
            )
            self.assertEqual(
                output["books"][0]["serverDerivedAfterReplay"]
                ["source"]["endpoints"],
                {
                    "recommendations": "/api/v1/books/901/recommendations",
                    "personalRating": (
                        "/api/v1/books/901?withDescription=true"
                    ),
                    "metadataMatchScore": (
                        "/api/v1/books/901?withDescription=true"
                    ),
                },
            )
            self.assertFalse(
                output["books"][0]["serverDerivedAfterReplay"]
                ["source"]["providerNetworkUsed"],
            )
            self.assertEqual(
                output["books"][0]["expectedKoreaderMetadata"]
                ["recommendations"][0]["title"],
                "Fresh-stack recommendation",
            )
            self.assertFalse(output["metadataCache"]["providerNetworkUsed"])


if __name__ == "__main__":
    unittest.main()
