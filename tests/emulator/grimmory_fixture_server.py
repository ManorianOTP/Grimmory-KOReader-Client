#!/usr/bin/env python3
"""A deterministic, stateful subset of the Grimmory v3 API for visual tests."""

from __future__ import annotations

import argparse
from copy import deepcopy
from datetime import datetime, timezone
from html import escape
import io
import json
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import re
import struct
import sys
from urllib.parse import parse_qs, urlparse
import zipfile
import zlib


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_FIXTURE = ROOT / "tests" / "emulator" / "grimmory_library_fixture.json"
TOKEN = "visual-access-token"
REFRESH_TOKEN = "visual-refresh-token"
FIXED_TIME = "2026-08-01T12:00:00Z"


def json_bytes(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def png_chunk(kind: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


def synthetic_cover(book_id: int, width: int = 360, height: int = 540) -> bytes:
    base = 48 + (book_id * 29) % 125
    rows = []
    for y in range(height):
        band = 35 if (y // 54) % 2 else 0
        pixel = bytes((min(245, base + band), min(245, base + 18), min(245, base + 42)))
        rows.append(b"\x00" + pixel * width)
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", header) + png_chunk(
        b"IDAT", zlib.compress(b"".join(rows), 9)
    ) + png_chunk(b"IEND", b"")


def _epub_info(path: str, *, stored: bool = False) -> zipfile.ZipInfo:
    """Return a byte-for-byte stable ZIP member for the committed CI fixture."""
    info = zipfile.ZipInfo(path, (2026, 8, 1, 12, 0, 0))
    info.compress_type = zipfile.ZIP_STORED if stored else zipfile.ZIP_DEFLATED
    info.external_attr = 0o644 << 16
    return info


def _fixture_chapter(number: int) -> str:
    settings = (
        "the rain garden behind the station",
        "a quiet workshop beside the river",
        "the lantern room above the harbour",
        "an orchard crossed by old stone paths",
    )
    details = (
        "maps, receipts, pencilled notes, and a key with no label",
        "thread, brass gears, seed packets, and a chipped blue cup",
        "weather logs, tide tables, postcards, and a folded paper bird",
        "measuring cord, field glasses, notebooks, and a tin of tea",
    )
    paragraphs = []
    for paragraph in range(1, 37):
        setting = settings[(number + paragraph) % len(settings)]
        objects = details[(number * 2 + paragraph) % len(details)]
        paragraphs.append(
            "<p id=\"p{paragraph}\">On the {ordinal} morning, Mara returned to {setting}. "
            "She compared {objects}, then wrote observation {marker} in the margin. "
            "Nothing dramatic happened; that was useful, because careful work depends on "
            "small differences being noticed. A bell sounded in the distance, someone "
            "laughed on the lower path, and the day continued with its ordinary, uneven "
            "rhythm.</p>".format(
                paragraph=paragraph,
                ordinal=paragraph,
                setting=setting,
                objects=objects,
                marker=f"{number}.{paragraph}",
            )
        )
    paragraphs.insert(
        9,
        # Put the opening smart-quoted word in a genuine inline element.  The
        # KOReader acceptance journey starts at that rendered quote and extends
        # across the following words, so its device highlight deterministically
        # crosses a real DOM/text-node boundary without changing visible prose.
        "<blockquote><p><em>\u201cRecord</em> what changed, including the awkward details,\u201d "
        "the field guide advised.</p></blockquote>",
    )
    paragraphs.insert(
        22,
        "<ul><li>A short item</li><li>An item whose wording wraps onto another "
        "line at narrow widths</li><li>One final item with <em>emphasis</em></li></ul>",
    )
    return (
        '<?xml version="1.0" encoding="utf-8"?>'
        '<html xmlns="http://www.w3.org/1999/xhtml" lang="en">'
        f'<head><title>Chapter {number}</title><link rel="stylesheet" '
        'type="text/css" href="styles.css"/></head><body>'
        f'<section epub:type="chapter" xmlns:epub="http://www.idpf.org/2007/ops" '
        f'id="chapter-{number}"><h1>Chapter {number}: Field Note {number:02d}</h1>'
        f'<p class="dateline">Saturday, {number} August \u2014 07:{number:02d}</p>'
        + "".join(paragraphs)
        + '<p class="end">\u2767</p></section></body></html>'
    )


def synthetic_epub(book: dict) -> bytes:
    """Build a realistic, copyright-safe EPUB large enough for position sync.

    The book intentionally has twelve spine items and hundreds of paragraphs.
    Its text is stable generated fixture prose, not content from a supplied book.
    This lets KOReader produce genuine page positions and CFIs in CI.
    """
    title = escape(str(book["title"]))
    author = escape(str(book["authors"][0]))
    chapter_count = 12
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as archive:
        archive.writestr(_epub_info("mimetype", stored=True), "application/epub+zip")
        archive.writestr(
            _epub_info("META-INF/container.xml"),
            '<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
        )
        manifest = "".join(
            f'<item id="chapter-{number}" href="chapter-{number:02d}.xhtml" '
            'media-type="application/xhtml+xml"/>'
            for number in range(1, chapter_count + 1)
        )
        spine = "".join(
            f'<itemref idref="chapter-{number}"/>'
            for number in range(1, chapter_count + 1)
        )
        archive.writestr(
            _epub_info("OEBPS/content.opf"),
            '<?xml version="1.0" encoding="utf-8"?>'
            '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
            'unique-identifier="id"><metadata '
            'xmlns:dc="http://purl.org/dc/elements/1.1/">'
            f'<dc:identifier id="id">visual-{book["id"]}</dc:identifier>'
            f'<dc:title>{title}</dc:title><dc:creator>{author}</dc:creator>'
            '<dc:language>en</dc:language><meta property="dcterms:modified">'
            '2026-08-01T12:00:00Z</meta></metadata><manifest>'
            '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" '
            f'properties="nav"/><item id="style" href="styles.css" '
            f'media-type="text/css"/>{manifest}</manifest><spine>{spine}</spine></package>',
        )
        archive.writestr(
            _epub_info("OEBPS/nav.xhtml"),
            '<?xml version="1.0" encoding="utf-8"?>'
            '<html xmlns="http://www.w3.org/1999/xhtml" '
            'xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title>'
            '</head><body><nav epub:type="toc"><h1>Contents</h1><ol>'
            + "".join(
                f'<li><a href="chapter-{number:02d}.xhtml">Chapter {number}</a></li>'
                for number in range(1, chapter_count + 1)
            )
            + '</ol></nav></body></html>',
        )
        archive.writestr(
            _epub_info("OEBPS/styles.css"),
            "body { line-height: 1.35; } h1 { page-break-before: always; } "
            ".dateline { font-style: italic; } blockquote { margin: 1em 2em; } "
            ".end { text-align: center; }",
        )
        for number in range(1, chapter_count + 1):
            archive.writestr(
                _epub_info(f"OEBPS/chapter-{number:02d}.xhtml"),
                _fixture_chapter(number),
            )
    return output.getvalue()


class FixtureState:
    # Grimmory v3.3.1's detail DTO exposes a lock flag for every provider-owned
    # metadata field.  Keeping this list explicit is intentional: an upstream
    # field addition is a contract change, not something the fixture should
    # silently approximate.
    DETAIL_LOCK_FIELDS = (
        "abridged", "ageRating", "amazonRating", "amazonReviewCount",
        "asin", "audibleId", "audibleRating", "audibleReviewCount",
        "audiobookCover", "authors", "categories", "comicvineId",
        "contentRating", "cover", "description", "goodreadsId",
        "goodreadsRating", "goodreadsReviewCount", "googleId",
        "hardcoverBookId", "hardcoverId", "hardcoverRating",
        "hardcoverReviewCount", "isbn10", "isbn13", "language",
        "lubimyczytacId", "lubimyczytacRating", "moods", "narrator",
        "pageCount", "publishedDate", "publisher", "ranobedbId",
        "ranobedbRating", "reviews", "seriesName", "seriesNumber",
        "seriesTotal", "subtitle", "tags", "title",
    )

    def __init__(self, fixture: dict):
        self.fixture = fixture
        self.books_by_id = {int(book["id"]): book for book in fixture["books"]}
        self.annotations: dict[int, list[dict]] = {book_id: [] for book_id in self.books_by_id}
        self.sessions: dict[int, list[dict]] = {book_id: [] for book_id in self.books_by_id}
        self.progress = {
            book_id: {
                "epubProgress": (
                    {
                        "percentage": book.get("progressPercent", 0),
                        "cfi": book.get("progressCfi"),
                        "href": None,
                        "contentSourceProgressPercent": None,
                        "ttsPositionCfi": None,
                    }
                    if book.get("progressPercent", 0) > 0
                    else None
                )
            }
            for book_id, book in self.books_by_id.items()
        }
        self.next_annotation_id = 9001
        self.next_session_id = 9501

    def reset(self) -> None:
        fresh = FixtureState(self.fixture)
        self.__dict__.update(fresh.__dict__)

    def shelf_summaries(self) -> list[dict]:
        return [
            {
                "id": shelf["id"],
                "name": shelf["name"],
                "bookCount": len(shelf["bookIds"]),
                "icon": "BOOKSHELF",
                "iconType": "LUCIDE",
                "publicShelf": False,
                "userId": 1,
            }
            for shelf in self.fixture["shelves"]
        ]

    @staticmethod
    def _added_on(book_id: int) -> str:
        return f"2026-0{1 + ((book_id - 1001) % 7)}-01T09:00:00Z"

    def file_dto(self, book: dict, item: dict | None = None, *, detail: bool = False) -> dict:
        book_id = int(book["id"])
        source = item or {
            "id": book["fileId"],
            "fileName": book.get("sourceFileName") or book["fileName"],
            "fileSizeKb": round(int(book.get("sourceBytes", 96 * 1024)) / 1024),
            "bookType": "EPUB",
            "extension": "epub",
        }
        file_name = str(source["fileName"])
        result = {
            "addedOn": self._added_on(book_id),
            "book": True,
            "bookId": book_id,
            "bookType": str(source["bookType"]),
            "extension": str(source.get("extension") or Path(file_name).suffix.lstrip(".")),
            "fileName": file_name,
            "fileSizeKb": int(source["fileSizeKb"]),
            "fileSubPath": file_name,
            "folderBased": False,
            "id": int(source["id"]),
        }
        if detail:
            result["filePath"] = f"/visual-library/{book_id}/{file_name}"
        return result

    def metadata_dto(self, book: dict, *, detail: bool) -> dict:
        book_id = int(book["id"])
        metadata = {
            "title": book["title"],
            "authors": book["authors"],
            "language": "English",
            "bookId": book_id,
            "categories": book.get("categories", []),
            "tags": book.get("tags", []),
            "moods": [],
            "subtitle": book.get("subtitle"),
            "seriesName": book.get("seriesName"),
            "seriesNumber": book.get("seriesNumber"),
            "seriesTotal": book.get("seriesTotal"),
            "publisher": book.get("publisher"),
            "publishedDate": book.get("publishedDate"),
            "pageCount": book.get("pageCount"),
            "coverUpdatedOn": FIXED_TIME,
            "goodreadsRating": 4.42 if book_id % 2 else 4.61,
            "goodreadsReviewCount": 125430 + book_id,
            "hardcoverRating": 4.37 if book_id % 2 else 4.55,
            "hardcoverReviewCount": 3180 + book_id,
        }
        if detail:
            metadata["description"] = (
                f"Deterministic visual-test summary for {book['title']}. "
                "This text is synthetic and is not copied from the supplied ebook."
            )
            metadata["bookReviews"] = ([{
                "id": 8101,
                "reviewer": "Visual Fixture Reader",
                "rating": 5,
                "title": "A synthetic review",
                "body": "Short deterministic review text written for layout testing.",
                "date": "2026-07-14",
            }] if book_id == 1002 else [])
            metadata.update({field + "Locked": True for field in self.DETAIL_LOCK_FIELDS})
        else:
            metadata["allMetadataLocked"] = True
        # Grimmory omits null provider values rather than serializing a forest
        # of nulls.  The fixture follows that wire behaviour exactly.
        return {key: value for key, value in metadata.items() if value is not None}

    def dto(self, book: dict, detail: bool = False) -> dict:
        book_id = int(book["id"])
        shelves = [
            summary
            for shelf, summary in zip(
                self.fixture["shelves"], self.shelf_summaries(), strict=True
            )
            if book_id in shelf["bookIds"]
        ]
        primary = self.file_dto(book, detail=True)
        alternatives = [self.file_dto(book, item, detail=True)
                        for item in book.get("alternativeFormats", [])]
        progress = self.progress[book_id].get("epubProgress")
        result = {
            "id": book_id,
            "libraryId": self.fixture["library"]["id"],
            "libraryName": self.fixture["library"]["name"],
            "primaryFile": primary,
            "metadata": self.metadata_dto(book, detail=detail),
            "addedOn": self._added_on(book_id),
            "isPhysical": False,
            "metadataMatchScore": 100.0,
        }
        # These are legitimate per-user catalogue state.  Jackson omits absent
        # values on the real server, so do the same here.
        if book.get("readStatus") is not None:
            result["readStatus"] = book["readStatus"]
        if book.get("personalRating") is not None:
            result["personalRating"] = book["personalRating"]
        if progress:
            result["epubProgress"] = progress
            result["lastReadTime"] = "2026-07-30T20:15:00Z"
        if not detail:
            return result
        result.update({
            "alternativeFormats": alternatives,
            "libraryPath": {"id": self.fixture["library"]["id"] * 10 + 1},
            "readStatus": book.get("readStatus", "UNREAD"),
            "shelves": shelves,
            "supplementaryFiles": [],
        })
        return result


class Handler(BaseHTTPRequestHandler):
    server_version = "GrimmoryVisualFixture/1"

    @property
    def state(self) -> FixtureState:
        return self.server.fixture_state  # type: ignore[attr-defined]

    def log_message(self, fmt: str, *args: object) -> None:
        if getattr(self.server, "quiet", False):  # type: ignore[attr-defined]
            return
        super().log_message(fmt, *args)

    def body(self) -> dict:
        size = int(self.headers.get("Content-Length", "0"))
        if size == 0:
            return {}
        return json.loads(self.rfile.read(size))

    def send_bytes(self, body: bytes, content_type: str, status: int = 200) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Grimmory-Fixture", "deterministic-v1")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def send_json(self, value: object, status: int = 200) -> None:
        self.send_bytes(json_bytes(value), "application/json; charset=utf-8", status)

    def send_empty(self, status: int) -> None:
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Grimmory-Fixture", "deterministic-v1")
        self.end_headers()

    def error(self, status: int, message: str) -> None:
        path, _query = self.parsed()
        self.send_json({
            "error": message,
            "path": path,
            "status": int(status),
            "timestamp": FIXED_TIME,
        }, status)

    def authorized(self, query: dict[str, list[str]]) -> bool:
        bearer = self.headers.get("Authorization", "") == f"Bearer {TOKEN}"
        query_token = query.get("token", [""])[0] == TOKEN
        return bearer or query_token

    def require_auth(self, query: dict[str, list[str]]) -> bool:
        if self.authorized(query):
            return True
        self.error(HTTPStatus.UNAUTHORIZED, "fixture token required")
        return False

    def parsed(self):
        parsed = urlparse(self.path)
        return parsed.path.rstrip("/") or "/", parse_qs(parsed.query)

    def do_HEAD(self) -> None:
        self.do_GET()

    def do_GET(self) -> None:
        path, query = self.parsed()
        if path == "/api/v1/healthcheck":
            return self.send_json({
                "status": 200,
                "message": "Pong",
                "timestamp": FIXED_TIME,
                "data": {"status": "UP", "message": "Visual fixture ready.", "version": "3.3.1", "timestamp": FIXED_TIME},
            })
        if path == "/api/v1/version":
            return self.send_json({"current": "3.3.1", "latest": "3.3.1"})
        if path == "/__fixture/state":
            return self.send_json({
                "mode": self.state.fixture.get("fixtureMode", "synthetic"),
                "bookIds": sorted(self.state.books_by_id),
                "books": len(self.state.books_by_id),
                "annotations": sum(map(len, self.state.annotations.values())),
                "sessions": sum(map(len, self.state.sessions.values())),
            })
        if not self.require_auth(query):
            return
        if path == "/api/v1/libraries":
            libraries = self.state.fixture.get("libraries", [self.state.fixture["library"]])
            return self.send_json([
                {
                    "allowedFormats": ["EPUB", "PDF", "MOBI", "AZW3"],
                    "formatPriority": ["EPUB", "PDF", "MOBI", "AZW3"],
                    "id": library["id"],
                    "metadataSource": "EMBEDDED",
                    "name": library["name"],
                    "organizationMode": "NONE",
                    "paths": [{"id": library["id"] * 10 + 1,
                               "path": f"/visual-library/{library['id']}"}],
                    "watch": False,
                }
                for library in libraries
            ])
        if path == "/api/v1/shelves":
            return self.send_json(self.state.shelf_summaries())
        if path in {"/api/v1/books", "/api/v1/books/page"}:
            books = [self.state.dto(book) for book in self.state.fixture["books"]]
            if path.endswith("/page") or "page" in query:
                page = max(0, int(query.get("page", ["0"])[0]))
                size = max(1, int(query.get("size", ["100"])[0]))
                start = page * size
                return self.send_json({
                    "content": books[start:start + size],
                    "links": [{
                        "href": f"/api/v1/books/page?page={page}&size={size}",
                        "rel": "self",
                        "type": "GET",
                    }],
                    "page": {"cursor": "", "size": size, "number": page,
                             "totalElements": len(books),
                             "totalPages": (len(books) + size - 1) // size},
                })
            return self.send_json(books)
        match = re.fullmatch(r"/api/v1/books/(\d+)", path)
        if match:
            book = self.state.books_by_id.get(int(match.group(1)))
            return self.send_json(self.state.dto(book, True)) if book else self.error(404, "book not found")
        match = re.fullmatch(r"/api/v1/books/(\d+)/files", path)
        if match:
            book = self.state.books_by_id.get(int(match.group(1)))
            if not book:
                return self.error(404, "book not found")
            return self.send_json([
                self.state.file_dto(book),
                *(self.state.file_dto(book, item)
                  for item in book.get("alternativeFormats", [])),
            ])
        match = re.fullmatch(r"/api/v1/books/(\d+)/recommendations", path)
        if match:
            source_id = int(match.group(1))
            source = self.state.books_by_id.get(source_id)
            if not source:
                return self.error(404, "book not found")
            related = [book for book in self.state.fixture["books"] if book["id"] != source_id and book.get("seriesName") == source.get("seriesName")][:4]
            return self.send_json([{"book": self.state.dto(book), "similarityScore": round(0.96 - index * 0.04, 2)} for index, book in enumerate(related)])
        match = re.fullmatch(r"/api/v1/media/book/(\d+)/(?:thumbnail|cover)", path)
        if match:
            return self.serve_cover(int(match.group(1)))
        match = re.fullmatch(r"/api/v1/books/(\d+)/(?:download|files/(\d+)/download)", path)
        if match:
            return self.serve_book(int(match.group(1)), int(match.group(2)) if match.group(2) else None)
        match = re.fullmatch(r"/api/v1/app/books/(\d+)/progress", path)
        if match:
            progress = self.state.progress.get(int(match.group(1)))
            if progress is None:
                return self.error(404, "book not found")
            epub = progress.get("epubProgress")
            if type(epub) is dict:
                epub = {
                    "percentage": epub.get("percentage"),
                    "cfi": epub.get("cfi"),
                    "href": epub.get("href"),
                    "updatedAt": FIXED_TIME,
                }
                return self.send_json({
                    "readStatus": "READING",
                    "readProgress": epub["percentage"],
                    "lastReadTime": FIXED_TIME,
                    "epubProgress": epub,
                })
            return self.send_json(progress)
        match = re.fullmatch(r"/api/v1/annotations/book/(\d+)", path)
        if match:
            return self.send_json(self.state.annotations.get(int(match.group(1)), []))
        match = re.fullmatch(r"/api/v1/reading-sessions/book/(\d+)", path)
        if match:
            sessions = self.state.sessions.get(int(match.group(1)), [])
            page = int(query.get("page", ["0"])[0])
            size = int(query.get("size", ["100"])[0])
            total_pages = (len(sessions) + size - 1) // size
            return self.send_json({
                "content": sessions[page * size:(page + 1) * size],
                "page": {
                    "size": size,
                    "number": page,
                    "totalElements": len(sessions),
                    "totalPages": total_pages,
                },
            })
        return self.error(404, f"fixture route not found: {path}")

    def serve_cover(self, book_id: int) -> None:
        book = self.state.books_by_id.get(book_id)
        if not book:
            return self.error(404, "book not found")
        if book.get("coverAvailable") is False:
            return self.error(404, "cover not found")
        cover = book.get("cover")
        if cover and Path(cover["path"]).is_file():
            return self.send_bytes(Path(cover["path"]).read_bytes(), cover["contentType"])
        return self.send_bytes(synthetic_cover(book_id), "image/png")

    def serve_book(self, book_id: int, file_id: int | None) -> None:
        book = self.state.books_by_id.get(book_id)
        if not book:
            return self.error(404, "book file not found")
        if file_id is not None and int(book["fileId"]) != file_id:
            alternative = next(
                (item for item in book.get("alternativeFormats", []) if int(item["id"]) == file_id),
                None,
            )
            if alternative is None:
                return self.error(404, "book file not found")
            if alternative["bookType"] == "PDF":
                return self.send_bytes(
                    b"%PDF-1.4\n1 0 obj<</Type/Catalog>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n",
                    "application/pdf",
                )
        source = Path(book.get("sourcePath", ""))
        body = source.read_bytes() if source.is_file() else synthetic_epub(book)
        self.send_bytes(body, "application/epub+zip")

    def do_POST(self) -> None:
        path, query = self.parsed()
        if path == "/api/v1/auth/login":
            body = self.body()
            expected = self.state.fixture["credentials"]
            if body.get("username") != expected["username"] or body.get("password") != expected["password"]:
                return self.error(401, "invalid visual fixture credentials")
            return self.send_json({
                "accessToken": TOKEN,
                "refreshToken": REFRESH_TOKEN,
                "expires": 86400,
                "isDefaultPassword": False,
            })
        if path == "/api/v1/auth/refresh":
            if self.body().get("refreshToken") != REFRESH_TOKEN:
                return self.error(401, "invalid refresh token")
            return self.send_json({
                "accessToken": TOKEN,
                "refreshToken": REFRESH_TOKEN,
                "expires": 86400,
            })
        if path == "/__fixture/reset":
            self.state.reset()
            return self.send_json({"status": "reset"})
        if not self.require_auth(query):
            return
        if path == "/api/v1/annotations":
            body = self.body()
            book_id = int(body.get("bookId", 0))
            if book_id not in self.state.books_by_id:
                return self.error(404, "book not found")
            item = {
                **body,
                "id": self.state.next_annotation_id,
                "userId": 1,
                "createdAt": FIXED_TIME,
                "updatedAt": FIXED_TIME,
            }
            self.state.next_annotation_id += 1
            self.state.annotations[book_id].append(item)
            return self.send_json(item)
        if path == "/api/v1/reading-sessions":
            body = self.body()
            book_id = int(body.get("bookId", 0))
            if book_id not in self.state.books_by_id:
                return self.error(404, "book not found")
            item = {
                **body,
                "id": self.state.next_session_id,
                "bookTitle": self.state.books_by_id[book_id]["title"],
                "createdAt": FIXED_TIME,
            }
            self.state.next_session_id += 1
            self.state.sessions[book_id].append(item)
            # The real Grimmory controller deliberately returns 202 with no
            # representation. Clients must confirm a response-lost retry by
            # querying the book's sessions, not by relying on a POST body.
            return self.send_empty(HTTPStatus.ACCEPTED)
        return self.error(404, f"fixture route not found: {path}")

    def do_PUT(self) -> None:
        path, query = self.parsed()
        if not self.require_auth(query):
            return
        match = re.fullmatch(r"/api/v1/app/books/(\d+)/progress", path)
        if match:
            book_id = int(match.group(1))
            if book_id not in self.state.progress:
                return self.error(404, "book not found")
            body = self.body()
            if "fileProgress" in body:
                file_progress = body["fileProgress"]
                self.state.progress[book_id] = {"epubProgress": {"percentage": file_progress.get("progressPercent"), "cfi": file_progress.get("positionData")}}
            else:
                self.state.progress[book_id] = body
            return self.send_empty(HTTPStatus.OK)
        match = re.fullmatch(r"/api/v1/annotations/(\d+)", path)
        if match:
            annotation_id = int(match.group(1))
            for items in self.state.annotations.values():
                for item in items:
                    if item["id"] == annotation_id:
                        item.update(self.body())
                        item["updatedAt"] = FIXED_TIME
                        return self.send_json(item)
            return self.error(404, "annotation not found")
        return self.error(404, f"fixture route not found: {path}")

    def do_DELETE(self) -> None:
        path, query = self.parsed()
        if not self.require_auth(query):
            return
        match = re.fullmatch(r"/api/v1/annotations/(\d+)", path)
        if match:
            annotation_id = int(match.group(1))
            for book_id, items in self.state.annotations.items():
                remaining = [item for item in items if item["id"] != annotation_id]
                if len(remaining) != len(items):
                    self.state.annotations[book_id] = remaining
                    return self.send_empty(HTTPStatus.NO_CONTENT)
            return self.error(404, "annotation not found")
        return self.error(404, f"fixture route not found: {path}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", type=Path, default=DEFAULT_FIXTURE)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--ready-file", type=Path)
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    fixture = json.loads(args.fixture.read_text(encoding="utf-8"))
    if len(fixture.get("books", [])) != 8:
        raise SystemExit("fixture must contain exactly eight books")
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.fixture_state = FixtureState(fixture)  # type: ignore[attr-defined]
    server.quiet = args.quiet  # type: ignore[attr-defined]
    host, port = server.server_address[:2]
    base_url = f"http://{host}:{port}"
    if args.ready_file:
        args.ready_file.parent.mkdir(parents=True, exist_ok=True)
        temporary = args.ready_file.with_suffix(args.ready_file.suffix + ".tmp")
        temporary.write_text(json.dumps({"url": base_url, "pid": __import__("os").getpid(), "books": 8}) + "\n", encoding="utf-8")
        temporary.replace(args.ready_file)
    print(base_url, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
