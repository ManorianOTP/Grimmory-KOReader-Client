#!/usr/bin/env python3
"""Compare the fast Grimmory fixture with a disposable full Grimmory server.

This compares both behaviour and the Grimmory v3.3.1 wire contract. Generated
IDs, timestamps, catalogue state, provider values, titles, paths and cover
bytes are allowed to differ, but endpoint status/content, every outer DTO key,
nested file/page shapes, and the fields consumed by the plugins are not. The
dedicated metadata lane owns exact provider-field values and legitimate
absences. The full-server runtime is private and the emitted report contains no
URL, credentials, titles, paths, tokens, or EPUB hashes.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import importlib.util
import json
from pathlib import Path
import re
from threading import Thread
from typing import Any, Iterator
import urllib.error
import urllib.request
import zipfile
import io


ROOT = Path(__file__).resolve().parents[2]
FIXTURE_MODULE = ROOT / "tests" / "emulator" / "grimmory_fixture_server.py"
FIXTURE_JSON = ROOT / "tests" / "emulator" / "grimmory_library_fixture.json"


class ParityError(RuntimeError):
    pass


SERVER_LOCAL_DATETIME = re.compile(
    r"^(?P<second>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})"
    r"(?P<fraction>\.\d{1,9})?(?P<offset>Z|[+-]\d{2}:\d{2})?$"
)
ANNOTATION_GENERATED_TIMESTAMPS = ("createdAt", "updatedAt")


@dataclass
class Response:
    status: int
    body: Any
    content_type: str
    raw: bytes


class Target:
    def __init__(self, name: str, base_url: str, username: str, password: str, book_id: int):
        self.name = name
        self.base_url = base_url.rstrip("/")
        self.username = username
        self.password = password
        self.book_id = int(book_id)
        self.token: str | None = None
        self.refresh_token: str | None = None
        self.file_id: int | None = None

    def request(
        self,
        path: str,
        method: str = "GET",
        body: dict[str, Any] | None = None,
        *,
        authenticated: bool = True,
    ) -> Response:
        payload = json.dumps(body).encode("utf-8") if body is not None else None
        headers = {"Accept": "application/json"}
        if body is not None:
            headers["Content-Type"] = "application/json"
        if authenticated and self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        request = urllib.request.Request(
            self.base_url + path,
            data=payload,
            headers=headers,
            method=method,
        )
        try:
            response = urllib.request.urlopen(request, timeout=30)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            raw = response.read()
            content_type = response.headers.get("Content-Type", "")
            parsed: Any = None
            if raw and "json" in content_type.lower():
                parsed = json.loads(raw)
            return Response(int(response.status), parsed, content_type, raw)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ParityError(message)


def first_exact_difference(expected: Any, actual: Any, path: str = "$") -> str | None:
    """Return the first exact recursive DTO difference with a stable path."""
    if type(expected) is not type(actual):
        return (
            f"{path}: type differs; expected {type(expected).__name__} "
            f"{expected!r}, got {type(actual).__name__} {actual!r}"
        )
    if isinstance(expected, dict):
        missing = sorted(set(expected) - set(actual))
        unexpected = sorted(set(actual) - set(expected))
        if missing or unexpected:
            return (
                f"{path}: keys differ; missing={missing!r}, "
                f"unexpected={unexpected!r}"
            )
        for key in sorted(expected):
            difference = first_exact_difference(
                expected[key], actual[key], f"{path}.{key}"
            )
            if difference:
                return difference
        return None
    if isinstance(expected, list):
        if len(expected) != len(actual):
            return f"{path}: length differs; expected {len(expected)}, got {len(actual)}"
        for index, (expected_item, actual_item) in enumerate(zip(expected, actual)):
            difference = first_exact_difference(
                expected_item, actual_item, f"{path}[{index}]"
            )
            if difference:
                return difference
        return None
    if expected != actual:
        return f"{path}: value differs; expected {expected!r}, got {actual!r}"
    return None


def require_exact_equal(expected: Any, actual: Any, name: str) -> None:
    difference = first_exact_difference(expected, actual)
    require(difference is None, f"{name}: {difference}")


def server_datetime_parts(value: Any, name: str) -> tuple[str, str | None, str]:
    """Validate a Grimmory ISO LocalDateTime and retain its wire-shape parts."""
    require_string(value, name, nonempty=True)
    match = SERVER_LOCAL_DATETIME.fullmatch(value)
    require(match is not None, f"{name} is not a strict ISO server datetime: {value!r}")
    second = match.group("second")
    try:
        datetime.strptime(second, "%Y-%m-%dT%H:%M:%S")
        offset = match.group("offset") or ""
        if offset and offset != "Z":
            # `fromisoformat` also rejects out-of-range numeric offsets.
            datetime.fromisoformat(second + offset)
    except ValueError as error:
        raise ParityError(f"{name} is not a valid server datetime: {value!r}") from error
    return second, match.group("fraction"), offset


def require_database_timestamp_roundtrip(
    emitted: Any, persisted: Any, name: str,
) -> None:
    """Allow only MariaDB DATETIME(0)'s proven fractional-second truncation.

    Grimmory v3.3.1 maps the annotation timestamps as Hibernate-generated
    LocalDateTime values into MariaDB columns declared as bare ``datetime``.
    The POST DTO is mapped from the in-memory entity and may therefore retain
    nanoseconds; a later GET is mapped from the DATETIME(0) row and has none.
    Calendar second and offset wire shape remain exact.
    """
    emitted_parts = server_datetime_parts(emitted, f"{name} emitted")
    persisted_parts = server_datetime_parts(persisted, f"{name} persisted")
    if emitted == persisted:
        return
    emitted_second, emitted_fraction, emitted_offset = emitted_parts
    persisted_second, persisted_fraction, persisted_offset = persisted_parts
    allowed = (
        emitted_second == persisted_second
        and emitted_offset == persisted_offset
        and emitted_fraction is not None
        and persisted_fraction is None
    )
    require(
        allowed,
        f"{name} differs beyond DATETIME(0) fractional-second truncation: "
        f"emitted={emitted!r}, persisted={persisted!r}; only removal of the "
        "emitted fractional seconds is allowed",
    )


def require_annotation_persistence_equal(
    emitted: dict[str, Any], persisted: dict[str, Any], name: str,
) -> None:
    """Compare an annotation DTO exactly except proven generated precision loss."""
    emitted_keys = set(emitted)
    persisted_keys = set(persisted)
    require(
        emitted_keys == persisted_keys,
        f"{name}: $. keys differ; missing={sorted(emitted_keys - persisted_keys)!r}, "
        f"unexpected={sorted(persisted_keys - emitted_keys)!r}",
    )
    for field in sorted(emitted):
        if field in ANNOTATION_GENERATED_TIMESTAMPS:
            require_database_timestamp_roundtrip(
                emitted[field], persisted[field], f"{name} $.{field}"
            )
        else:
            difference = first_exact_difference(
                emitted[field], persisted[field], f"$.{field}"
            )
            require(difference is None, f"{name}: {difference}")


def require_mapping(value: Any, name: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{name} must be an object")
    return value


def require_list(value: Any, name: str) -> list[Any]:
    require(isinstance(value, list), f"{name} must be an array")
    return value


def require_fields(value: Any, name: str, fields: tuple[str, ...]) -> dict[str, Any]:
    item = require_mapping(value, name)
    missing = [field for field in fields if field not in item]
    require(not missing, f"{name} missing fields: {', '.join(missing)}")
    return item


def require_exact_keys(
    value: Any,
    name: str,
    required: tuple[str, ...],
    optional: tuple[str, ...] = (),
) -> dict[str, Any]:
    item = require_mapping(value, name)
    required_set = set(required)
    allowed = required_set | set(optional)
    actual = set(item)
    missing = sorted(required_set - actual)
    unexpected = sorted(actual - allowed)
    require(not missing, f"{name} missing fields: {', '.join(missing)}")
    require(not unexpected, f"{name} has unexpected fields: {', '.join(unexpected)}")
    return item


def require_string(value: Any, name: str, *, nonempty: bool = False) -> None:
    require(isinstance(value, str), f"{name} must be a string")
    if nonempty:
        require(bool(value.strip()), f"{name} must be non-empty")


def require_number(value: Any, name: str) -> None:
    require(isinstance(value, (int, float)) and not isinstance(value, bool),
            f"{name} must be a number")


def require_unique_id(items: list[Any], expected_id: int, name: str) -> dict[str, Any]:
    """Return one exact identity, rejecting missing and duplicate DTOs."""
    matches = [
        require_mapping(item, f"{name}[{index}]")
        for index, item in enumerate(items)
        if isinstance(item, dict) and item.get("id") == expected_id
    ]
    require(len(matches) == 1,
            f"{name} must contain id {expected_id} exactly once; got {len(matches)}")
    return matches[0]


def require_annotation_fields(
    value: Any,
    name: str,
    expected: dict[str, Any],
    *,
    expected_id: int | None = None,
) -> dict[str, Any]:
    fields = (
        "bookId", "cfi", "chapterTitle", "color", "createdAt", "id",
        "note", "style", "text", "updatedAt", "userId",
    )
    item = require_exact_keys(value, name, fields)
    require_number(item["id"], f"{name}.id")
    require_number(item["userId"], f"{name}.userId")
    server_datetime_parts(item["createdAt"], f"{name}.createdAt")
    server_datetime_parts(item["updatedAt"], f"{name}.updatedAt")
    if expected_id is not None:
        require(int(item["id"]) == expected_id,
                f"{name}.id must remain {expected_id}")
    for field, wanted in expected.items():
        require(item[field] == wanted,
                f"{name}.{field} differs: expected {wanted!r}, got {item[field]!r}")
    return item


DETAIL_LOCK_FIELDS = (
    "abridged", "ageRating", "amazonRating", "amazonReviewCount", "asin",
    "audibleId", "audibleRating", "audibleReviewCount", "audiobookCover",
    "authors", "categories", "comicvineId", "contentRating", "cover",
    "description", "goodreadsId", "goodreadsRating", "goodreadsReviewCount",
    "googleId", "hardcoverBookId", "hardcoverId", "hardcoverRating",
    "hardcoverReviewCount", "isbn10", "isbn13", "language",
    "lubimyczytacId", "lubimyczytacRating", "moods", "narrator",
    "pageCount", "publishedDate", "publisher", "ranobedbId",
    "ranobedbRating", "reviews", "seriesName", "seriesNumber",
    "seriesTotal", "subtitle", "tags", "title",
)

PROVIDER_METADATA_FIELDS = (
    "abridged", "ageRating", "amazonRating", "amazonReviewCount", "asin",
    "audibleId", "audibleRating", "audibleReviewCount", "audiobookCover",
    "bookReviews", "categories", "comicvineId", "contentRating",
    "coverUpdatedOn", "description", "goodreadsId", "goodreadsRating",
    "goodreadsReviewCount", "googleId", "hardcoverBookId", "hardcoverId",
    "hardcoverRating", "hardcoverReviewCount", "isbn10", "isbn13",
    "lubimyczytacId", "lubimyczytacRating", "moods", "narrator",
    "pageCount", "publishedDate", "publisher", "ranobedbId",
    "ranobedbRating", "seriesName", "seriesNumber", "seriesTotal",
    "subtitle", "tags",
)

LIST_BOOK_FIELDS = (
    "addedOn", "id", "isPhysical", "libraryId", "libraryName", "metadata",
    "metadataMatchScore", "primaryFile",
)
DETAIL_BOOK_FIELDS = (
    "addedOn", "alternativeFormats", "id", "isPhysical", "libraryId",
    "libraryName", "libraryPath", "metadata", "metadataMatchScore",
    "primaryFile", "readStatus", "shelves", "supplementaryFiles",
)
BOOK_STATE_FIELDS = (
    "dateFinished", "epubProgress", "lastReadTime", "personalRating",
    "readStatus",
)
FILE_FIELDS = (
    "addedOn", "book", "bookId", "bookType", "extension", "fileName",
    "fileSizeKb", "fileSubPath", "folderBased", "id",
)


def canonical_metadata(raw: Any, *, detail: bool) -> dict[str, Any]:
    required = ("authors", "bookId", "categories", "language", "moods", "tags", "title")
    if detail:
        required += tuple(field + "Locked" for field in DETAIL_LOCK_FIELDS)
        optional = PROVIDER_METADATA_FIELDS
    else:
        required = ("allMetadataLocked", "authors", "bookId", "language", "title")
        optional = PROVIDER_METADATA_FIELDS
    metadata = require_exact_keys(raw, "book.metadata", required, optional)
    require_string(metadata["title"], "book.metadata.title", nonempty=True)
    require_number(metadata["bookId"], "book.metadata.bookId")
    require_string(metadata["language"], "book.metadata.language", nonempty=True)
    authors = require_list(metadata["authors"], "book.metadata.authors")
    require(bool(authors), "book.metadata.authors must not be empty")
    for index, author in enumerate(authors):
        require_string(author, f"book.metadata.authors[{index}]", nonempty=True)
    if detail:
        for field in ("categories", "moods", "tags"):
            values = require_list(metadata[field], f"book.metadata.{field}")
            require(all(isinstance(item, str) for item in values),
                    f"book.metadata.{field} entries must be strings")
        for field in DETAIL_LOCK_FIELDS:
            require(isinstance(metadata[field + "Locked"], bool),
                    f"book.metadata.{field}Locked must be boolean")
    else:
        require(isinstance(metadata["allMetadataLocked"], bool),
                "book.metadata.allMetadataLocked must be boolean")
    # Provider-owned optional values are purposefully not compared here. Their
    # exact values, covers and legitimate absences are asserted against the
    # ignored SHA-bound cache by the browser and KOReader metadata lanes.
    return {
        "contract": "detail-metadata" if detail else "list-metadata",
        "title": "string",
        "authors": "array-of-string",
        "bookId": "number",
        "language": "string",
        "providerBoundary": "validated-allowlist; values owned by metadata lane",
    }


def canonical_file(raw: Any, *, detail: bool, name: str = "book file") -> dict[str, Any]:
    required = FILE_FIELDS + (("filePath",) if detail else ())
    item = require_exact_keys(raw, name, required)
    for field in ("addedOn", "bookType", "extension", "fileName"):
        require_string(item[field], f"{name}.{field}", nonempty=True)
    require_string(item["fileSubPath"], f"{name}.fileSubPath")
    if detail:
        require_string(item["filePath"], f"{name}.filePath", nonempty=True)
    for field in ("id", "bookId", "fileSizeKb"):
        require_number(item[field], f"{name}.{field}")
    for field in ("book", "folderBased"):
        require(isinstance(item[field], bool), f"{name}.{field} must be boolean")
    return {field: ("boolean" if field in {"book", "folderBased"}
                    else "number" if field in {"id", "bookId", "fileSizeKb"}
                    else "string") for field in required}


def canonical_shelf(raw: Any, name: str = "shelf") -> dict[str, Any]:
    fields = ("bookCount", "icon", "iconType", "id", "name", "publicShelf", "userId")
    item = require_exact_keys(raw, name, fields)
    for field in ("bookCount", "id", "userId"):
        require_number(item[field], f"{name}.{field}")
    for field in ("icon", "iconType", "name"):
        require_string(item[field], f"{name}.{field}", nonempty=True)
    require(isinstance(item["publicShelf"], bool), f"{name}.publicShelf must be boolean")
    return {field: ("boolean" if field == "publicShelf"
                    else "number" if field in {"bookCount", "id", "userId"}
                    else "string") for field in fields}


def canonical_book(raw: Any, *, detail: bool) -> dict[str, Any]:
    required = DETAIL_BOOK_FIELDS if detail else LIST_BOOK_FIELDS
    optional = tuple(field for field in BOOK_STATE_FIELDS if field not in required)
    book = require_exact_keys(raw, "book", required, optional)
    for field in ("id", "libraryId", "metadataMatchScore"):
        require_number(book[field], f"book.{field}")
    require_string(book["addedOn"], "book.addedOn", nonempty=True)
    require_string(book["libraryName"], "book.libraryName", nonempty=True)
    require(isinstance(book["isPhysical"], bool), "book.isPhysical must be boolean")
    for field in ("dateFinished", "lastReadTime"):
        if field in book:
            require_string(book[field], f"book.{field}", nonempty=True)
    if "personalRating" in book:
        require_number(book["personalRating"], "book.personalRating")
    if "readStatus" in book:
        require_string(book["readStatus"], "book.readStatus", nonempty=True)
    if "epubProgress" in book:
        progress = require_exact_keys(
            book["epubProgress"], "book.epubProgress",
            ("cfi", "contentSourceProgressPercent", "href", "percentage",
             "ttsPositionCfi"),
        )
        require_string(progress["cfi"], "book.epubProgress.cfi", nonempty=True)
        require_number(progress["percentage"], "book.epubProgress.percentage")
        for field in ("contentSourceProgressPercent", "href", "ttsPositionCfi"):
            require(progress[field] is None or isinstance(progress[field], (str, int, float)),
                    f"book.epubProgress.{field} has invalid type")
    metadata = canonical_metadata(book["metadata"], detail=detail)
    primary = canonical_file(book["primaryFile"], detail=True, name="book.primaryFile")
    if detail:
        library_path = require_exact_keys(book["libraryPath"], "book.libraryPath", ("id",))
        require_number(library_path["id"], "book.libraryPath.id")
        require_string(book["readStatus"], "book.readStatus", nonempty=True)
        for field in ("alternativeFormats", "supplementaryFiles"):
            for index, item in enumerate(require_list(book[field], f"book.{field}")):
                canonical_file(item, detail=True, name=f"book.{field}[{index}]")
        for index, shelf in enumerate(require_list(book["shelves"], "book.shelves")):
            canonical_shelf(shelf, f"book.shelves[{index}]")
    return {
        "outerFields": sorted(required),
        "optionalCatalogueState": sorted(optional),
        "metadata": metadata,
        "primaryFile": primary,
        "detailCollections": "validated" if detail else "not-present",
    }


def canonical_books_page(raw: Any) -> dict[str, Any]:
    page = require_exact_keys(raw, "books page", ("content", "links", "page"))
    books = require_list(page["content"], "books page content")
    require(bool(books), "books page must not be empty")
    canonical_books = [canonical_book(book, detail=False) for book in books]
    require(all(item == canonical_books[0] for item in canonical_books),
            "books page contains mixed canonical Book list envelopes")
    links = require_list(page["links"], "books page links")
    require(bool(links), "books page links must not be empty")
    for index, link in enumerate(links):
        item = require_exact_keys(link, f"books page links[{index}]", ("href", "rel", "type"))
        for field in ("href", "rel", "type"):
            require_string(item[field], f"books page links[{index}].{field}")
    page_meta = require_exact_keys(
        page["page"], "books page metadata",
        ("cursor", "number", "size", "totalElements", "totalPages"),
    )
    require_string(page_meta["cursor"], "books page metadata.cursor")
    for field in ("number", "size", "totalElements", "totalPages"):
        require_number(page_meta[field], f"books page metadata.{field}")
    return {
        "outerFields": ["content", "links", "page"],
        "book": canonical_books[0],
        "link": {field: "string" for field in ("href", "rel", "type")},
        "page": {"cursor": "string", "number": "number", "size": "number",
                 "totalElements": "number", "totalPages": "number"},
    }


def normalized_book(raw: Any) -> dict[str, Any]:
    book = require_mapping(raw, "book")
    metadata = require_mapping(book.get("metadata"), "book.metadata")
    primary = require_fields(book.get("primaryFile"), "book.primaryFile", ("id", "bookType", "fileName"))
    title = metadata.get("title")
    authors = metadata.get("authors") or []
    require(isinstance(title, str) and bool(title.strip()), "book title must be non-empty")
    require(isinstance(authors, list), "book authors must be an array")
    require(isinstance(book.get("id"), int) and not isinstance(book.get("id"), bool),
            "book id must be an integer")
    require(isinstance(primary.get("id"), int) and not isinstance(primary.get("id"), bool),
            "book.primaryFile.id must be an integer")
    require_string(primary.get("bookType"), "book.primaryFile.bookType", nonempty=True)
    require_string(primary.get("fileName"), "book.primaryFile.fileName", nonempty=True)
    return {
        "id": True,
        "title": "string",
        "authors": "array",
        "primaryFile": {
            "id": True,
            "bookType": True,
            "fileName": True,
        },
        "metadata": "object",
    }


def value_shape(value: Any) -> Any:
    """Return an exact recursive key/type shape, normalizing generated values."""
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, (int, float)):
        return "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, dict):
        return {
            "type": "object",
            "fields": {key: value_shape(value[key]) for key in sorted(value)},
        }
    if isinstance(value, list):
        unique: dict[str, Any] = {}
        for item in value:
            item_shape = value_shape(item)
            unique[json.dumps(item_shape, sort_keys=True)] = item_shape
        return {"type": "array", "items": [unique[key] for key in sorted(unique)]}
    raise ParityError(f"unsupported response value type: {type(value).__name__}")


def response_shape(response: Response) -> dict[str, Any]:
    if not response.raw:
        content = "empty"
    elif "json" in response.content_type.lower():
        content = "json"
    else:
        content = "binary"
    return {
        "status": response.status,
        "content": content,
        "body": value_shape(response.body) if content == "json" else None,
    }


def expect_status(target: Target, name: str, response: Response, status: int) -> None:
    require(response.status == status, f"{target.name} {name}: expected HTTP {status}, got {response.status}")


def exercise(target: Target) -> dict[str, Any]:
    observations: dict[str, Any] = {}

    health = target.request("/api/v1/healthcheck", authenticated=False)
    expect_status(target, "health", health, 200)
    require_fields(health.body, "health", ("status", "message", "data"))
    observations["health"] = response_shape(health)

    unauthorised = target.request("/api/v1/books/page?page=0&size=1", authenticated=False)
    expect_status(target, "unauthorised books", unauthorised, 401)
    require_exact_keys(
        unauthorised.body, "unauthorised error",
        ("error", "path", "status", "timestamp"),
    )
    observations["unauthorised"] = response_shape(unauthorised)

    login = target.request(
        "/api/v1/auth/login",
        "POST",
        {"username": target.username, "password": target.password},
        authenticated=False,
    )
    expect_status(target, "login", login, 200)
    login_body = require_fields(login.body, "login", ("accessToken", "refreshToken"))
    require(isinstance(login_body["accessToken"], str) and login_body["accessToken"], "login access token missing")
    require(isinstance(login_body["refreshToken"], str) and login_body["refreshToken"], "login refresh token missing")
    target.token = login_body["accessToken"]
    target.refresh_token = login_body["refreshToken"]
    observations["login"] = response_shape(login)

    refresh = target.request(
        "/api/v1/auth/refresh",
        "POST",
        {"refreshToken": target.refresh_token},
        authenticated=False,
    )
    expect_status(target, "refresh", refresh, 200)
    refreshed = require_fields(refresh.body, "refresh", ("accessToken", "refreshToken"))
    target.token = refreshed["accessToken"]
    observations["refresh"] = response_shape(refresh)

    version = target.request("/api/v1/version")
    expect_status(target, "version", version, 200)
    require(isinstance(version.body, (dict, str)), "version response must be an object or string")
    observations["version"] = response_shape(version)

    libraries = target.request("/api/v1/libraries")
    expect_status(target, "libraries", libraries, 200)
    library_items = require_list(libraries.body, "libraries")
    require(bool(library_items), "libraries must not be empty")
    library_fields = (
        "allowedFormats", "formatPriority", "id", "metadataSource", "name",
        "organizationMode", "paths", "watch",
    )
    for index, library in enumerate(library_items):
        item = require_exact_keys(library, f"libraries[{index}]", library_fields)
        for field in ("allowedFormats", "formatPriority"):
            values = require_list(item[field], f"libraries[{index}].{field}")
            require(all(isinstance(value, str) for value in values),
                    f"libraries[{index}].{field} entries must be strings")
        for path_index, library_path in enumerate(
            require_list(item["paths"], f"libraries[{index}].paths")
        ):
            path_item = require_exact_keys(
                library_path, f"libraries[{index}].paths[{path_index}]", ("id", "path")
            )
            require_number(path_item["id"], "library path id")
            require_string(path_item["path"], "library path", nonempty=True)
    observations["libraries"] = response_shape(libraries)

    shelves = target.request("/api/v1/shelves")
    expect_status(target, "shelves", shelves, 200)
    shelf_items = require_list(shelves.body, "shelves")
    require(bool(shelf_items), "shelves must not be empty")
    for index, shelf in enumerate(shelf_items):
        canonical_shelf(shelf, f"shelves[{index}]")
    observations["shelves"] = response_shape(shelves)

    page = target.request("/api/v1/books/page?page=0&size=100")
    expect_status(target, "books page", page, 200)
    page_body = require_mapping(page.body, "books page")
    books = require_list(page_body["content"], "books page content")
    target_list_book = require_unique_id(books, target.book_id, "books page content")
    observations["booksPage"] = {
        "status": page.status,
        "content": "json",
        "wire": canonical_books_page(page.body),
        "consumer": normalized_book(target_list_book),
    }

    detail = target.request(f"/api/v1/books/{target.book_id}?withDescription=true")
    expect_status(target, "book detail", detail, 200)
    observations["bookDetail"] = {
        "status": detail.status,
        "content": "json",
        "wire": canonical_book(detail.body, detail=True),
        "consumer": normalized_book(detail.body),
    }

    files = target.request(f"/api/v1/books/{target.book_id}/files?isBook=true")
    expect_status(target, "book files", files, 200)
    file_items = require_list(files.body, "book files")
    require(bool(file_items), "book files must not be empty")
    for index, item in enumerate(file_items):
        canonical_file(item, detail=False, name=f"book files[{index}]")
    detail_body = require_mapping(detail.body, "book detail")
    detail_primary = require_mapping(detail_body.get("primaryFile"), "book detail primary file")
    require_number(detail_primary.get("id"), "book detail primary file id")
    primary = require_unique_id(file_items, int(detail_primary["id"]), "book files")
    target.file_id = int(primary["id"])
    observations["bookFiles"] = response_shape(files)

    # Grimmory's primary-file route is book-scoped. The `/files/{id}` route is
    # reserved for additional/alternative files and rejects a primary ID.
    download = target.request(f"/api/v1/books/{target.book_id}/download")
    expect_status(target, "download", download, 200)
    require(len(download.raw) > 1000, "downloaded EPUB is implausibly small")
    require(zipfile.is_zipfile(io.BytesIO(download.raw)), "download is not a readable EPUB ZIP")
    observations["download"] = {"status": download.status, "format": "epub-zip"}

    cfi = "epubcfi(/6/4!/4/2:0)"
    progress = target.request(
        f"/api/v1/app/books/{target.book_id}/progress",
        "PUT",
        {"fileProgress": {"bookFileId": target.file_id, "positionData": cfi, "progressPercent": 37.25}},
    )
    expect_status(target, "progress update", progress, 200)
    fetched_progress = target.request(f"/api/v1/app/books/{target.book_id}/progress")
    expect_status(target, "progress read", fetched_progress, 200)
    progress_body = require_exact_keys(
        fetched_progress.body, "progress",
        ("epubProgress", "lastReadTime", "readProgress", "readStatus"),
    )
    epub_progress = require_exact_keys(
        progress_body["epubProgress"], "EPUB progress",
        ("percentage", "cfi", "href", "updatedAt"),
    )
    require(epub_progress["percentage"] == 37.25,
            "progress percentage must exactly equal the submitted value")
    require(progress_body["readProgress"] == 37.25,
            "progress readProgress must exactly equal the submitted value")
    require(epub_progress["cfi"] == cfi, "progress CFI did not round-trip")
    require(epub_progress["href"] is None,
            "progress href must stay absent when the request omitted it")
    require(progress_body["readStatus"] == "READING",
            "progress update must set the exact READING status")
    require_string(progress_body["lastReadTime"], "progress.lastReadTime", nonempty=True)
    require_string(epub_progress["updatedAt"], "progress.epubProgress.updatedAt", nonempty=True)
    observations["progress"] = {
        "put": response_shape(progress),
        "get": response_shape(fetched_progress),
        "roundTrip": True,
    }

    created_values = {
        "bookId": target.book_id,
        "cfi": cfi,
        "chapterTitle": "Contract parity",
        "text": "Contract parity highlight",
        "color": "#FFFF00",
        "style": "highlight",
        "note": "created",
    }
    annotation = target.request(
        "/api/v1/annotations",
        "POST",
        created_values,
    )
    expect_status(target, "annotation create", annotation, 200)
    annotation_body = require_annotation_fields(annotation.body, "annotation", created_values)
    annotation_id = int(annotation_body["id"])
    listed = target.request(f"/api/v1/annotations/book/{target.book_id}")
    expect_status(target, "annotation list", listed, 200)
    listed_items = require_list(listed.body, "annotations")
    listed_created = require_unique_id(listed_items, annotation_id, "annotations")
    require_annotation_fields(
        listed_created, "listed annotation", created_values, expected_id=annotation_id,
    )
    require_annotation_persistence_equal(
        annotation_body,
        listed_created,
        "annotation POST-to-list persistence",
    )
    updated = target.request(f"/api/v1/annotations/{annotation_id}", "PUT", {"note": "updated", "color": "#00FF00", "style": "underline"})
    expect_status(target, "annotation update", updated, 200)
    updated_values = dict(created_values)
    updated_values.update({"note": "updated", "color": "#00FF00", "style": "underline"})
    updated_body = require_annotation_fields(
        updated.body, "updated annotation", updated_values,
        expected_id=annotation_id,
    )
    require_database_timestamp_roundtrip(
        annotation_body["createdAt"],
        updated_body["createdAt"],
        "annotation update $.createdAt",
    )
    deleted = target.request(f"/api/v1/annotations/{annotation_id}", "DELETE")
    expect_status(target, "annotation delete", deleted, 204)
    after_delete = target.request(f"/api/v1/annotations/book/{target.book_id}")
    expect_status(target, "annotation list after delete", after_delete, 200)
    after_delete_items = require_list(after_delete.body, "annotations after delete")
    require(not any(
        isinstance(item, dict) and item.get("id") == annotation_id
        for item in after_delete_items
    ), "deleted annotation is still listed")
    observations["annotations"] = {
        "post": response_shape(annotation),
        # Other consumers may legitimately have left annotations on this
        # shared acceptance stack. Compare the exact created-item shape while
        # still requiring the list endpoint itself to be a JSON array.
        "get": {
            "status": listed.status,
            "content": "json-array",
            "item": value_shape(listed_created),
        },
        "put": response_shape(updated),
        "delete": response_shape(deleted),
        "afterDelete": {
            "status": after_delete.status,
            "content": "json-array",
            "deletedIdentityCount": 0,
        },
    }

    now = datetime.now(timezone.utc).replace(microsecond=0)
    session = target.request(
        "/api/v1/reading-sessions",
        "POST",
        {
            "bookId": target.book_id,
            "bookType": "EPUB",
            "startTime": (now - timedelta(seconds=60)).isoformat().replace("+00:00", "Z"),
            "endTime": now.isoformat().replace("+00:00", "Z"),
            "durationSeconds": 60,
            "startProgress": 37.25,
            "endProgress": 38.0,
            "progressDelta": 0.75,
            "startLocation": cfi,
            "endLocation": "epubcfi(/6/4!/4/4:0)",
        },
    )
    expect_status(target, "reading session create", session, 202)
    require(session.body is None and session.raw == b"", "reading session POST must return an empty 202 response")
    sessions = target.request(f"/api/v1/reading-sessions/book/{target.book_id}?page=0&size=100")
    expect_status(target, "reading sessions", sessions, 200)
    sessions_body = require_fields(sessions.body, "reading sessions", ("content", "page"))
    session_items = require_list(sessions_body["content"], "reading sessions content")
    require(any(
        int(item.get("durationSeconds", -1)) == 60
        and item.get("startLocation") == cfi
        and item.get("endLocation") == "epubcfi(/6/4!/4/4:0)"
        for item in session_items
    ), "created reading session was not listed")
    require_fields(sessions_body["page"], "reading sessions page", ("number", "size", "totalElements", "totalPages"))
    observations["sessions"] = {
        "post": response_shape(session),
        "get": response_shape(sessions),
        "page": "spring-page",
    }
    return observations


def load_fixture_module():
    spec = importlib.util.spec_from_file_location("grimmory_parity_fixture", FIXTURE_MODULE)
    if spec is None or spec.loader is None:
        raise ParityError("unable to load fixture server")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@contextmanager
def fixture_target() -> Iterator[Target]:
    module = load_fixture_module()
    fixture = json.loads(FIXTURE_JSON.read_text(encoding="utf-8"))
    server = module.ThreadingHTTPServer(("127.0.0.1", 0), module.Handler)
    server.fixture_state = module.FixtureState(fixture)
    server.quiet = True
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        credentials = fixture["credentials"]
        yield Target(
            "fixture",
            f"http://127.0.0.1:{server.server_port}",
            credentials["username"],
            credentials["password"],
            int(fixture["books"][0]["id"]),
        )
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def real_targets(runtime_path: Path) -> list[Target]:
    runtime = json.loads(runtime_path.read_text(encoding="utf-8"))
    books = runtime.get("books") or []
    synthetic = [book for book in books if book.get("kind") == "synthetic"]
    private = [book for book in books if book.get("kind") in {"real", "private", "private-real-epub"}]
    require(len(synthetic) == 1, f"full-server runtime must have one synthetic control book, found {len(synthetic)}")
    require(len(private) == 8, f"full-server runtime must have eight private EPUB companions, found {len(private)}")
    return [
        Target(
            "full-server synthetic" if book.get("kind") == "synthetic" else "full-server private EPUB",
            str(runtime.get("baseUrl") or ""),
            str(runtime.get("username") or ""),
            str(runtime.get("password") or ""),
            int(book["serverBookId"]),
        )
        for book in [*synthetic, *private]
    ]


def compare(fixture: dict[str, Any], real: dict[str, Any]) -> None:
    difference = first_exact_difference(fixture, real)
    require(
        difference is None,
        "fixture/full-server observations differ at " + str(difference) + ":\n"
        + json.dumps({"fixture": fixture, "fullServer": real}, indent=2, sort_keys=True),
    )


def write_report(
    path: Path, observations: dict[str, Any], full_server_books: int = 9,
    source_fingerprint: str | None = None,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps({
        "schemaVersion": 1,
        "status": "passed",
        "targets": ["fixture", "full-server"],
        "fullServerBooks": full_server_books,
        "pairing": "one synthetic control plus eight private real EPUB companions",
        "sourceFingerprint": source_fingerprint,
        "observations": observations,
    }, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    runtime_path = args.runtime.resolve()
    runtime = json.loads(runtime_path.read_text(encoding="utf-8"))
    source_fingerprint = runtime.get("sourceFingerprint")
    require(
        isinstance(source_fingerprint, str) and bool(source_fingerprint),
        "full-server runtime must include the acceptance source fingerprint",
    )
    with fixture_target() as fixture:
        fixture_observations = exercise(fixture)
    targets = real_targets(runtime_path)
    for target in targets:
        compare(fixture_observations, exercise(target))
    if args.output:
        write_report(
            args.output.resolve(), fixture_observations, len(targets),
            source_fingerprint,
        )
    print(
        "server contract parity passed: "
        f"{len(fixture_observations)} workflows x {len(targets)} full-server books"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, ParityError, urllib.error.URLError) as error:
        print(f"server-contract-parity: {error}", file=__import__("sys").stderr)
        raise SystemExit(1) from error
