#!/usr/bin/env python3
"""Capture and replay real Grimmory metadata without re-querying providers.

The cache is deliberately private.  It contains titles, descriptions, reviews,
provider identifiers, cover bytes, and source EPUB digests, so this tool only
writes it below the repository's ignored ``build`` directory (or outside the
repository).

Capture happens *after* a human or browser journey has selected and saved a
real provider result in Grimmory's metadata UI.  Replay uses the same supported
metadata and cover endpoints as that UI; it never edits MariaDB or EPUB files.
"""

from __future__ import annotations

import argparse
import copy
import datetime as dt
import hashlib
import io
import json
import mimetypes
from pathlib import Path
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from typing import Any, Iterable

from PIL import Image, ImageOps


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CACHE = ROOT / "build" / "grimmory-compatibility" / "private-metadata-cache"
SCHEMA_VERSION = 1

# These are persisted by BookMetadataUpdater in Grimmory v3.3.1.  Transient
# candidate-only fields (provider, thumbnailUrl) and database identities are
# intentionally not replayed.
REPLAY_FIELDS = (
    "title", "subtitle", "publisher", "publishedDate", "description",
    "seriesName", "seriesNumber", "seriesTotal", "isbn13", "isbn10",
    "pageCount", "language", "narrator", "abridged", "asin",
    "amazonRating", "amazonReviewCount", "goodreadsId", "comicvineId",
    "goodreadsRating", "goodreadsReviewCount", "hardcoverId",
    "hardcoverBookId", "hardcoverRating", "hardcoverReviewCount",
    "lubimyczytacRating", "googleId", "lubimyczytacId", "ranobedbId",
    "ranobedbRating", "audibleId", "audibleRating", "audibleReviewCount",
    "authors", "categories", "moods", "tags", "bookReviews", "isFixedLayout",
    "ageRating", "contentRating",
)

PROVIDER_IDENTIFIERS = {
    "Amazon": "asin",
    "GoodReads": "goodreadsId",
    "Google": "googleId",
    "Hardcover": "hardcoverId",
    "Comicvine": "comicvineId",
    "Douban": "doubanId",
    "Lubimyczytac": "lubimyczytacId",
    "Ranobedb": "ranobedbId",
    "Audible": "audibleId",
}


def canonical_provider(value: Any) -> str | None:
    if value is None:
        return None
    raw = str(value).strip()
    return next(
        (provider for provider in PROVIDER_IDENTIFIERS if provider.casefold() == raw.casefold()),
        raw or None,
    )

VOLATILE_METADATA_FIELDS = {
    "bookId", "coverUpdatedOn", "audiobookCoverUpdatedOn", "thumbnailUrl",
}

VOLATILE_BOOK_FIELDS = {
    "id", "addedOn", "lastReadTime", "dateFinished", "metadataMatchScore",
    "primaryFile", "alternativeFormats", "supplementaryFiles", "shelves",
    "pdfProgress", "epubProgress", "cbxProgress", "audiobookProgress",
    "koreaderProgress", "koboProgress",
}


class CacheError(RuntimeError):
    pass


