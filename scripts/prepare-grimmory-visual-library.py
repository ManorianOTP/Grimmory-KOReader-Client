#!/usr/bin/env python3
"""Prepare ignored, local Grimmory fixtures from user-owned EPUB files.

The source books are never copied into the repository.  This writes an
ignored runtime manifest, hashes, and locally extracted cover images only.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import mimetypes
import os
from pathlib import Path, PurePosixPath
import shutil
import sys
import tempfile
import zipfile
import xml.etree.ElementTree as ET

from PIL import Image, ImageOps

# The fixture server owns the Grimmory v3 wire shape.  Reusing it here keeps
# private companion runs honest: their locally generated UI records pass
# through the same contract as server responses instead of inventing a second
# approximation in this preparation script.
sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tests" / "emulator"))
from grimmory_fixture_server import FixtureState  # noqa: E402
from private_epub_sources import (  # noqa: E402
    SourceResolutionError,
    resolve_private_epubs,
)


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_FIXTURE = ROOT / "tests" / "emulator" / "grimmory_library_fixture.json"
DEFAULT_OUTPUT = ROOT / "build" / "grimmory-fixture"
DEFAULT_METADATA_CACHE = (
    ROOT / "build" / "grimmory-compatibility" / "private-metadata-cache"
)

PROVIDER_METADATA_FIELDS = (
    "title", "subtitle", "authors", "series", "publisher", "publishedDate",
    "pageCount", "language", "genres", "tags", "moods", "description",
    "identifiers", "ratings", "reviews", "coverPresent",
    "coverSourceSha256", "coverVisualFingerprint", "providerSelection",
)
CATALOG_STRESS_FIELDS = (
    "libraryId", "libraryName", "shelves", "readStatus", "personalRating",
    "epubProgress", "lastReadAt", "createdAt", "lastReadTime", "addedOn",
    "alternativeFormats", "metadata.coverUpdatedOn", "metadata.allMetadataLocked",
)


def canonical_json(value: object) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
    ).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def load_provider_cache(cache: Path) -> tuple[dict[str, dict], dict]:
    """Load and fully validate the ignored exact-SHA provider cache.

    Private visual DTOs may not fall back to tracked fixture metadata: doing so
    makes a real title/cover mask fictional series, genres, ratings or reviews.
    """

    cache = cache.resolve()
    manifest_path = cache / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schemaVersion") != 1 or not isinstance(manifest.get("books"), list):
        raise ValueError("provider metadata cache must be schemaVersion 1 with books[]")
    claimed = manifest.get("manifestSha256")
    unsigned = copy.deepcopy(manifest)
    unsigned.pop("manifestSha256", None)
    actual = sha256_bytes(canonical_json(unsigned))
    if not isinstance(claimed, str) or claimed != actual:
        raise ValueError("provider metadata cache integrity fingerprint does not match")

    index: dict[str, dict] = {}
    for item in manifest["books"]:
        if not isinstance(item, dict) or item.get("kind") != "private-real-epub":
            continue
        source_sha = item.get("sourceSha256")
        if not isinstance(source_sha, str) or len(source_sha) != 64:
            raise ValueError("private provider metadata entry has invalid sourceSha256")
        if item.get("cacheKey") != source_sha:
            raise ValueError(
                f"private provider metadata must use exact source SHA identity: {source_sha}"
            )
        if source_sha in index:
            raise ValueError(f"duplicate provider metadata source identity: {source_sha}")
        expected = item.get("expectedMetadata")
        if not isinstance(expected, dict):
            raise ValueError(f"provider metadata entry has no expectedMetadata: {source_sha}")
        missing = [field for field in PROVIDER_METADATA_FIELDS if field not in expected]
        if missing:
            raise ValueError(
                f"provider metadata entry omits projected fields {missing}: {source_sha}"
            )
        native_metadata = item.get("metadata")
        if not isinstance(native_metadata, dict):
            raise ValueError(f"provider metadata entry has no native metadata: {source_sha}")
        projection_digest = item.get("metadataProjectionSha256")
        if (
            not isinstance(projection_digest, str)
            or len(projection_digest) != 64
            or projection_digest != sha256_bytes(canonical_json(native_metadata))
        ):
            raise ValueError(f"provider native metadata projection differs: {source_sha}")
        evidence = item.get("captureEvidence")
        if (
            not isinstance(evidence, dict)
            or evidence.get("captureMethod") != "grimmory-web-metadata-selection"
            or not evidence.get("provider")
            or not evidence.get("providerItemId")
        ):
            raise ValueError(f"provider metadata lacks visible selection evidence: {source_sha}")
        selected = expected.get("providerSelection") or {}
        if (
            selected.get("provider") != evidence.get("provider")
            or str(selected.get("providerItemId") or "")
            != str(evidence.get("providerItemId") or "")
        ):
            raise ValueError(f"provider selection evidence differs: {source_sha}")
        cover = item.get("cover")
        if bool(expected.get("coverPresent")) != bool(cover):
            raise ValueError(f"provider cover presence contract differs: {source_sha}")
        if cover:
            relative = Path(str(cover.get("file") or ""))
            cover_path = (cache / relative).resolve()
            try:
                cover_path.relative_to(cache)
            except ValueError as exc:
                raise ValueError(f"provider cover escapes cache: {relative}") from exc
            cover_bytes = cover_path.read_bytes()
            if len(cover_bytes) != int(cover.get("bytes") or -1):
                raise ValueError(f"provider cover byte count differs: {source_sha}")
            if sha256_bytes(cover_bytes) != cover.get("sha256"):
                raise ValueError(f"provider cover digest differs: {source_sha}")
            if cover.get("sha256") != expected.get("coverSourceSha256"):
                raise ValueError(f"provider cover projection digest differs: {source_sha}")
            if cover.get("visualFingerprint") != expected.get("coverVisualFingerprint"):
                raise ValueError(f"provider cover visual fingerprint differs: {source_sha}")
            cover = {**cover, "path": str(cover_path)}
        normalized = copy.deepcopy(item)
        normalized["cover"] = cover
        index[source_sha] = normalized

    return index, {
        "schemaVersion": 1,
        "manifestPath": str(manifest_path),
        "manifestSha256": claimed,
        "providerNetworkUsed": False,
        "identityRule": "exact private EPUB SHA-256",
        "source": "Grimmory-visible provider selection cache",
    }


def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def normalized_member(base: PurePosixPath, href: str) -> str:
    candidate = base.joinpath(PurePosixPath(href))
    parts: list[str] = []
    for part in candidate.parts:
        if part in ("", "."):
            continue
        if part == "..":
            if not parts:
                raise ValueError(f"EPUB member escapes archive root: {href}")
            parts.pop()
        else:
            parts.append(part)
    return "/".join(parts)


def text_values(root: ET.Element, name: str) -> list[str]:
    return [
        (node.text or "").strip()
        for node in root.iter()
        if local_name(node.tag) == name and (node.text or "").strip()
    ]


def epub_details(path: Path, cover_dir: Path, book_id: int) -> dict:
    sha = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            sha.update(chunk)

    with zipfile.ZipFile(path) as archive:
        bad_member = archive.testzip()
        if bad_member:
            raise ValueError(f"CRC failure in {path.name}: {bad_member}")
        container = ET.fromstring(archive.read("META-INF/container.xml"))
        rootfiles = [
            node for node in container.iter() if local_name(node.tag) == "rootfile"
        ]
        if not rootfiles:
            raise ValueError(f"No package document in {path.name}")
        opf_name = rootfiles[0].attrib.get("full-path")
        if not opf_name:
            raise ValueError(f"Package path missing in {path.name}")
        opf = ET.fromstring(archive.read(opf_name))
        opf_base = PurePosixPath(opf_name).parent

        manifest_items: dict[str, ET.Element] = {}
        content_members: list[str] = []
        cover_id = None
        cover_href = None
        for node in opf.iter():
            if local_name(node.tag) == "item":
                item_id = node.attrib.get("id")
                if item_id:
                    manifest_items[item_id] = node
                if node.attrib.get("media-type") in {
                    "application/xhtml+xml",
                    "text/html",
                } and node.attrib.get("href"):
                    content_members.append(
                        normalized_member(opf_base, node.attrib["href"])
                    )
                if "cover-image" in node.attrib.get("properties", "").split():
                    cover_href = node.attrib.get("href")
            elif local_name(node.tag) == "meta" and node.attrib.get("name") == "cover":
                cover_id = node.attrib.get("content")
        if not cover_href and cover_id in manifest_items:
            cover_href = manifest_items[cover_id].attrib.get("href")

        cover_info = None
        if cover_href:
            member = normalized_member(opf_base, cover_href)
            cover_bytes = archive.read(member)
            suffix = PurePosixPath(member).suffix.lower()
            content_type = mimetypes.guess_type(member)[0] or "application/octet-stream"
            if suffix in {".jpg", ".jpeg", ".png", ".gif", ".webp"}:
                cover_path = cover_dir / f"{book_id}{suffix}"
                cover_path.write_bytes(cover_bytes)
                cover_info = {
                    "path": str(cover_path.resolve()),
                    "contentType": content_type,
                    "sha256": hashlib.sha256(cover_bytes).hexdigest(),
                    "bytes": len(cover_bytes),
                }

        return {
            "sourcePath": str(path.resolve()),
            "sourceSha256": sha.hexdigest(),
            "sourceBytes": path.stat().st_size,
            "embeddedMetadata": {
                "titles": text_values(opf, "title"),
                "authors": text_values(opf, "creator"),
                "publishers": text_values(opf, "publisher"),
                "dates": text_values(opf, "date"),
                "languages": text_values(opf, "language"),
                "identifiers": text_values(opf, "identifier"),
                "descriptions": text_values(opf, "description"),
                "subjects": text_values(opf, "subject"),
            },
            "epubProfile": {
                "archiveMembers": len(archive.infolist()),
                "contentDocuments": len(content_members),
                "spineItems": sum(
                    1 for node in opf.iter() if local_name(node.tag) == "itemref"
                ),
                "contentBytes": sum(
                    archive.getinfo(member).file_size for member in content_members
                ),
            },
            "cover": cover_info,
        }


def visual_library(
    fixture: dict, provider_entries: dict[str, dict], cache_provenance: dict,
) -> dict:
    """Build ignored DTOs from exact-SHA Grimmory provider metadata.

    This output may contain titles, authors, descriptions, filesystem paths,
    and cover paths.  It is intentionally written only below ignored build/.
    The tracked fixture contributes only explicitly-labelled local catalogue
    stress state; no provider-owned field may leak from it.
    """

    state = FixtureState(fixture)
    books = []
    for raw in fixture["books"]:
        dto = state.dto(raw, detail=True)
        source_sha = raw.get("sourceSha256")
        provider = provider_entries.get(source_sha)
        if provider is None:
            raise ValueError(
                f"no exact-SHA provider metadata cache entry for private book {raw['id']}"
            )
        expected = copy.deepcopy(provider["expectedMetadata"])
        native_metadata = copy.deepcopy(provider["metadata"])
        metadata = dto["metadata"]
        cover_updated_on = metadata.get("coverUpdatedOn")

        dto["title"] = expected["title"]
        metadata.clear()
        metadata.update(native_metadata)
        metadata["coverUpdatedOn"] = cover_updated_on
        metadata["allMetadataLocked"] = True
        # The current DTO also exposes some rating/review fields at book level.
        # Populate them from the same provider projection so no deterministic
        # fixture value can surface through a compatibility path.
        dto.update({
            "goodreadsRating": native_metadata.get("goodreadsRating"),
            "goodreadsReviewCount": native_metadata.get("goodreadsReviewCount"),
            "hardcoverRating": native_metadata.get("hardcoverRating"),
            "hardcoverReviewCount": native_metadata.get("hardcoverReviewCount"),
            "bookReviews": copy.deepcopy(native_metadata.get("bookReviews") or []),
        })

        primary = dto["primaryFile"]
        alternatives = dto.get("alternativeFormats") or []
        dto.update(
            fileName=primary.get("fileName"),
            fileSizeKb=primary.get("fileSizeKb"),
            bookType=primary.get("bookType"),
            bookFiles=[primary, *alternatives],
            downloadFiles=[primary, *alternatives],
            downloadEligible=True,
            sourcePath=raw["sourcePath"],
            sourceSha256=raw["sourceSha256"],
            sourceBytes=raw["sourceBytes"],
            sourceBookId=raw["id"],
            sourceFileId=raw["fileId"],
            epubProfile=raw["epubProfile"],
        )
        provider_cover = provider.get("cover")
        dto["cover"] = ({
            "path": raw["visualCoverPath"],
            "contentType": provider_cover["contentType"],
            "sha256": provider_cover["sha256"],
        } if provider_cover else None)
        dto["metadataProvenance"] = {
            "provider": {
                "source": "ignored exact-SHA Grimmory provider cache",
                "cacheKey": provider["cacheKey"],
                "sourceSha256": provider["sourceSha256"],
                "metadataProjectionSha256": provider["metadataProjectionSha256"],
                "coverPresent": expected["coverPresent"],
                "coverSourceSha256": expected["coverSourceSha256"],
                "captureEvidence": copy.deepcopy(provider["captureEvidence"]),
                "fields": list(PROVIDER_METADATA_FIELDS),
                "providerNetworkUsed": False,
            },
            "catalogStressOverlay": {
                "source": "tracked fictional deterministic fixture",
                "fields": list(CATALOG_STRESS_FIELDS),
                "providerMetadata": False,
            },
        }
        books.append(dto)

    return {
        "schemaVersion": 1,
        "fixtureMode": "real-epub-companion",
        "metadataProvenance": {
            "provider": {
                **copy.deepcopy(cache_provenance),
                "fields": list(PROVIDER_METADATA_FIELDS),
                "bookCount": len(books),
            },
            "catalogStressOverlay": {
                "source": "tracked fictional deterministic fixture",
                "fields": list(CATALOG_STRESS_FIELDS),
                "providerMetadata": False,
            },
        },
        "books": books,
        "libraries": fixture.get("libraries", [fixture["library"]]),
        "shelves": state.shelf_summaries(),
    }


def verify_provider_overlay(
    library: dict, provider_entries: dict[str, dict], cache_provenance: dict,
) -> dict:
    """Fail closed if any real DTO provider surface diverges from its cache."""

    checks = []
    for book in library.get("books") or []:
        source_sha = book.get("sourceSha256")
        provider = provider_entries.get(source_sha)
        if provider is None:
            raise ValueError(f"provider overlay verification has no entry: {source_sha}")
        actual_metadata = copy.deepcopy(book.get("metadata") or {})
        actual_metadata.pop("coverUpdatedOn", None)
        actual_metadata.pop("allMetadataLocked", None)
        if actual_metadata != provider["metadata"]:
            raise ValueError(f"provider overlay metadata differs for book {book['id']}")
        native = provider["metadata"]
        for key in (
            "goodreadsRating", "goodreadsReviewCount", "hardcoverRating",
            "hardcoverReviewCount", "bookReviews",
        ):
            expected_value = native.get(key)
            if key == "bookReviews" and expected_value is None:
                expected_value = []
            if book.get(key) != expected_value:
                raise ValueError(
                    f"provider overlay compatibility field {key} differs for book {book['id']}"
                )
        provider_cover = provider.get("cover")
        rendered_cover = book.get("cover")
        if bool(provider_cover) != bool(rendered_cover):
            raise ValueError(f"provider overlay cover presence differs for book {book['id']}")
        if provider_cover and rendered_cover.get("sha256") != provider_cover.get("sha256"):
            raise ValueError(f"provider overlay cover digest differs for book {book['id']}")
        provenance = book.get("metadataProvenance") or {}
        if (
            (provenance.get("provider") or {}).get("cacheKey") != source_sha
            or (provenance.get("catalogStressOverlay") or {}).get("providerMetadata")
            is not False
        ):
            raise ValueError(f"provider overlay provenance differs for book {book['id']}")
        checks.append({
            "fixtureBookId": int(book["id"]),
            "sourceSha256": source_sha,
            "metadataProjectionSha256": provider["metadataProjectionSha256"],
            "coverSourceSha256": provider_cover.get("sha256") if provider_cover else None,
            "nativeMetadataExact": True,
            "compatibilityFieldsExact": True,
            "coverExact": True,
            "catalogStressClaimedAsProvider": False,
        })
    return {
        "schemaVersion": 1,
        "status": "passed",
        "manifestSha256": cache_provenance["manifestSha256"],
        "providerNetworkUsed": False,
        "bookCount": len(checks),
        "checks": checks,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-dir", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, default=DEFAULT_FIXTURE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument(
        "--metadata-cache",
        type=Path,
        help="ignored cache used to match the eight source files by SHA-256",
    )
    parser.add_argument(
        "--private-source-map",
        type=Path,
        help="ignored schemaVersion 1 map of neutral fixture IDs to EPUB paths",
    )
    parser.add_argument(
        "--stage-books",
        type=Path,
        help="also hard-link/copy the exact eight books into this ignored directory for the real Docker server",
    )
    args = parser.parse_args()

    fixture = json.loads(args.fixture.read_text(encoding="utf-8"))
    output = args.output.resolve()
    failures: list[str] = []
    sources: list[tuple[dict, Path]] = []
    metadata_cache = args.metadata_cache
    if metadata_cache is None and (DEFAULT_METADATA_CACHE / "manifest.json").is_file():
        metadata_cache = DEFAULT_METADATA_CACHE
    if metadata_cache is None:
        print(
            "ERROR: real visual companions require an ignored Grimmory provider "
            "metadata cache; pass --metadata-cache",
            file=sys.stderr,
        )
        return 2
    try:
        provider_entries, cache_provenance = load_provider_cache(metadata_cache)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"ERROR: invalid provider metadata cache: {exc}", file=sys.stderr)
        return 2
    try:
        resolved = resolve_private_epubs(
            fixture["books"], args.source_dir,
            metadata_cache=metadata_cache,
            source_map=args.private_source_map,
        )
    except SourceResolutionError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    for book in fixture["books"]:
        sources.append((book, resolved[int(book["id"])]))

    output.parent.mkdir(parents=True, exist_ok=True)
    prepared_books = []
    with tempfile.TemporaryDirectory(prefix="grimmory-covers.", dir=output.parent) as temp:
        temporary_covers = Path(temp) / "covers"
        temporary_covers.mkdir()
        for book, source in sources:
            try:
                runtime = epub_details(source, temporary_covers, int(book["id"]))
            except (KeyError, OSError, ValueError, zipfile.BadZipFile, ET.ParseError) as exc:
                failures.append(f"invalid {source.name}: {exc}")
                continue
            prepared_books.append({
                **book,
                **runtime,
                # Private and written only below ignored build/. The tracked
                # deterministic fixture retains its fictional filename.
                "sourceFileName": source.name,
            })
            print(
                f"prepared private slot {book['id']} "
                f"({runtime['sourceBytes']} bytes, source identity verified)"
            )

        if failures:
            for failure in failures:
                print(f"ERROR: {failure}", file=sys.stderr)
            print("No runtime manifest, covers, or staged books were published.", file=sys.stderr)
            return 2

        final_covers = output / "covers"
        final_covers.mkdir(parents=True, exist_ok=True)
        visual_covers = output / "visual-covers"
        visual_covers.mkdir(parents=True, exist_ok=True)
        for book in prepared_books:
            cover = book.get("cover")
            if cover:
                temporary_cover = Path(cover["path"])
                final_cover = final_covers / temporary_cover.name

                # Embedded covers can be several thousand pixels wide. Feeding
                # a row of those originals to KOReader's small image cache can
                # exhaust it before the UI paints. Grimmory serves thumbnails
                # in normal use, so make an equivalent bounded local asset for
                # the optional private-cover gallery.
                visual_cover = visual_covers / f"{book['id']}.jpg"
                temporary_visual = visual_cover.with_suffix(".jpg.tmp")
                with Image.open(temporary_cover) as opened:
                    resized = ImageOps.exif_transpose(opened)
                    resized.thumbnail((600, 840), Image.Resampling.LANCZOS)
                    if "A" in resized.getbands():
                        flattened = Image.new("RGBA", resized.size, "white")
                        flattened.alpha_composite(resized.convert("RGBA"))
                        resized = flattened.convert("RGB")
                    else:
                        resized = resized.convert("RGB")
                    resized.save(
                        temporary_visual,
                        format="JPEG",
                        quality=86,
                        optimize=True,
                    )
                temporary_visual.replace(visual_cover)
                book["visualCoverPath"] = str(visual_cover.resolve())

                temporary_cover.replace(final_cover)
                cover["path"] = str(final_cover.resolve())

        # Real companion cover pixels must be the exact provider-selected
        # Grimmory cache bytes, not the EPUB's embedded art.  Copy them into
        # this ignored run so the runtime is self-contained and validate the
        # exact source identity again at the preparation boundary.
        provider_covers = output / "provider-covers"
        provider_covers.mkdir(parents=True, exist_ok=True)
        for book in prepared_books:
            source_sha = book["sourceSha256"]
            provider = provider_entries.get(source_sha)
            if provider is None:
                failures.append(
                    f"no exact-SHA provider metadata for fixture book {book['id']}"
                )
                continue
            provider_cover = provider.get("cover")
            if provider_cover:
                source_cover = Path(provider_cover["path"])
                suffix = source_cover.suffix.lower() or ".jpg"
                local_cover = provider_covers / f"{book['id']}{suffix}"
                local_cover.write_bytes(source_cover.read_bytes())
                book["visualCoverPath"] = str(local_cover.resolve())
                book["cover"] = {
                    **provider_cover,
                    "path": str(local_cover.resolve()),
                }
            else:
                book["visualCoverPath"] = None
                book["cover"] = None
            book["providerMetadataCache"] = {
                "cacheKey": provider["cacheKey"],
                "sourceSha256": provider["sourceSha256"],
                "metadataProjectionSha256": provider["metadataProjectionSha256"],
                "captureEvidence": copy.deepcopy(provider["captureEvidence"]),
                "providerNetworkUsed": False,
            }

        if failures:
            for failure in failures:
                print(f"ERROR: {failure}", file=sys.stderr)
            print("No provider-backed visual library was published.", file=sys.stderr)
            return 2

    if args.stage_books:
        args.stage_books.mkdir(parents=True, exist_ok=True)
        for book, source in sources:
            staged = args.stage_books / f"{book['id']}.epub"
            if staged.exists():
                staged.unlink()
            try:
                os.link(source, staged)
            except OSError:
                shutil.copy2(source, staged)

    runtime_fixture = {**fixture, "books": prepared_books, "fixtureMode": "real-epub"}
    runtime_fixture["metadataProvenance"] = {
        "provider": {
            **copy.deepcopy(cache_provenance),
            "fields": list(PROVIDER_METADATA_FIELDS),
            "bookCount": len(prepared_books),
        },
        "catalogStressOverlay": {
            "source": "tracked fictional deterministic fixture",
            "fields": list(CATALOG_STRESS_FIELDS),
            "providerMetadata": False,
        },
    }
    manifest_path = output / "library.json"
    temporary = manifest_path.with_suffix(".json.tmp")
    temporary.write_text(
        json.dumps(runtime_fixture, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    temporary.replace(manifest_path)
    print(f"runtime manifest: {manifest_path}")

    visual_library_path = output / "visual-library.json"
    temporary_visual_library = visual_library_path.with_suffix(".json.tmp")
    private_visual_library = visual_library(
        runtime_fixture, provider_entries, cache_provenance,
    )
    overlay_verification = verify_provider_overlay(
        private_visual_library, provider_entries, cache_provenance,
    )
    temporary_visual_library.write_text(
        json.dumps(private_visual_library, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    temporary_visual_library.replace(visual_library_path)
    print(f"visual companion library: {visual_library_path}")
    overlay_path = output / "provider-overlay-verification.json"
    temporary_overlay = overlay_path.with_suffix(".json.tmp")
    temporary_overlay.write_text(
        json.dumps(overlay_verification, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    temporary_overlay.replace(overlay_path)
    print(f"provider overlay verification: {overlay_path}")

    # A narrow map lets the deterministic whole-app scenarios render the
    # user's real covers without replacing their deliberately stressful book
    # records (long titles, missing covers, pagination boundaries, and so on).
    cover_map = {}
    for book in private_visual_library["books"]:
        cover = book.get("cover")
        cover_map[str(book["id"])] = (
            cover.get("path")
            if cover and book.get("coverAvailable", True) is not False
            else None
        )
    cover_map_path = output / "cover-map.json"
    temporary_cover_map = cover_map_path.with_suffix(".json.tmp")
    temporary_cover_map.write_text(
        json.dumps(cover_map, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    temporary_cover_map.replace(cover_map_path)
    print(f"visual cover map: {cover_map_path}")
    if not args.stage_books:
        print("The EPUB files remain in their original directory and are not copied.")
    if args.stage_books:
        print(
            "Real-server staging: "
            f"{args.stage_books.resolve()} (ignored local lane; hard links used where supported)"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
