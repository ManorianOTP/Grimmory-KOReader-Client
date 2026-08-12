#!/usr/bin/env python3
"""Read-only verification of KOReader's full-server acceptance effects.

The input artifacts and runtime are private.  The emitted report deliberately
contains aliases and boolean checks only: no credentials, server URL, book
titles, annotation text, generated IDs, EPUB hashes, or CFIs.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
from typing import Any
import urllib.error
import urllib.request


class VerificationError(RuntimeError):
    pass


INLINE_XPOINTER_ELEMENTS = {
    "a", "abbr", "b", "bdi", "bdo", "cite", "code", "data", "dfn",
    "em", "font", "i", "kbd", "mark", "q", "rp", "rt", "ruby", "s",
    "samp", "small", "span", "strong", "sub", "sup", "time", "u", "var",
}
XPOINTER_ELEMENT = re.compile(r"[A-Za-z][A-Za-z0-9:_-]*(?:\[[1-9][0-9]*\])?")
XPOINTER_TEXT = re.compile(r"text\(\)(?:\[[1-9][0-9]*\])?")


def parse_selection_xpointer(value: object) -> dict[str, str] | None:
    """Parse the exact CREngine text-leaf form recorded by the device lane."""
    if not isinstance(value, str) or not value.startswith("/"):
        return None
    match = re.fullmatch(r"(.+)\.([0-9]+)", value)
    if not match:
        return None
    text_path, offset = match.groups()
    segments = text_path[1:].split("/")
    if (len(segments) < 5 or segments[0] != "body"
            or not re.fullmatch(r"DocFragment\[[1-9][0-9]*\]", segments[1])
            or segments[2] != "body" or not XPOINTER_TEXT.fullmatch(segments[-1])):
        return None
    if any(not XPOINTER_ELEMENT.fullmatch(segment) for segment in segments[3:-1]):
        return None
    block_segments = segments[:-1]
    inline_segments: list[str] = []
    while len(block_segments) > 3:
        tag = block_segments[-1].split("[", 1)[0].lower()
        if tag not in INLINE_XPOINTER_ELEMENTS:
            break
        inline_segments.insert(0, block_segments.pop())
    if len(block_segments) <= 3:
        return None
    return {
        "textPath": text_path,
        "blockPath": "/" + "/".join(block_segments),
        "inlinePath": "/".join(inline_segments),
        "offset": offset,
    }


def require_device_selection_evidence(device: dict, alias: str) -> dict:
    selection = device.get("selection")
    require(isinstance(selection, dict),
            f"{alias}: Jump phase omitted device selection evidence")
    start_xpointer = parse_selection_xpointer(selection.get("pos0"))
    end_xpointer = parse_selection_xpointer(selection.get("pos1"))
    require(start_xpointer is not None and end_xpointer is not None,
            f"{alias}: device selection omitted exact well-formed XPointers")
    require(selection.get("pos0") != selection.get("pos1"),
            f"{alias}: device selection XPointers are collapsed")
    require(start_xpointer["blockPath"] == selection.get("startBlockPath")
            and end_xpointer["blockPath"] == selection.get("endBlockPath")
            and start_xpointer["inlinePath"] == selection.get("startInlinePath")
            and end_xpointer["inlinePath"] == selection.get("endInlinePath"),
            f"{alias}: raw XPointers differ from recorded selection topology")
    return selection


class Client:
    def __init__(self, base_url: str, username: str, password: str) -> None:
        self.base_url = base_url.rstrip("/")
        self.username = username
        self.password = password
        self.token: str | None = None

    def request(self, path: str, method: str = "GET", body: dict | None = None) -> Any:
        payload = json.dumps(body).encode("utf-8") if body is not None else None
        headers = {"Accept": "application/json"}
        if body is not None:
            headers["Content-Type"] = "application/json"
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        request = urllib.request.Request(
            self.base_url + path, data=payload, headers=headers, method=method
        )
        try:
            response = urllib.request.urlopen(request, timeout=30)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            raw = response.read()
            if int(response.status) != 200:
                raise VerificationError(f"GET {path} returned HTTP {response.status}")
            return json.loads(raw) if raw else None

    def login(self) -> None:
        result = self.request(
            "/api/v1/auth/login",
            "POST",
            {"username": self.username, "password": self.password},
        )
        if not isinstance(result, dict) or not result.get("accessToken"):
            raise VerificationError("login did not return an access token")
        self.token = str(result["accessToken"])


def load_object(path: Path, label: str) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise VerificationError(f"cannot read {label}: {error}") from error
    if not isinstance(value, dict):
        raise VerificationError(f"{label} must be a JSON object")
    return value


def require(condition: bool, message: str) -> None:
    if not condition:
        raise VerificationError(message)


def as_items(value: Any) -> list[dict]:
    if isinstance(value, list):
        return [item for item in value if isinstance(item, dict)]
    if isinstance(value, dict) and isinstance(value.get("content"), list):
        return [item for item in value["content"] if isinstance(item, dict)]
    raise VerificationError("expected an array or paged content response")


def same_server_number(left: Any, right: Any) -> bool:
    try:
        return progress_percentage_at_server_precision(left) == \
            progress_percentage_at_server_precision(right)
    except (TypeError, ValueError):
        return False


def progress_percentage_at_server_precision(value: Any) -> float:
    """Mirror the browser verifier's pinned toPrecision(6) server contract."""
    return float(format(float(value), ".6g"))