def canonical_json(value: Any) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
    ).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise CacheError(f"cannot read JSON {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise CacheError(f"expected a JSON object in {path}")
    return value


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(
        json.dumps(value, indent=2, ensure_ascii=False, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def assert_private_cache_location(path: Path) -> None:
    resolved = path.resolve()
    try:
        relative = resolved.relative_to(ROOT.resolve())
    except ValueError:
        return
    if not relative.parts or relative.parts[0] != "build":
        raise CacheError(
            "metadata caches contain private/copyrighted data and must live "
            f"below {ROOT / 'build'} (got {resolved})"
        )


def first_present(value: dict[str, Any], paths: Iterable[tuple[str, ...]]) -> Any:
    for keys in paths:
        current: Any = value
        for key in keys:
            if not isinstance(current, dict) or key not in current:
                break
            current = current[key]
        else:
            if current is not None:
                return current
    return None


def runtime_connection(runtime: dict[str, Any]) -> tuple[str, str, str]:
    base = first_present(runtime, (
        ("baseUrl",), ("serverUrl",), ("grimmory", "baseUrl"),
        ("server", "baseUrl"),
    ))
    username = first_present(runtime, (
        ("username",), ("credentials", "username"),
        ("grimmory", "username"), ("server", "username"),
    ))
    password = first_present(runtime, (
        ("password",), ("credentials", "password"),
        ("grimmory", "password"), ("server", "password"),
    ))
    if not all(isinstance(item, str) and item for item in (base, username, password)):
        raise CacheError("runtime must contain baseUrl, username, and password")
    return base.rstrip("/"), username, password


def metadata_cache_identity(source_sha: Any, alias: Any, kind: Any) -> str:
    """Bind private books to bytes, but generated controls to stable aliases.

    Provider metadata belongs to the exact private EPUB that was selected in
    Grimmory, so real-book cache keys must remain content hashes. Synthetic
    controls are generated by this harness and contain deterministic stress
    metadata rather than provider truth; harmless generator/privacy edits can
    change their ZIP bytes without invalidating that metadata contract.
    """
    if str(kind or "").lower() == "synthetic" or source_sha is None:
        if alias is None or str(alias) == "":
            raise CacheError("synthetic metadata cache identity requires an alias")
        return f"synthetic:{alias}"
    return str(source_sha)


def runtime_books(runtime: dict[str, Any]) -> list[dict[str, Any]]:
    candidates = [
        runtime.get("books"), runtime.get("importedBooks"),
        (runtime.get("sourceManifest") or {}).get("books")
        if isinstance(runtime.get("sourceManifest"), dict) else None,
    ]
    books = next((item for item in candidates if isinstance(item, list)), None)
    if books is None:
        raise CacheError("runtime must contain books[] or importedBooks[]")
    output: list[dict[str, Any]] = []
    for index, item in enumerate(books):
        if not isinstance(item, dict):
            raise CacheError(f"runtime book {index} is not an object")
        server_id = first_present(item, (
            ("serverBookId",), ("bookId",), ("server", "bookId"),
        ))
        source_sha = first_present(item, (
            ("sourceSha256",), ("sha256",), ("source", "sha256"),
        ))
        alias = first_present(item, (
            ("alias",), ("sourceBookId",), ("fixtureBookId",),
            ("sourceBasename",), ("basename",),
        ))
        if server_id is None:
            raise CacheError(f"runtime book {index} has no serverBookId")
        if source_sha is None and alias is None:
            raise CacheError(f"runtime book {index} has neither sourceSha256 nor alias")
        normalized = dict(item)
        normalized["serverBookId"] = int(server_id)
        normalized["cacheKey"] = metadata_cache_identity(
            source_sha, alias, item.get("kind"))
        normalized["sourceSha256"] = source_sha
        normalized["alias"] = str(alias or source_sha[:12])
        output.append(normalized)
    keys = [item["cacheKey"] for item in output]
    if len(keys) != len(set(keys)):
        raise CacheError("runtime contains duplicate source identities")
    return output


class GrimmoryClient:
    def __init__(self, base_url: str, username: str, password: str):
        self.base_url = base_url
        self.token = self._json(
            "/api/v1/auth/login", method="POST",
            body={"username": username, "password": password},
            authenticate=False,
        )["accessToken"]

    def _open(
        self, path: str, *, method: str = "GET", body: Any = None,
        headers: dict[str, str] | None = None, authenticate: bool = True,
    ) -> tuple[bytes, dict[str, str]]:
        request_headers = dict(headers or {})
        data = None
        if body is not None:
            data = canonical_json(body)
            request_headers["Content-Type"] = "application/json"
        if authenticate:
            request_headers["Authorization"] = f"Bearer {self.token}"
        request = urllib.request.Request(
            self.base_url + path, data=data, headers=request_headers, method=method,
        )
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                return response.read(), dict(response.headers.items())
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")[:1000]
            raise CacheError(f"Grimmory HTTP {exc.code} at {path}: {detail}") from exc
        except urllib.error.URLError as exc:
            raise CacheError(f"cannot reach Grimmory at {self.base_url}: {exc}") from exc

    def _json(self, path: str, **kwargs: Any) -> Any:
        raw, _ = self._open(path, **kwargs)
        try:
            return json.loads(raw) if raw else None
        except json.JSONDecodeError as exc:
            raise CacheError(f"invalid JSON from Grimmory at {path}") from exc

    def book(self, book_id: int) -> dict[str, Any]:
        value = self._json(f"/api/v1/books/{book_id}?withDescription=true")
        if not isinstance(value, dict) or not isinstance(value.get("metadata"), dict):
            raise CacheError(f"book {book_id} response has no metadata object")
        return value

    def recommendations(self, book_id: int) -> list[dict[str, Any]]:
        value = self._json(f"/api/v1/books/{book_id}/recommendations")
        return value if isinstance(value, list) else []

    def cover(self, book_id: int) -> tuple[bytes, str] | None:
        # Grimmory's media controller uses a query token.  It is never written
        # to logs or reports by this tool.
        path = (
            f"/api/v1/media/book/{book_id}/thumbnail?token="
            f"{urllib.parse.quote(self.token, safe='')}"
        )
        try:
            raw, headers = self._open(path, authenticate=False)
        except CacheError as exc:
            if "HTTP 404" in str(exc):
                return None
            raise
        if not raw:
            return None
        return raw, headers.get("Content-Type", "application/octet-stream")

    def put_metadata(self, book_id: int, metadata: dict[str, Any]) -> None:
        self._json(
            f"/api/v1/books/{book_id}/metadata?mergeCategories=false&replaceMode=REPLACE_ALL",
            method="PUT", body={"metadata": metadata, "clearFlags": {}},
        )

    def upload_cover(self, book_id: int, cover: bytes, filename: str, mime: str) -> None:
        boundary = "----grimmory-metadata-cache-" + uuid.uuid4().hex
        prefix = (
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'
            f"Content-Type: {mime}\r\n\r\n"
        ).encode("ascii")
        data = prefix + cover + f"\r\n--{boundary}--\r\n".encode("ascii")
        self._upload_raw(book_id, data, boundary)

    def _upload_raw(self, book_id: int, data: bytes, boundary: str) -> None:
        request = urllib.request.Request(
            self.base_url + f"/api/v1/books/{book_id}/metadata/cover/upload",
            data=data,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Content-Type": f"multipart/form-data; boundary={boundary}",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                response.read()
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")[:1000]
            raise CacheError(
                f"cover upload failed for book {book_id}: HTTP {exc.code}: {detail}"
            ) from exc


def image_extension(value: bytes) -> tuple[str, str]:
    if value.startswith(b"\xff\xd8"):
        return "jpg", "image/jpeg"
    if value.startswith(b"\x89PNG\r\n\x1a\n"):
        return "png", "image/png"
    if value.startswith((b"GIF87a", b"GIF89a")):
        return "gif", "image/gif"
    if value.startswith(b"RIFF") and value[8:12] == b"WEBP":
        return "webp", "image/webp"
    raise CacheError("Grimmory cover response is not JPEG, PNG, GIF, or WebP")


def cover_visual_fingerprint(value: bytes) -> dict[str, Any]:
    """Return a codec-stable fingerprint for a cover.

    Grimmory intentionally decodes and re-encodes an uploaded thumbnail.  A
    byte SHA therefore changes during legitimate cache replay.  A 256-bit
    difference hash verifies the actual image while tolerating tiny JPEG
    rounding changes; dimensions and aspect ratio guard against a wrong cover
    with a coincidentally similar low-frequency pattern.
    """
    try:
        with Image.open(io.BytesIO(value)) as opened:
            normalized = ImageOps.exif_transpose(opened).convert("L")
            width, height = normalized.size
            resized = normalized.resize((17, 16), Image.Resampling.LANCZOS)
            pixels = list(resized.getdata())
    except (OSError, ValueError) as exc:
        raise CacheError(f"cannot decode Grimmory cover: {exc}") from exc
    bits = 0
    for y in range(16):
        row = y * 17
        for x in range(16):
            bits = (bits << 1) | int(pixels[row + x] > pixels[row + x + 1])
    return {
        "differenceHash256": f"{bits:064x}",
        "width": width,
        "height": height,
        "aspectRatio": round(width / height, 6) if height else None,
    }


def hash_distance(left: str, right: str) -> int:
    return (int(left, 16) ^ int(right, 16)).bit_count()


def clean_review(value: Any) -> Any:
    if not isinstance(value, dict):
        return value
    return {key: child for key, child in value.items() if key != "id"}


def replay_metadata(metadata: dict[str, Any]) -> dict[str, Any]:
    output = {
        field: copy.deepcopy(metadata.get(field))
        for field in REPLAY_FIELDS
        if field in metadata
    }
    if isinstance(output.get("bookReviews"), list):
        output["bookReviews"] = [clean_review(item) for item in output["bookReviews"]]
    return output


def stable_metadata(metadata: dict[str, Any]) -> dict[str, Any]:
    output = replay_metadata(metadata)
    for field in ("categories", "moods", "tags"):
        if isinstance(output.get(field), list):
            output[field] = sorted(output[field], key=lambda item: str(item).casefold())
    return output


def project_metadata(
    metadata: dict[str, Any], cover: dict[str, Any] | None,
) -> dict[str, Any]:
    reviews = metadata.get("bookReviews")
    if not isinstance(reviews, list):
        reviews = []
    return {
        "title": metadata.get("title"),
        "subtitle": metadata.get("subtitle"),
        "authors": metadata.get("authors") or [],
        "series": {
            "name": metadata.get("seriesName"),
            "number": metadata.get("seriesNumber"),
            "total": metadata.get("seriesTotal"),
        },
        "publisher": metadata.get("publisher"),
        "publishedDate": metadata.get("publishedDate"),
        "language": metadata.get("language"),
        "genres": sorted(metadata.get("categories") or [], key=str.casefold),
        "moods": sorted(metadata.get("moods") or [], key=str.casefold),
        "tags": sorted(metadata.get("tags") or [], key=str.casefold),
        "description": metadata.get("description"),
        "pageCount": metadata.get("pageCount"),
        "identifiers": {
            name: metadata.get(field) for name, field in PROVIDER_IDENTIFIERS.items()
        } | {"isbn10": metadata.get("isbn10"), "isbn13": metadata.get("isbn13")},
        "ratings": {
            "amazon": metadata.get("amazonRating"),
            "amazonReviewCount": metadata.get("amazonReviewCount"),
            "goodreads": metadata.get("goodreadsRating"),
            "goodreadsReviewCount": metadata.get("goodreadsReviewCount"),
            "hardcover": metadata.get("hardcoverRating"),
            "hardcoverReviewCount": metadata.get("hardcoverReviewCount"),
            "personal": metadata.get("rating"),
        },
        "reviews": [clean_review(item) for item in reviews],
        # The source SHA is provenance, not a replay assertion: Grimmory
        # re-encodes uploads.  Browser tests use the visual fingerprint below.
        "coverPresent": cover is not None,
        "coverSourceSha256": cover.get("sha256") if cover else None,
        "coverVisualFingerprint": copy.deepcopy(cover.get("visualFingerprint"))
        if cover else None,
    }


def project_recommendations(value: list[dict[str, Any]]) -> list[dict[str, Any]]:
    output = []
    for item in value:
        book = item.get("book") if isinstance(item, dict) else None
        if not isinstance(book, dict):
            continue
        metadata = book.get("metadata") if isinstance(book.get("metadata"), dict) else {}
        output.append({
            "title": metadata.get("title") or book.get("title"),
            "authors": metadata.get("authors") or [],
            "seriesName": metadata.get("seriesName"),
            "similarityScore": item.get("similarityScore"),
        })
    return output


def project_koreader_metadata(
    metadata: dict[str, Any], expected: dict[str, Any],
) -> dict[str, Any]:
    """Expose the exact Grimmory DTO names consumed by the production plugin.

    The browser projection deliberately uses presentation names such as
    ``genres`` and nested ``ratings``.  KOReader receives Grimmory's native
    metadata object, where those same values are ``categories``,
    ``goodreadsRating``, ``seriesName``, and so on.  Keeping this second,
    explicit projection in the private runtime prevents acceptance tests from
    silently inventing their own field translation.
    """
    projected = {
        field: copy.deepcopy(metadata.get(field)) for field in REPLAY_FIELDS
    }
    projected.update({
        "personalRating": expected.get("personalRating"),
        "metadataMatchScore": expected.get("metadataMatchScore"),
        "recommendations": copy.deepcopy(expected.get("recommendations") or []),
        "coverPresent": expected.get("coverPresent") is True,
        "coverVisualFingerprint": copy.deepcopy(
            expected.get("coverVisualFingerprint")
        ),
    })
    projected["presence"] = presence_contract(projected)
    return projected


def presence_contract(value: Any) -> Any:
    """Encode both expected presence and expected absence for UI assertions."""
    if isinstance(value, dict):
        return {key: presence_contract(child) for key, child in value.items()}
    if isinstance(value, list):
        return len(value) > 0
    return value is not None and value != ""


def evidence_map(path: Path | None) -> dict[str, Any]:
    if path is None:
        return {}
    value = load_json(path)
    if isinstance(value.get("books"), list):
        output = {}
        for item in value["books"]:
            if not isinstance(item, dict):
                continue
            key = item.get("sourceSha256") or item.get("cacheKey") or item.get("alias")
            if key:
                nested = item.get("captureEvidence")
                output[str(key)] = nested if isinstance(nested, dict) else item
        return output
    return value


def find_evidence(
    book: dict[str, Any], metadata: dict[str, Any], supplied: dict[str, Any],
    allow_inferred: bool,
) -> dict[str, Any]:
    kind = str(book.get("kind") or "").lower()
    if kind == "synthetic" or str(book.get("cacheKey", "")).startswith("synthetic:"):
        return {
            "captureMethod": "deterministic-synthetic-metadata",
            "provider": None,
            "providerItemId": None,
        }
    evidence = (
        supplied.get(book["cacheKey"]) or supplied.get(book["alias"])
        or book.get("metadataSelection")
    )
    if isinstance(evidence, dict):
        provider = evidence.get("provider")
        provider_item = evidence.get("providerItemId")
        if provider and provider_item:
            provider = canonical_provider(provider)
            persisted_field = PROVIDER_IDENTIFIERS.get(provider)
            persisted_item = metadata.get(persisted_field) if persisted_field else None
            if persisted_field is None:
                raise CacheError(
                    f"{book['alias']} uses unsupported evidence provider {provider!r}"
                )
            if str(persisted_item or "") != str(provider_item):
                raise CacheError(
                    f"{book['alias']} UI evidence does not match the persisted "
                    f"{provider} item identity"
                )
            return {
                "captureMethod": "grimmory-web-metadata-selection",
                "provider": provider,
                "providerItemId": str(provider_item),
                "query": evidence.get("query"),
                "selectedAt": evidence.get("selectedAt"),
            }
    identifiers = {
        provider: metadata.get(field)
        for provider, field in PROVIDER_IDENTIFIERS.items()
        if metadata.get(field)
    }
    if allow_inferred and identifiers:
        return {
            "captureMethod": "inferred-from-persisted-provider-identifiers",
            "providerIdentifiers": identifiers,
        }
    raise CacheError(
        f"{book['alias']} has no UI provider-selection evidence. Run the one-time "
        "browser metadata-selection journey and pass its evidence JSON. "
        "--allow-inferred-provenance is available only for migrating an old cache."
    )


def new_client(runtime: dict[str, Any]) -> GrimmoryClient:
    return GrimmoryClient(*runtime_connection(runtime))


def load_cache(cache: Path) -> dict[str, Any]:
    manifest = load_json(cache / "manifest.json")
    if manifest.get("schemaVersion") != SCHEMA_VERSION:
        raise CacheError(
            f"unsupported cache schema {manifest.get('schemaVersion')}; expected {SCHEMA_VERSION}"
        )
    if not isinstance(manifest.get("books"), list):
        raise CacheError("cache manifest has no books[]")
    claimed_hash = manifest.get("manifestSha256")
    if not isinstance(claimed_hash, str) or not claimed_hash:
        raise CacheError("cache manifest has no integrity fingerprint")
    unsigned = copy.deepcopy(manifest)
    unsigned.pop("manifestSha256", None)
    actual_hash = sha256_bytes(canonical_json(unsigned))
    if actual_hash != claimed_hash:
        raise CacheError("cache manifest integrity fingerprint does not match")
    return manifest


def cache_index(manifest: dict[str, Any]) -> dict[str, dict[str, Any]]:
    result = {}
    for item in manifest["books"]:
        if not isinstance(item, dict) or not item.get("cacheKey"):
            raise CacheError("invalid cache book entry")
        normalized = copy.deepcopy(item)
        normalized["cacheKey"] = metadata_cache_identity(
            item.get("sourceSha256"), item.get("alias"), item.get("kind"))
        if normalized["cacheKey"] in result:
            raise CacheError("metadata cache contains duplicate source identities")
        result[normalized["cacheKey"]] = normalized
    return result


def privacy_safe_summary(manifest: dict[str, Any]) -> dict[str, Any]:
    """Describe cache coverage without exposing any book-derived value."""
    books = [item for item in manifest.get("books", []) if isinstance(item, dict)]
    methods: dict[str, int] = {}
    providers: dict[str, int] = {}
    field_counts = {field: 0 for field in REPLAY_FIELDS}
    private_count = 0
    cover_count = 0
    for item in books:
        if str(item.get("kind", "")).lower() != "synthetic":
            private_count += 1
        evidence = item.get("captureEvidence") or {}
        method = str(evidence.get("captureMethod") or "unknown")
        methods[method] = methods.get(method, 0) + 1
        provider = canonical_provider(evidence.get("provider"))
        if provider:
            providers[str(provider)] = providers.get(str(provider), 0) + 1
        metadata = item.get("metadata") or {}
        for field in field_counts:
            value = metadata.get(field)
            if value is not None and value != [] and value != {} and value != "":
                field_counts[field] += 1
        if item.get("cover"):
            cover_count += 1
    provenance = manifest.get("serverProvenance") or {}
    return {
        "schemaVersion": manifest.get("schemaVersion"),
        "bookCount": len(books),
        "privateRealEpubCount": private_count,
        "syntheticCount": len(books) - private_count,
        "captureMethods": methods,
        "providers": providers,
        "sourceIdentitiesValidated": len({item.get("cacheKey") for item in books}),
        "covers": {
            "count": cover_count,
            "sourceByteSha256Recorded": True,
            "replayValidation": "256-bit difference hash (distance <= 20) and aspect-ratio delta <= 0.01",
        },
        "nonEmptyPersistedFieldCounts": field_counts,
        "serverProvenanceFingerprint": sha256_bytes(canonical_json(provenance)),
        "privateValuesIncluded": False,
    }


def write_summary(args: argparse.Namespace) -> int:
    manifest = load_cache(args.cache)
    summary = privacy_safe_summary(manifest)
    if args.output:
        write_json(args.output, summary)
        print(f"privacy-safe metadata summary: {args.output}")
    else:
        print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


def copy_cache(args: argparse.Namespace) -> int:
    """Publish only the live manifest and referenced cover blobs to a stable cache."""
    manifest = load_cache(args.cache)
    destination = args.output_cache.resolve()
    assert_private_cache_location(destination)
    for entry in manifest["books"]:
        cover = entry.get("cover")
        if not cover:
            continue
        source = args.cache / cover["file"]
        value = source.read_bytes()
        if sha256_bytes(value) != cover.get("sha256"):
            raise CacheError(f"source cover digest mismatch: {source}")
        target = destination / cover["file"]
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(value)
    write_json(destination / "manifest.json", manifest)
    print(f"copied validated private metadata cache: {destination / 'manifest.json'}")
    return 0


def capture(args: argparse.Namespace) -> int:
    runtime = load_json(args.runtime)
    books = runtime_books(runtime)
    client = new_client(runtime)
    supplied_evidence = evidence_map(args.selection_evidence)
    cache = args.cache.resolve()
    assert_private_cache_location(cache)
    cover_dir = cache / "covers"
    cover_dir.mkdir(parents=True, exist_ok=True)
    captured = []
    for book in books:
        server_book = client.book(book["serverBookId"])
        metadata = server_book["metadata"]
        evidence = find_evidence(
            book, metadata, supplied_evidence, args.allow_inferred_provenance,
        )
        cover_response = client.cover(book["serverBookId"])
        cover_record = None
        if cover_response:
            cover_bytes, _reported_type = cover_response
            extension, mime = image_extension(cover_bytes)
            digest = sha256_bytes(cover_bytes)
            cover_name = f"{book['cacheKey'][:16]}-{digest[:16]}.{extension}"
            cover_path = cover_dir / cover_name
            cover_path.write_bytes(cover_bytes)
            cover_record = {
                "file": f"covers/{cover_name}", "sha256": digest,
                "bytes": len(cover_bytes), "contentType": mime,
                "visualFingerprint": cover_visual_fingerprint(cover_bytes),
            }
        stable = stable_metadata(metadata)
        expected = project_metadata(metadata, cover_record)
        expected["providerSelection"] = copy.deepcopy(evidence)
        expected["presence"] = presence_contract(expected)
        captured.append({
            "cacheKey": book["cacheKey"],
            "sourceSha256": book.get("sourceSha256"),
            "alias": book["alias"],
            "kind": book.get("kind") or ("private" if book.get("sourceSha256") else "synthetic"),
            "captureEvidence": evidence,
            "metadata": stable,
            "metadataProjectionSha256": sha256_bytes(canonical_json(stable)),
            "expectedMetadata": expected,
            "cover": cover_record,
        })
        print(f"captured metadata for {book['alias']} ({evidence['captureMethod']})")
    provenance = runtime.get("provenance") or runtime.get("images") or {}
    manifest = {
        "schemaVersion": SCHEMA_VERSION,
        "capturedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "captureRule": "saved through Grimmory web metadata selection; replay through supported APIs",
        "serverProvenance": provenance,
        "books": captured,
    }
    manifest["manifestSha256"] = sha256_bytes(canonical_json(manifest))
    write_json(cache / "manifest.json", manifest)
    print(f"private metadata cache: {cache / 'manifest.json'}")
    return 0


def compare_entry(
    book: dict[str, Any], entry: dict[str, Any], client: GrimmoryClient,
) -> list[str]:
    live_book = client.book(book["serverBookId"])
    live_metadata = stable_metadata(live_book["metadata"])
    failures = []
    if live_metadata != entry.get("metadata"):
        failures.append(
            f"{book['alias']}: metadata differs "
            f"(expected {entry.get('metadataProjectionSha256')}, "
            f"got {sha256_bytes(canonical_json(live_metadata))})"
        )
    live_cover = client.cover(book["serverBookId"])
    expected_cover = entry.get("cover")
    if expected_cover:
        if not live_cover:
            failures.append(f"{book['alias']}: expected cover is missing")
        elif sha256_bytes(live_cover[0]) != expected_cover.get("sha256"):
            expected_visual = expected_cover.get("visualFingerprint") or {}
            live_visual = cover_visual_fingerprint(live_cover[0])
            expected_hash = expected_visual.get("differenceHash256")
            live_hash = live_visual.get("differenceHash256")
            distance = hash_distance(expected_hash, live_hash) if expected_hash and live_hash else 257
            expected_ratio = expected_visual.get("aspectRatio")
            live_ratio = live_visual.get("aspectRatio")
            ratio_delta = (
                abs(float(expected_ratio) - float(live_ratio))
                if expected_ratio is not None and live_ratio is not None else 1.0
            )
            if distance > 20 or ratio_delta > 0.01:
                failures.append(
                    f"{book['alias']}: cover differs visually "
                    f"(difference-hash distance={distance}, aspect delta={ratio_delta:.4f})"
                )
    elif live_cover:
        failures.append(f"{book['alias']}: unexpected cover exists")
    return failures


def validate_synthetic_before_replay(
    books: list[dict[str, Any]], entries: dict[str, dict[str, Any]],
    client: GrimmoryClient,
) -> list[dict[str, Any]]:
    """Reject semantic synthetic-fixture drift before replay can overwrite it."""
    checks = []
    for book in books:
        if str(book.get("kind") or "").lower() != "synthetic":
            continue
        entry = entries[book["cacheKey"]]
        live = client.book(book["serverBookId"])
        actual = stable_metadata(live.get("metadata") or {})
        expected = entry.get("metadata") or {}
        actual_digest = sha256_bytes(canonical_json(actual))
        expected_digest = entry.get("metadataProjectionSha256") \
            or sha256_bytes(canonical_json(expected))
        if actual != expected or actual_digest != expected_digest:
            raise CacheError(
                f"{book['alias']}: freshly imported synthetic metadata differs "
                "from the cached deterministic contract before replay "
                f"(expected {expected_digest}, got {actual_digest})"
            )
        checks.append({
            "alias": book["alias"],
            "cacheIdentity": book["cacheKey"],
            "cachedSourceSha256": entry.get("sourceSha256"),
            "currentSourceSha256": book.get("sourceSha256"),
            "metadataProjectionSha256": actual_digest,
            "matchedBeforeReplay": True,
            "source": f"/api/v1/books/{book['serverBookId']}?withDescription=true",
        })
    return checks


def enriched_runtime(
    runtime: dict[str, Any], books: list[dict[str, Any]],
    entries: dict[str, dict[str, Any]], cache: Path, client: GrimmoryClient,
    synthetic_pre_replay_checks: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    output = copy.deepcopy(runtime)
    enriched = []
    for book in books:
        original = copy.deepcopy(book)
        entry = entries[book["cacheKey"]]
        original["expectedMetadata"] = copy.deepcopy(entry["expectedMetadata"])
        # Recommendations are computed by Grimmory from the books currently in
        # the library.  Their exact titles can legitimately change on a fresh
        # database because equally-scored candidates inherit database order;
        # they are not provider metadata and are not replayable.  Snapshot the
        # local server's post-replay result instead, so UI tests still prove
        # that every rendered recommendation matches Grimmory without making
        # any provider request.
        live_book = client.book(book["serverBookId"])
        expected = original["expectedMetadata"]
        server_derived = {
            "recommendations": project_recommendations(
                client.recommendations(book["serverBookId"]),
            ),
            "personalRating": live_book.get("personalRating"),
            "metadataMatchScore": live_book.get("metadataMatchScore"),
            "source": {
                "kind": "grimmory-local-api-after-replay",
                "endpoints": {
                    "recommendations": (
                        f"/api/v1/books/{book['serverBookId']}/recommendations"
                    ),
                    "personalRating": (
                        f"/api/v1/books/{book['serverBookId']}?withDescription=true"
                    ),
                    "metadataMatchScore": (
                        f"/api/v1/books/{book['serverBookId']}?withDescription=true"
                    ),
                },
                "providerNetworkUsed": False,
            },
        }
        original["serverDerivedAfterReplay"] = server_derived
        koreader_expected = copy.deepcopy(expected)
        koreader_expected.update({
            "recommendations": copy.deepcopy(server_derived["recommendations"]),
            "personalRating": server_derived["personalRating"],
            "metadataMatchScore": server_derived["metadataMatchScore"],
        })
        original["expectedKoreaderMetadata"] = project_koreader_metadata(
            entry["metadata"], koreader_expected,
        )
        original["metadataProjectionSha256"] = entry["metadataProjectionSha256"]
        original["metadataCacheKey"] = entry["cacheKey"]
        if entry.get("cover"):
            original["expectedMetadata"]["cachedCoverPath"] = str(
                (cache / entry["cover"]["file"]).resolve()
            )
        enriched.append(original)
    output["books"] = enriched
    output["metadataCache"] = {
        "schemaVersion": SCHEMA_VERSION,
        "path": str((cache / "manifest.json").resolve()),
        "manifestSha256": load_cache(cache).get("manifestSha256"),
        "providerNetworkUsed": False,
        "immutableTruth": "provider-saved metadata and cover only",
        "syntheticIdentity": {
            "rule": "stable alias plus exact freshly imported metadata projection before replay",
            "checks": copy.deepcopy(synthetic_pre_replay_checks or []),
        },
        "serverDerivedAfterReplay": {
            "fields": "books[].serverDerivedAfterReplay",
            "source": "field-specific local Grimmory API endpoints after replay",
            "providerNetworkUsed": False,
        },
    }
    return output


def replay_or_verify(args: argparse.Namespace, do_replay: bool) -> int:
    runtime = load_json(args.runtime)
    books = runtime_books(runtime)
    client = new_client(runtime)
    manifest = load_cache(args.cache)
    entries = cache_index(manifest)
    runtime_keys = {book["cacheKey"] for book in books}
    cache_keys = set(entries)
    if runtime_keys != cache_keys:
        missing = sorted(runtime_keys - cache_keys)
        stale = sorted(cache_keys - runtime_keys)
        raise CacheError(f"cache/source identity mismatch; missing={missing}, stale={stale}")
    synthetic_pre_replay_checks = copy.deepcopy(
        (((runtime.get("metadataCache") or {}).get("syntheticIdentity") or {})
         .get("checks") or [])
    )
    if do_replay:
        # This MUST precede every PUT. Stable alias identity is permitted only
        # for generated synthetic controls, and only when their newly imported
        # public metadata is byte-for-byte the cached projection. Thus ZIP/body
        # privacy edits are harmless, while semantic fixture drift cannot be
        # hidden by replay overwriting the live values.
        synthetic_pre_replay_checks = validate_synthetic_before_replay(
            books, entries, client)
        for book in books:
            entry = entries[book["cacheKey"]]
            client.put_metadata(book["serverBookId"], entry["metadata"])
            cover = entry.get("cover")
            if cover:
                cover_path = args.cache / cover["file"]
                cover_bytes = cover_path.read_bytes()
                if sha256_bytes(cover_bytes) != cover["sha256"]:
                    raise CacheError(f"cached cover digest mismatch: {cover_path}")
                client.upload_cover(
                    book["serverBookId"], cover_bytes, cover_path.name,
                    cover.get("contentType") or mimetypes.guess_type(cover_path.name)[0]
                    or "application/octet-stream",
                )
            print(f"replayed cached metadata for {book['alias']}")
    failures = []
    for book in books:
        failures.extend(compare_entry(book, entries[book["cacheKey"]], client))
    if failures:
        raise CacheError("metadata verification failed:\n  " + "\n  ".join(failures))
    destination = args.enriched_runtime or args.runtime.with_name("runtime.with-metadata.json")
    write_json(destination, enriched_runtime(
        runtime, books, entries, args.cache, client,
        synthetic_pre_replay_checks,
    ))
    print(f"verified {len(books)} cached metadata records without provider requests")
    print(f"enriched runtime: {destination}")
    return 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subparsers = result.add_subparsers(dest="command", required=True)
    capture_parser = subparsers.add_parser("capture")
    capture_parser.add_argument("--runtime", type=Path, required=True)
    capture_parser.add_argument("--cache", type=Path, default=DEFAULT_CACHE)
    capture_parser.add_argument("--selection-evidence", type=Path)
    capture_parser.add_argument("--allow-inferred-provenance", action="store_true")
    capture_parser.set_defaults(handler=capture)
    for command, do_replay in (("replay", True), ("verify", False)):
        child = subparsers.add_parser(command)
        child.add_argument("--runtime", type=Path, required=True)
        child.add_argument("--cache", type=Path, default=DEFAULT_CACHE)
        child.add_argument("--enriched-runtime", type=Path)
        child.set_defaults(
            handler=lambda args, replay=do_replay: replay_or_verify(args, replay),
        )
    summary_parser = subparsers.add_parser("summary")
    summary_parser.add_argument("--cache", type=Path, default=DEFAULT_CACHE)
    summary_parser.add_argument("--output", type=Path)
    summary_parser.set_defaults(handler=write_summary)
    copy_parser = subparsers.add_parser("copy")
    copy_parser.add_argument("--cache", type=Path, required=True)
    copy_parser.add_argument("--output-cache", type=Path, required=True)
    copy_parser.set_defaults(handler=copy_cache)
    return result


def main() -> int:
    args = parser().parse_args()
    args.cache = args.cache.resolve()
    assert_private_cache_location(args.cache)
    try:
        return args.handler(args)
    except (CacheError, OSError, KeyError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
