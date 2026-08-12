from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tests" / "compatibility" / "server_contract_parity.py"
SPEC = importlib.util.spec_from_file_location("server_contract_parity", SCRIPT)
assert SPEC and SPEC.loader
parity = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = parity
SPEC.loader.exec_module(parity)


class ServerContractParityTest(unittest.TestCase):
    @staticmethod
    def annotation():
        return {
            "bookId": 4,
            "cfi": "epubcfi(/6/2)",
            "chapterTitle": "One",
            "color": "#FFFF00",
            "createdAt": "2026-08-01T00:00:00.987654321",
            "id": 7,
            "note": "created",
            "style": "highlight",
            "text": "selected",
            "updatedAt": "2026-08-01T00:00:00.987654321",
            "userId": 1,
        }

    @staticmethod
    def detail_metadata():
        metadata = {
            "authors": ["Reader"],
            "bookId": 4,
            "categories": [],
            "language": "English",
            "moods": [],
            "tags": [],
            "title": "Nested",
        }
        metadata.update({field + "Locked": True for field in parity.DETAIL_LOCK_FIELDS})
        return metadata

    @staticmethod
    def detail_file():
        return {
            "addedOn": "2026-08-01T00:00:00Z",
            "book": True,
            "bookId": 4,
            "bookType": "EPUB",
            "extension": "epub",
            "fileName": "book.epub",
            "filePath": "/books/book.epub",
            "fileSizeKb": 123,
            "fileSubPath": "book.epub",
            "folderBased": False,
            "id": 9,
        }

    @classmethod
    def detail_book(cls):
        return {
            "addedOn": "2026-08-01T00:00:00Z",
            "alternativeFormats": [],
            "id": 4,
            "isPhysical": False,
            "libraryId": 1,
            "libraryName": "Library",
            "libraryPath": {"id": 2},
            "metadata": cls.detail_metadata(),
            "metadataMatchScore": 100,
            "primaryFile": cls.detail_file(),
            "readStatus": "UNREAD",
            "shelves": [],
            "supplementaryFiles": [],
        }

    def test_normalizes_nested_real_and_flat_fixture_books_identically(self):
        primary = {
            "id": 9,
            "bookId": 4,
            "bookType": "EPUB",
            "fileName": "book.epub",
            "fileSizeKb": 123,
        }
        nested = {
            "id": 4,
            "metadata": {"title": "Nested", "authors": ["Reader"]},
            "primaryFile": primary,
        }
        flat = {
            "id": 1001,
            "title": "Flat",
            "metadata": {"title": "Flat", "authors": ["Reader"]},
            "primaryFile": {**primary, "id": 5001, "bookId": 1001},
        }
        self.assertEqual(parity.normalized_book(nested), parity.normalized_book(flat))

    def test_normalized_book_rejects_missing_metadata(self):
        raw = self.detail_book()
        raw.pop("metadata")
        with self.assertRaisesRegex(parity.ParityError, "metadata must be an object"):
            parity.normalized_book(raw)

    def test_detail_contract_rejects_outer_key_drift(self):
        expected = self.detail_book()
        parity.canonical_book(expected, detail=True)
        missing = self.detail_book()
        missing.pop("libraryPath")
        with self.assertRaisesRegex(parity.ParityError, "missing fields: libraryPath"):
            parity.canonical_book(missing, detail=True)
        extra = self.detail_book()
        extra["legacyTitle"] = "drift"
        with self.assertRaisesRegex(parity.ParityError, "unexpected fields: legacyTitle"):
            parity.canonical_book(extra, detail=True)

    def test_detail_contract_rejects_file_and_metadata_drift(self):
        wrong_file = self.detail_book()
        wrong_file["primaryFile"].pop("fileSubPath")
        with self.assertRaisesRegex(parity.ParityError, "missing fields: fileSubPath"):
            parity.canonical_book(wrong_file, detail=True)
        wrong_metadata = self.detail_book()
        wrong_metadata["metadata"]["title"] = 5
        with self.assertRaisesRegex(parity.ParityError, "metadata.title must be a string"):
            parity.canonical_book(wrong_metadata, detail=True)
        unexpected_provider = self.detail_book()
        unexpected_provider["metadata"]["inventedProviderField"] = "drift"
        with self.assertRaisesRegex(parity.ParityError, "unexpected fields"):
            parity.canonical_book(unexpected_provider, detail=True)

    def test_catalogue_state_is_explicitly_normalized_but_validated(self):
        baseline = self.detail_book()
        stateful = self.detail_book()
        stateful.update({
            "dateFinished": "2026-08-02T00:00:00Z",
            "lastReadTime": "2026-08-02T00:01:00Z",
            "personalRating": 5,
            "epubProgress": {
                "cfi": "epubcfi(/6/2!/4/2:0)",
                "contentSourceProgressPercent": None,
                "href": None,
                "percentage": 42.5,
                "ttsPositionCfi": None,
            },
        })
        self.assertEqual(
            parity.canonical_book(baseline, detail=True),
            parity.canonical_book(stateful, detail=True),
        )
        stateful["epubProgress"].pop("ttsPositionCfi")
        with self.assertRaisesRegex(parity.ParityError, "missing fields: ttsPositionCfi"):
            parity.canonical_book(stateful, detail=True)

    def test_library_shelf_and_error_shapes_reject_drift(self):
        shelf = {
            "bookCount": 1, "icon": "BOOKSHELF", "iconType": "LUCIDE",
            "id": 2, "name": "Shelf", "publicShelf": False, "userId": 1,
        }
        parity.canonical_shelf(shelf)
        drift = dict(shelf)
        drift["bookIds"] = [4]
        with self.assertRaisesRegex(parity.ParityError, "unexpected fields: bookIds"):
            parity.canonical_shelf(drift)

        error = parity.Response(
            401,
            {"error": "denied", "path": "/api/v1/books/page", "status": 401,
             "timestamp": "2026-08-01T00:00:00Z"},
            "application/json", b"{}",
        )
        self.assertEqual(parity.response_shape(error)["body"]["fields"]["path"], "string")

    def test_comparison_rejects_status_or_shape_drift(self):
        expected = {"annotations": {"post": 200, "delete": 204}}
        parity.compare(expected, expected.copy())
        with self.assertRaisesRegex(parity.ParityError, "observations differ"):
            parity.compare(expected, {"annotations": {"post": 200, "delete": 200}})

    def test_unique_identity_rejects_missing_and_duplicate_records(self):
        self.assertEqual(
            parity.require_unique_id([{"id": 4}, {"id": 9}], 9, "items"),
            {"id": 9},
        )
        with self.assertRaisesRegex(parity.ParityError, "exactly once; got 0"):
            parity.require_unique_id([{"id": 4}], 9, "items")
        with self.assertRaisesRegex(parity.ParityError, "exactly once; got 2"):
            parity.require_unique_id([{"id": 9}, {"id": 9}], 9, "items")

    def test_annotation_contract_rejects_wrong_extra_and_stale_fields(self):
        expected = {
            "bookId": 4, "cfi": "epubcfi(/6/2)", "chapterTitle": "One",
            "color": "#FFFF00", "note": "created", "style": "highlight",
            "text": "selected",
        }
        annotation = {
            **expected, "id": 7, "userId": 1,
            "createdAt": "2026-08-01T00:00:00Z",
            "updatedAt": "2026-08-01T00:00:00Z",
        }
        parity.require_annotation_fields(annotation, "annotation", expected, expected_id=7)
        wrong = dict(annotation)
        wrong["text"] = "wrong selection"
        with self.assertRaisesRegex(parity.ParityError, "annotation.text differs"):
            parity.require_annotation_fields(wrong, "annotation", expected)
        extra = dict(annotation)
        extra["legacyId"] = 99
        with self.assertRaisesRegex(parity.ParityError, "unexpected fields: legacyId"):
            parity.require_annotation_fields(extra, "annotation", expected)
        with self.assertRaisesRegex(parity.ParityError, "must remain 8"):
            parity.require_annotation_fields(annotation, "annotation", expected, expected_id=8)

    def test_annotation_persistence_allows_only_database_fraction_truncation(self):
        emitted = self.annotation()
        persisted = dict(emitted)
        persisted["createdAt"] = "2026-08-01T00:00:00"
        persisted["updatedAt"] = "2026-08-01T00:00:00"
        parity.require_annotation_persistence_equal(
            emitted, persisted, "annotation persistence"
        )

        exact_fixture = dict(emitted)
        exact_fixture["createdAt"] = "2026-08-01T00:00:00Z"
        exact_fixture["updatedAt"] = "2026-08-01T00:00:00Z"
        parity.require_annotation_persistence_equal(
            exact_fixture, dict(exact_fixture), "fixture persistence"
        )

    def test_annotation_persistence_rejects_wrong_field_extra_and_timestamp_drift(self):
        emitted = self.annotation()
        wrong_text = dict(emitted)
        wrong_text["text"] = "selecte"
        with self.assertRaisesRegex(
            parity.ParityError,
            r"\$\.text.*expected 'selected', got 'selecte'",
        ):
            parity.require_annotation_persistence_equal(
                emitted, wrong_text, "annotation persistence"
            )

        extra = dict(emitted)
        extra["legacyId"] = 4
        with self.assertRaisesRegex(parity.ParityError, r"unexpected=\['legacyId'\]"):
            parity.require_annotation_persistence_equal(
                emitted, extra, "annotation persistence"
            )

        wrong_second = dict(emitted)
        wrong_second["createdAt"] = "2026-08-01T00:00:01"
        with self.assertRaisesRegex(
            parity.ParityError, "beyond DATETIME\\(0\\).*only removal",
        ):
            parity.require_annotation_persistence_equal(
                emitted, wrong_second, "annotation persistence"
            )

        retained_different_fraction = dict(emitted)
        retained_different_fraction["updatedAt"] = "2026-08-01T00:00:00.1"
        with self.assertRaisesRegex(parity.ParityError, "beyond DATETIME\\(0\\)"):
            parity.require_annotation_persistence_equal(
                emitted, retained_different_fraction, "annotation persistence"
            )

        changed_offset = dict(emitted)
        changed_offset["createdAt"] = "2026-08-01T00:00:00Z"
        with self.assertRaisesRegex(parity.ParityError, "beyond DATETIME\\(0\\)"):
            parity.require_annotation_persistence_equal(
                emitted, changed_offset, "annotation persistence"
            )

    def test_annotation_timestamp_validation_rejects_invented_or_invalid_values(self):
        annotation = self.annotation()
        annotation["createdAt"] = "yesterday"
        expected = {
            key: annotation[key]
            for key in ("bookId", "cfi", "chapterTitle", "color", "note", "style", "text")
        }
        with self.assertRaisesRegex(parity.ParityError, "not a strict ISO server datetime"):
            parity.require_annotation_fields(annotation, "annotation", expected)

        with self.assertRaisesRegex(parity.ParityError, "not a valid server datetime"):
            parity.server_datetime_parts(
                "2026-02-30T00:00:00", "annotation.createdAt"
            )

    def test_exact_difference_reports_nested_path_type_and_order(self):
        self.assertEqual(
            parity.first_exact_difference(
                {"items": [{"id": 1}, {"id": 2}]},
                {"items": [{"id": 1}, {"id": "2"}]},
            ),
            "$.items[1].id: type differs; expected int 2, got str '2'",
        )
        with self.assertRaisesRegex(
            parity.ParityError, r"observations differ at \$\.items\[0\]",
        ):
            parity.compare({"items": [1, 2]}, {"items": [2, 1]})

    def test_fixture_completes_every_strict_workflow(self):
        with parity.fixture_target() as target:
            observations = parity.exercise(target)
        self.assertEqual(len(observations), 14)
        self.assertEqual(observations["unauthorised"]["status"], 401)
        self.assertEqual(
            observations["booksPage"]["wire"]["outerFields"],
            ["content", "links", "page"],
        )

    def test_public_report_contains_no_connection_or_book_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "report.json"
            observations = {"login": 200, "download": {"status": 200, "format": "epub-zip"}}
            parity.write_report(output, observations, source_fingerprint="f" * 64)
            report = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(report["status"], "passed")
            self.assertEqual(report["sourceFingerprint"], "f" * 64)
            rendered = output.read_text(encoding="utf-8")
            for private_key in ("baseUrl", "password", "token", "title", "sourceSha256"):
                self.assertNotIn(private_key, rendered)


if __name__ == "__main__":
    unittest.main()