def utc_timestamp(epoch_seconds: Any) -> str:
    return datetime.fromtimestamp(
        int(epoch_seconds), tz=timezone.utc
    ).strftime("%Y-%m-%dT%H:%M:%SZ")


def session_matches(remote: dict, expected: dict) -> bool:
    def field(camel: str, snake: str) -> Any:
        return remote.get(camel, remote.get(snake))

    return (
        int(field("bookId", "book_id") or -1) == int(expected.get("bookId") or -2)
        and str(field("bookType", "book_type")) == str(expected.get("bookType"))
        and str(field("startTime", "start_time")) == str(expected.get("startTime"))
        and str(field("endTime", "end_time")) == str(expected.get("endTime"))
        and int(field("durationSeconds", "duration_seconds") or -1)
            == int(expected.get("durationSeconds") or -2)
        and same_server_number(field("startProgress", "start_progress"), expected.get("startProgress"))
        and same_server_number(field("endProgress", "end_progress"), expected.get("endProgress"))
        and same_server_number(field("progressDelta", "progress_delta"), expected.get("progressDelta"))
        and str(field("startLocation", "start_location") or "")
            == str(expected.get("startLocation") or "")
        and str(field("endLocation", "end_location") or "")
            == str(expected.get("endLocation") or "")
    )


