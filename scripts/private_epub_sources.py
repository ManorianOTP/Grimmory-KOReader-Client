#!/usr/bin/env python3
"""Resolve private EPUB slots without committing filenames or book metadata."""

from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
from typing import Any


class SourceResolutionError(RuntimeError):
    pass


def _canonical_json(value: Any) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
    ).encode("utf-8")


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _expected_ids(books: list[dict[str, Any]]) -> list[int]:
    ids = [int(book["id"]) for book in books]
    if len(ids) != 8 or len(set(ids)) != 8:
        raise SourceResolutionError("fixture must declare eight unique private EPUB slots")
    return ids


def _from_explicit_map(
    books: list[dict[str, Any]], source_dir: Path, source_map: Path,
) -> dict[int, Path]:
    try:
        value = json.loads(source_map.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SourceResolutionError(f"cannot read private source map: {exc}") from exc
    rows = value.get("books") if isinstance(value, dict) else None
    if not isinstance(value, dict) or value.get("schemaVersion") != 1 \
            or not isinstance(rows, list):
        raise SourceResolutionError("private source map must use schemaVersion 1 and books[]")
    output: dict[int, Path] = {}
    for row in rows:
        if not isinstance(row, dict) or "id" not in row or "path" not in row:
            raise SourceResolutionError("private source map rows require id and path")
        book_id = int(row["id"])
        raw = Path(str(row["path"]))
        path = raw if raw.is_absolute() else source_dir / raw
        if book_id in output:
            raise SourceResolutionError(f"duplicate private source slot {book_id}")
        output[book_id] = path.resolve()
    expected = set(_expected_ids(books))
    if set(output) != expected:
        raise SourceResolutionError("private source map must cover the eight fixture IDs exactly")
    return output


def _cache_hashes(books: list[dict[str, Any]], metadata_cache: Path) -> dict[int, str]:
    manifest_path = metadata_cache / "manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SourceResolutionError(f"cannot read private metadata cache: {exc}") from exc
    if not isinstance(manifest, dict):
        raise SourceResolutionError("private metadata cache manifest must be an object")
    claimed = manifest.get("manifestSha256")
    unsigned = copy.deepcopy(manifest)
    unsigned.pop("manifestSha256", None)
    actual = hashlib.sha256(_canonical_json(unsigned)).hexdigest()
    if not isinstance(claimed, str) or claimed != actual:
        raise SourceResolutionError("private metadata cache integrity fingerprint differs")
    by_alias = {
        str(row.get("alias")): row
        for row in manifest.get("books", [])
        if isinstance(row, dict)
    }
    output: dict[int, str] = {}
    for book_id in _expected_ids(books):
        row = by_alias.get(f"real-{book_id}")
        digest = row.get("sourceSha256") if row else None
        if not isinstance(digest, str) or len(digest) != 64:
            raise SourceResolutionError(
                f"private metadata cache has no source identity for slot {book_id}"
            )
        output[book_id] = digest.lower()
    if len(set(output.values())) != len(output):
        raise SourceResolutionError("private metadata cache reuses a source across slots")
    return output


def _from_cache(
    books: list[dict[str, Any]], source_dir: Path, metadata_cache: Path,
) -> dict[int, Path]:
    expected = _cache_hashes(books, metadata_cache)
    candidates = sorted(
        (path for path in source_dir.iterdir()
         if path.is_file() and path.suffix.casefold() == ".epub"),
        key=lambda path: path.name.casefold(),
    )
    by_hash: dict[str, list[Path]] = {}
    wanted = set(expected.values())
    for candidate in candidates:
        digest = _sha256(candidate)
        if digest in wanted:
            by_hash.setdefault(digest, []).append(candidate.resolve())
    output: dict[int, Path] = {}
    missing: list[int] = []
    for book_id, digest in expected.items():
        matches = by_hash.get(digest) or []
        if not matches:
            missing.append(book_id)
        else:
            # Byte-identical duplicate files are equivalent. Choosing the first
            # stable path avoids leaking either filename into tracked state.
            output[book_id] = matches[0]
    if missing:
        raise SourceResolutionError(
            "source directory is missing cached private EPUB slot(s): "
            + ", ".join(str(value) for value in missing)
        )
    return output


def resolve_private_epubs(
    books: list[dict[str, Any]], source_dir: Path, *,
    metadata_cache: Path | None = None, source_map: Path | None = None,
) -> dict[int, Path]:
    """Resolve each neutral fixture ID to an ignored user-owned EPUB path.

    An explicit ignored map is useful before the first provider cache exists.
    Normal runs use the already-validated private metadata cache's exact source
    hashes, so tracked code never needs a title or filename from the library.
    """

    source_dir = source_dir.resolve()
    if not source_dir.is_dir():
        raise SourceResolutionError(f"source directory does not exist: {source_dir}")
    if source_map is not None:
        resolved = _from_explicit_map(books, source_dir, source_map.resolve())
    elif metadata_cache is not None and (metadata_cache / "manifest.json").is_file():
        resolved = _from_cache(books, source_dir, metadata_cache.resolve())
    else:
        raise SourceResolutionError(
            "private EPUB filenames are intentionally not tracked; pass an ignored "
            "--private-source-map, or provide the private metadata cache so files "
            "can be matched by exact source SHA-256"
        )
    missing = [book_id for book_id, path in resolved.items() if not path.is_file()]
    if missing:
        raise SourceResolutionError(
            "resolved private EPUB path is missing for slot(s): "
            + ", ".join(str(value) for value in missing)
        )
    return resolved
