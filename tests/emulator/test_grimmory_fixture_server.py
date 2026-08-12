#!/usr/bin/env python3

from __future__ import annotations

import json
import io
from pathlib import Path
import sys
from threading import Thread
import unittest
import urllib.error
import urllib.request
import zipfile


HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import grimmory_fixture_server as fixture_server  # noqa: E402


class GrimmoryFixtureServerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        fixture = json.loads(
            (HERE / "grimmory_library_fixture.json").read_text(encoding="utf-8")
        )
        cls.server = fixture_server.ThreadingHTTPServer(
            ("127.0.0.1", 0), fixture_server.Handler
        )
        cls.server.fixture_state = fixture_server.FixtureState(fixture)
        cls.server.quiet = True
        cls.thread = Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.url = f"http://127.0.0.1:{cls.server.server_port}"
        login = cls.request(
            "/api/v1/auth/login",
            "POST",
            {"username": "visual", "password": "grimmory-visual"},
            authenticated=False,
        )
        cls.token = login["accessToken"]

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=5)

    @classmethod
    def request(
        cls,
        path,
        method="GET",
        body=None,
        authenticated=True,
        raw=False,
        include_status=False,
    ):
        payload = json.dumps(body).encode() if body is not None else None
        headers = {"Content-Type": "application/json"}
        if authenticated:
            headers["Authorization"] = f"Bearer {cls.token}"
        request = urllib.request.Request(
            cls.url + path, data=payload, headers=headers, method=method
        )
        with urllib.request.urlopen(request, timeout=5) as response:
            data = response.read()
            value = data if raw else (json.loads(data) if data else None)
            return (response.status, value) if include_status else value

    def setUp(self):
        self.request("/__fixture/reset", "POST", {}, authenticated=False)

    def test_health_and_auth_boundary(self):
        health = self.request("/api/v1/healthcheck", authenticated=False)
        self.assertEqual(health["data"]["status"], "UP")
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.request("/api/v1/books/page?page=0&size=100", authenticated=False)
        self.assertEqual(caught.exception.code, 401)

    def test_library_has_stable_rich_identifiers(self):
        page = self.request("/api/v1/books/page?page=0&size=100")
        self.assertEqual([book["id"] for book in page["content"]], list(range(1001, 1009)))
        self.assertEqual(page["page"]["totalElements"], 8)
        self.assertEqual(page["content"][0]["primaryFile"]["id"], 5001)
        self.assertEqual(len(self.request("/api/v1/libraries")), 2)
        self.assertEqual(len(self.request("/api/v1/shelves")), 5)
        detail = self.request("/api/v1/books/1002?withDescription=true")
        self.assertIn("synthetic", detail["metadata"]["description"].lower())
        self.assertEqual(
            detail["metadata"]["bookReviews"][0]["reviewer"],
            "Visual Fixture Reader",
        )
        self.assertGreaterEqual(len(self.request("/api/v1/books/1002/recommendations")), 2)

    def test_v331_wire_envelopes_are_exact(self):
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.request("/api/v1/books/page?page=0&size=1", authenticated=False)
        error = json.loads(caught.exception.read())
        self.assertEqual(
            set(error), {"error", "path", "status", "timestamp"}
        )

        library = self.request("/api/v1/libraries")[0]
        self.assertEqual(set(library), {
            "allowedFormats", "formatPriority", "id", "metadataSource", "name",
            "organizationMode", "paths", "watch",
        })
        self.assertEqual(set(library["paths"][0]), {"id", "path"})
        shelf = self.request("/api/v1/shelves")[0]
        self.assertEqual(set(shelf), {
            "bookCount", "icon", "iconType", "id", "name", "publicShelf", "userId",
        })

        page = self.request("/api/v1/books/page?page=0&size=100")
        self.assertEqual(set(page), {"content", "links", "page"})
        self.assertEqual(
            set(page["page"]),
            {"cursor", "number", "size", "totalElements", "totalPages"},
        )
        primary = page["content"][0]["primaryFile"]
        self.assertEqual(set(primary), {
            "addedOn", "book", "bookId", "bookType", "extension", "fileName",
            "filePath", "fileSizeKb", "fileSubPath", "folderBased", "id",
        })
        file_item = self.request("/api/v1/books/1001/files?isBook=true")[0]
        self.assertEqual(set(file_item), set(primary) - {"filePath"})

    def test_cover_and_alternative_format_edges(self):
        cover = self.request(
            f"/api/v1/media/book/1001/thumbnail?token={self.token}",
            authenticated=False,
            raw=True,
        )
        self.assertTrue(cover.startswith(b"\x89PNG"))
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.request(
                f"/api/v1/media/book/1007/thumbnail?token={self.token}",
                authenticated=False,
                raw=True,
            )
        self.assertEqual(caught.exception.code, 404)
        files = self.request("/api/v1/books/1003/files?isBook=true")
        self.assertEqual([item["bookType"] for item in files], ["EPUB", "PDF"])
        pdf = self.request("/api/v1/books/1003/files/6003/download", raw=True)
        self.assertTrue(pdf.startswith(b"%PDF"))

    def test_synthetic_epub_is_stable_structured_and_long_form(self):
        book = self.server.fixture_state.fixture["books"][0]
        first = fixture_server.synthetic_epub(book)
        second = fixture_server.synthetic_epub(book)
        self.assertEqual(first, second)
        with zipfile.ZipFile(io.BytesIO(first)) as archive:
            names = archive.namelist()
            chapters = [name for name in names if name.startswith("OEBPS/chapter-")]
            self.assertEqual(len(chapters), 12)
            self.assertIn("OEBPS/nav.xhtml", names)
            self.assertIn("OEBPS/styles.css", names)
            # Large enough to render well over a hundred KOReader pages while
            # keeping every emulator process quick. This guards against the
            # former one-document/one-page smoke fixture, not prose volume.
            self.assertGreater(sum(len(archive.read(name)) for name in chapters), 150_000)
            self.assertIn(b'id="p36"', archive.read("OEBPS/chapter-12.xhtml"))

    def test_progress_annotation_and_session_round_trips(self):
        self.request(
            "/api/v1/app/books/1002/progress",
            "PUT",
            {"fileProgress": {"bookFileId": 5002, "positionData": "epubcfi(/6/20!/4/2:0)", "progressPercent": 70.5}},
        )
        progress = self.request("/api/v1/app/books/1002/progress")
        self.assertEqual(progress["epubProgress"]["percentage"], 70.5)

        annotation = self.request(
            "/api/v1/annotations",
            "POST",
            {"bookId": 1002, "cfi": "epubcfi(/6/2!/4/2:0)", "text": "Fixture highlight"},
        )
        self.assertEqual(annotation["id"], 9001)
        self.request(f"/api/v1/annotations/{annotation['id']}", "PUT", {"note": "Changed"})
        self.assertEqual(self.request("/api/v1/annotations/book/1002")[0]["note"], "Changed")
        delete_status, _ = self.request(
            f"/api/v1/annotations/{annotation['id']}",
            "DELETE",
            include_status=True,
        )
        self.assertEqual(delete_status, 204)
        self.assertEqual(self.request("/api/v1/annotations/book/1002"), [])

        empty_sessions = self.request(
            "/api/v1/reading-sessions/book/1002?page=0&size=100"
        )
        self.assertEqual(empty_sessions["content"], [])
        self.assertEqual(empty_sessions["page"]["totalElements"], 0)
        self.assertEqual(empty_sessions["page"]["totalPages"], 0)

        session_status, session = self.request(
            "/api/v1/reading-sessions",
            "POST",
            {"bookId": 1002, "bookType": "EPUB", "startTime": "2026-08-01T10:00:00Z", "endTime": "2026-08-01T10:30:00Z"},
            include_status=True,
        )
        self.assertEqual(session_status, 202)
        self.assertIsNone(session)
        sessions = self.request("/api/v1/reading-sessions/book/1002?page=0&size=100")
        self.assertEqual(len(sessions["content"]), 1)
        self.assertEqual(sessions["content"][0]["id"], 9501)
        self.assertEqual(sessions["page"]["totalElements"], 1)


if __name__ == "__main__":
    unittest.main()