def sessions_created_since(remote: list[dict], baseline_ids: list[Any]) -> list[dict]:
    """Select by stable identity; an old matching payload is not a new result."""
    baseline = {str(value) for value in baseline_ids}
    return [item for item in remote if str(item.get("id")) not in baseline]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--session-baseline", type=Path, required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--alias", action="append", default=[])
    args = parser.parse_args()

    runtime = load_object(args.runtime.resolve(), "runtime")
    source_fingerprint = runtime.get("sourceFingerprint")
    require(isinstance(source_fingerprint, str) and bool(source_fingerprint),
            "runtime omitted the acceptance source fingerprint")
    checkpoint = load_object(args.checkpoint.resolve(), "checkpoint")
    session_baseline = load_object(
        args.session_baseline.resolve(), "reading-session baseline"
    )
    require(session_baseline.get("sourceFingerprint") == source_fingerprint,
            "reading-session baseline used a mixed source fingerprint")
    baseline_sessions = session_baseline.get("sessions")
    require(isinstance(baseline_sessions, dict),
            "reading-session baseline omitted its per-book ID map")
    checkpoint_by_alias = {
        item.get("alias"): item
        for item in checkpoint.get("checkpoints", [])
        if isinstance(item, dict) and item.get("journey") == "web-to-koreader-producer"
    }
    books = runtime.get("books") or []
    require(len(books) == 9, "runtime must describe synthetic plus all eight real EPUBs")
    if args.alias:
        requested = set(args.alias)
        available = {str(book.get("alias") or "") for book in books}
        require(requested <= available,
                "unknown requested aliases: " + ", ".join(sorted(requested - available)))
        books = [book for book in books if book.get("alias") in requested]

    client = Client(
        str(runtime.get("baseUrl") or ""),
        str(runtime.get("username") or ""),
        str(runtime.get("password") or ""),
    )
    client.login()
    rows: list[dict[str, Any]] = []
    for descriptor in books:
        alias = str(descriptor.get("alias") or "")
        require(alias in checkpoint_by_alias, f"{alias}: missing browser checkpoint")
        jump = load_object(
            args.input.resolve() / f"reader-jump-{alias}" / f"{alias}.json",
            f"{alias} jump result",
        )
        sync_here = load_object(
            args.input.resolve() / f"reader-sync-here-{alias}" / f"{alias}.json",
            f"{alias} Sync Here result",
        )
        require(jump.get("passed") is True, f"{alias}: Jump phase was not green")
        require(sync_here.get("passed") is True, f"{alias}: Sync Here phase was not green")
        require((jump.get("provenance") or {}).get("sourceFingerprint") == source_fingerprint,
                f"{alias}: Jump phase used a mixed source fingerprint")
        require((sync_here.get("provenance") or {}).get("sourceFingerprint") == source_fingerprint,
                f"{alias}: Sync Here phase used a mixed source fingerprint")
        jump_observed = jump.get("observations") or {}
        sync_observed = sync_here.get("observations") or {}
        device = jump_observed.get("deviceAnnotation") or {}
        adopted = sync_observed.get("deviceAnnotationAdopted") or {}
        expected_progress = sync_observed.get("syncHere") or {}
        require(device.get("id") is not None,
                f"{alias}: Jump phase omitted the server annotation identity")
        require(str(device.get("cfi") or "").startswith("epubcfi("),
                f"{alias}: Jump phase omitted the device annotation CFI")
        require(isinstance(device.get("text"), str) and bool(device.get("text")),
                f"{alias}: Jump phase omitted the complete device annotation text")
        require_device_selection_evidence(device, alias)
        require(str(adopted.get("id")) == str(device.get("id"))
                and adopted.get("cfi") == device.get("cfi")
                and adopted.get("text") == device.get("text"),
                f"{alias}: fresh reader did not adopt the exact device annotation")
        require(str(expected_progress.get("cfi") or "").startswith("epubcfi("),
                f"{alias}: Sync Here phase omitted the final CFI")

        book_id = int(descriptor["serverBookId"])
        progress = client.request(f"/api/v1/app/books/{book_id}/progress")
        remote = progress.get("epubProgress") if isinstance(progress, dict) else None
        require(isinstance(remote, dict), f"{alias}: server omitted EPUB progress")
        require(remote.get("cfi") == expected_progress.get("cfi"),
                f"{alias}: server CFI differs from the Sync Here position")
        require(remote.get("href") is None,
                f"{alias}: KOReader Sync Here must preserve the exact absent href")
        expected_serialized_percentage = progress_percentage_at_server_precision(
            expected_progress.get("percentage")
        )
        actual_serialized_percentage = float(remote.get("percentage"))
        require(actual_serialized_percentage == expected_serialized_percentage,
                f"{alias}: server percentage {actual_serialized_percentage} differs "
                f"from exact Sync Here persistence {expected_serialized_percentage}")

        annotations = as_items(client.request(f"/api/v1/annotations/book/{book_id}"))
        browser_id = (checkpoint_by_alias[alias].get("annotation") or {}).get("id")
        remaining_ids = {str(item.get("id")) for item in annotations}
        require(str(browser_id) not in remaining_ids,
                f"{alias}: browser annotation was not deleted through KOReader")
        require(len(annotations) == 1,
                f"{alias}: browser handoff requires exactly one retained device annotation")
        retained = annotations[0]
        require(str(retained.get("id")) == str(device.get("id")),
                f"{alias}: retained server annotation identity differs from KOReader")
        require(retained.get("cfi") == device.get("cfi"),
                f"{alias}: retained server annotation CFI differs from KOReader")
        require(retained.get("text") == device.get("text"),
                f"{alias}: retained server annotation text differs from KOReader")

        session_expected = jump_observed.get("sessionExpected") is True
        sessions = as_items(client.request(
            f"/api/v1/reading-sessions/book/{book_id}?page=0&size=100"
        ))
        baseline_session_ids = baseline_sessions.get(alias)
        require(isinstance(baseline_session_ids, list),
                f"{alias}: pre-KOReader snapshot omitted the session IDs")
        require(all(item.get("id") is not None for item in sessions),
                f"{alias}: reading-session response omitted stable IDs")
        new_sessions = sessions_created_since(sessions, baseline_session_ids)
        if session_expected:
            fingerprint = jump_observed.get("sessionFingerprint")
            require(isinstance(fingerprint, dict),
                    f"{alias}: KOReader result omitted its session fingerprint")
            require(int(fingerprint.get("durationSeconds") or 0) >= 30,
                    f"{alias}: KOReader session did not cross the 30-second threshold")
            require(isinstance(fingerprint.get("startEpochSeconds"), int)
                    and isinstance(fingerprint.get("endEpochSeconds"), int),
                    f"{alias}: KOReader fingerprint omitted independent wall-clock bounds")
            expected_session = dict(fingerprint)
            expected_session["startTime"] = utc_timestamp(
                fingerprint["startEpochSeconds"]
            )
            expected_session["endTime"] = utc_timestamp(
                fingerprint["endEpochSeconds"]
            )
            require(len(new_sessions) == 1,
                    f"{alias}: expected exactly one newly created KOReader session, "
                    f"found {len(new_sessions)}")
            require(session_matches(new_sessions[0], expected_session),
                    f"{alias}: the newly created KOReader session differs from "
                    "the independently observed ReaderUI fingerprint")
        else:
            require(len(new_sessions) == 0,
                    f"{alias}: a session-disabled KOReader journey unexpectedly "
                    f"created {len(new_sessions)} session(s)")

        rows.append({
            "alias": alias,
            "exactProgress": True,
            "exactAbsentHref": True,
            "browserAnnotationDeleted": True,
            "deviceAnnotationExactOnServer": True,
            "deviceAnnotationPendingWeb": True,
            "sessionExpected": session_expected,
            "sessionVerified": session_expected,
            "newSessionCountExact": True,
        })

    report = {
        "schemaVersion": 1,
        "passed": True,
        "bookCount": len(rows),
        "privateArtifacts": True,
        "verificationBoundary": "read-only-full-server-api-before-web-consumer",
        "sourceFingerprint": source_fingerprint,
        "books": rows,
    }
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"KOReader server verification passed: {len(rows)} selected book(s)")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (KeyError, TypeError, ValueError, VerificationError,
            urllib.error.URLError) as error:
        print(f"koreader-reader-verification: {error}", file=__import__("sys").stderr)
        raise SystemExit(1) from error
