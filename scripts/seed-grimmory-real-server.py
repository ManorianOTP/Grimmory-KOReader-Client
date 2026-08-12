#!/usr/bin/env python3
"""Create a test-owned account/library through Grimmory's public API.

The script deliberately does not edit Grimmory's database or files.  It waits
for the real library scanner to discover every staged EPUB, then writes an
ignored import record that later browser and KOReader journeys can consume.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import time
import urllib.error
import urllib.request


USERNAME = "visual"
PASSWORD = "grimmory-visual"
LIBRARY_NAME = "Visual Real EPUB Library"


def request(base: str, path: str, method: str = "GET", body=None, token=None):
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(base + path, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=15) as response:
        raw = response.read()
        return json.loads(raw) if raw else None


def unwrap(value):
    """Accept both Grimmory's direct DTOs and its occasional data wrapper."""
    if isinstance(value, dict) and set(value).issuperset({"data"}):
        return value["data"]
    return value


def page_content(value) -> list[dict]:
    value = unwrap(value)
    if isinstance(value, dict):
        content = value.get("content", [])
        return content if isinstance(content, list) else []
    return value if isinstance(value, list) else []


def file_names(book: dict) -> set[str]:
    names: set[str] = set()
    candidates = [book.get("primaryFile")]
    candidates.extend(book.get("alternativeFormats") or [])
    candidates.extend(book.get("bookFiles") or [])
    candidates.extend(book.get("files") or [])
    for candidate in candidates:
        if isinstance(candidate, dict):
            name = candidate.get("fileName") or candidate.get("filename")
            if name:
                names.add(str(name))
    direct = book.get("fileName") or book.get("filename")
    if direct:
        names.add(str(direct))
    return names


def source_entries(path: Path | None) -> list[dict]:
    if path is None:
        return []
    payload = json.loads(path.read_text(encoding="utf-8"))
    entries = payload.get("books", payload)
    if not isinstance(entries, list):
        raise SystemExit("source manifest must contain a books array")
    return entries


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:16060")
    parser.add_argument("--expected-books", type=int, default=8)
    parser.add_argument("--timeout", type=int, default=240)
    parser.add_argument("--username", default=os.environ.get("GRIMMORY_TEST_USERNAME", USERNAME))
    parser.add_argument("--password", default=os.environ.get("GRIMMORY_TEST_PASSWORD", PASSWORD))
    parser.add_argument("--email", default="visual-fixture@example.invalid")
    parser.add_argument("--name", default="Visual Fixture")
    parser.add_argument("--library-name", default=LIBRARY_NAME)
    parser.add_argument("--books-path", default="/books")
    parser.add_argument("--source-manifest", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    base = args.url.rstrip("/")

    status = request(base, "/api/v1/setup/status")
    if not bool(status.get("data")):
        request(
            base,
            "/api/v1/setup",
            "POST",
            {
                "username": args.username,
                "email": args.email,
                "name": args.name,
                "password": args.password,
            },
        )
        print("created real-server fixture account")

    login = request(
        base,
        "/api/v1/auth/login",
        "POST",
        {"username": args.username, "password": args.password},
    )
    token = login["accessToken"]
    libraries = unwrap(request(base, "/api/v1/libraries", token=token))
    libraries = libraries if isinstance(libraries, list) else []
    library = next((item for item in libraries if item.get("name") == args.library_name), None)
    if library is None:
        library = request(
            base,
            "/api/v1/libraries",
            "POST",
            {
                "name": args.library_name,
                "paths": [{"path": args.books_path}],
                "watch": False,
                "formatPriority": ["EPUB"],
                "allowedFormats": ["EPUB"],
                "metadataSource": "EMBEDDED",
                "organizationMode": "BOOK_PER_FILE",
            },
            token,
        )
        library = unwrap(library)
        print(f"created real-server library {library.get('id')}")

    sources = source_entries(args.source_manifest)
    expected_names = {str(entry["stagedName"]) for entry in sources}
    deadline = time.monotonic() + args.timeout
    last_count = -1
    content: list[dict] = []
    while time.monotonic() < deadline:
        page = request(base, "/api/v1/books/page?page=0&size=100", token=token)
        content = page_content(page)
        last_count = len(content)
        discovered_names = set().union(*(file_names(book) for book in content)) if content else set()
        names_ready = not expected_names or expected_names.issubset(discovered_names)
        if last_count >= args.expected_books and names_ready:
            print(f"real Grimmory imported {last_count} book(s); ready at {base}")
            break
        time.sleep(2)
    else:
        missing = sorted(expected_names - discovered_names)
        raise SystemExit(
            f"real Grimmory became healthy but imported only {last_count}/{args.expected_books} "
            f"books within {args.timeout}s; missing staged files: {missing}"
        )

    if args.output:
        imported = []
        by_name = {
            name: book for book in content for name in file_names(book)
        }
        for source in sources:
            match = by_name.get(str(source["stagedName"]))
            if match is None:
                raise SystemExit(f"scanner result missing {source['stagedName']}")
            imported.append(
                {
                    **source,
                    "serverBookId": match.get("id"),
                    "serverTitle": match.get("title")
                    or (match.get("metadata") or {}).get("title"),
                    "serverFileNames": sorted(file_names(match)),
                }
            )
        output = {
            "schemaVersion": 1,
            "library": {"id": library.get("id"), "name": library.get("name")},
            "books": imported,
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        temporary = args.output.with_suffix(args.output.suffix + ".tmp")
        temporary.write_text(json.dumps(output, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        temporary.replace(args.output)
        print(f"import manifest: {args.output}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        raise SystemExit(f"Grimmory HTTP {exc.code}: {detail}") from exc
