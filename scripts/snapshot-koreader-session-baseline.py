#!/usr/bin/env python3
"""Snapshot stable reading-session IDs immediately before KOReader runs."""

from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path


def load_verifier(repo: Path):
    source = repo / "scripts" / "verify-koreader-reader-artifacts.py"
    spec = importlib.util.spec_from_file_location("koreader_reader_verifier", source)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load verifier: {source}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--alias", action="append", default=[])
    args = parser.parse_args()

    repo = Path(__file__).resolve().parents[1]
    verifier = load_verifier(repo)
    runtime = verifier.load_object(args.runtime.resolve(), "runtime")
    requested = set(args.alias)
    books = [
        book for book in runtime.get("books") or []
        if not requested or str(book.get("alias") or "") in requested
    ]
    verifier.require(bool(books), "session baseline has no selected books")
    verifier.require(
        not requested or requested == {str(book.get("alias") or "") for book in books},
        "session baseline contains an unknown alias",
    )

    client = verifier.Client(
        str(runtime.get("baseUrl") or ""),
        str(runtime.get("username") or ""),
        str(runtime.get("password") or ""),
    )
    client.login()
    sessions: dict[str, list[str]] = {}
    for book in books:
        alias = str(book.get("alias") or "")
        book_id = int(book["serverBookId"])
        rows = verifier.as_items(client.request(
            f"/api/v1/reading-sessions/book/{book_id}?page=0&size=100"
        ))
        verifier.require(all(row.get("id") is not None for row in rows),
                         f"{alias}: baseline session response omitted stable IDs")
        sessions[alias] = [str(row["id"]) for row in rows]

    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({
        "schemaVersion": 1,
        "sourceFingerprint": runtime.get("sourceFingerprint"),
        "sessions": sessions,
    }, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
