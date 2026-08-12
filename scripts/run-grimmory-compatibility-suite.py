#!/usr/bin/env python3
"""Run browser, KOReader, then fixture-parity consumers on one full server."""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
from pathlib import Path
import re
import runpy
import shutil
import subprocess
import sys
from typing import Sequence


class SuiteError(RuntimeError):
    pass


def validate_realism_policy(repo: Path) -> None:
    """Run the repository's exact source/outcome contract before consumers."""
    checker = repo / "scripts" / "check-test-realism.py"
    try:
        namespace = runpy.run_path(str(checker))
        namespace["validate_repository"](repo)
    except Exception as exc:
        raise SuiteError(f"acceptance realism policy failed: {exc}") from exc


NODE_PATH_ENV = "GRIMMORY_COMPAT_NODE"
NODE_VERSION_ENV = "GRIMMORY_COMPAT_NODE_VERSION"
NODE_VERSION_RE = re.compile(r"^v\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$")
NODE_MIN_MAJOR = 20


SOURCE_DIRECTORIES = (
    Path("grimmory.koplugin"),
    Path("grimmory_sync.koplugin"),
    Path("tests/compatibility"),
    Path("tests/emulator/acceptance_driver.koplugin"),
)

SOURCE_FILES = (
    Path("scripts/grimmory-metadata-cache.py"),
    Path("scripts/grimmory-real-stack.py"),
    Path("scripts/koreader_acceptance_report.py"),
    Path("scripts/private_epub_sources.py"),
    Path("scripts/run-grimmory-compatibility-suite.py"),
    Path("scripts/run-koreader-real-server-acceptance.sh"),
    Path("scripts/seed-grimmory-real-server.py"),
    Path("scripts/setup-koreader-emulator.sh"),
    Path("scripts/snapshot-koreader-session-baseline.py"),
    Path("scripts/verify-koreader-metadata-artifacts.py"),
    Path("scripts/verify-koreader-reader-artifacts.py"),
    Path("tests/emulator/grimmory-real-server.compose.yml"),
    Path("tests/emulator/grimmory_fixture_server.py"),
    Path("tests/emulator/grimmory_library_fixture.json"),
    Path("tests/emulator/koreader-emulator.env"),
    Path("tests/emulator/settings.reader.lua"),
)

SOURCE_EXCLUDED_PARTS = {"node_modules", "__pycache__"}
SOURCE_EXCLUDED_SUFFIXES = {".pyc", ".pyo"}


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def acceptance_source_provenance(repo: Path) -> dict:
    """Fingerprint every executable input used by the acceptance consumers."""
    selected: set[Path] = set()
    for relative in SOURCE_DIRECTORIES:
        directory = repo / relative
        if not directory.is_dir():
            raise SuiteError(f"acceptance source directory is missing: {relative.as_posix()}")
        members = [
            item for item in directory.rglob("*")
            if item.is_file()
            and not SOURCE_EXCLUDED_PARTS.intersection(item.relative_to(repo).parts)
            and item.suffix.lower() not in SOURCE_EXCLUDED_SUFFIXES
        ]
        if not members:
            raise SuiteError(f"acceptance source directory is empty: {relative.as_posix()}")
        selected.update(members)
    for relative in SOURCE_FILES:
        source = repo / relative
        if not source.is_file():
            raise SuiteError(f"acceptance source file is missing: {relative.as_posix()}")
        selected.add(source)

    files = []
    for source in sorted(selected, key=lambda item: item.relative_to(repo).as_posix()):
        value = source.read_bytes()
        files.append({
            "path": source.relative_to(repo).as_posix(),
            "bytes": len(value),
            "sha256": sha256_bytes(value),
        })
    canonical = json.dumps(
        {"schemaVersion": 1, "files": files},
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return {
        "schemaVersion": 1,
        "algorithm": "sha256(canonical-json(path,bytes,sha256)[])",
        "fingerprint": sha256_bytes(canonical),
        "fileCount": len(files),
        "files": files,
    }


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def artifact_source_fingerprint(path: Path) -> str | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    nested = value.get("provenance") if isinstance(value, dict) else None
    if isinstance(nested, dict) and nested.get("sourceFingerprint"):
        return str(nested["sourceFingerprint"])
    if isinstance(value, dict) and value.get("sourceFingerprint"):
        return str(value["sourceFingerprint"])
    return None


def validate_artifact_source_fingerprints(
    output: Path, runtime: dict, statuses: dict, expected: str,
) -> list[str]:
    """Reject green lanes whose process artifacts are missing or mixed-source."""
    required: list[Path] = []
    if statuses["browserJourneysStatus"] == 0:
        required.append(output / "browser" / "journeys" / "web-reader-checkpoints.json")
    if statuses["browserProducerStatus"] == 0:
        required.append(output / "browser" / "producer" / "web-reader-checkpoints.json")
    if statuses["koreaderStatus"] == 0:
        required.extend([
            output / "koreader" / "metadata" / "metadata.json",
            output / "koreader" / "metadata" / "cover-verification.json",
            output / "koreader" / "reader-server-verification.json",
        ])
        for book in runtime.get("books") or []:
            alias = str(book.get("alias") or "")
            required.extend([
                output / "koreader" / f"reader-jump-{alias}" / f"{alias}.json",
                output / "koreader" / f"reader-sync-here-{alias}" / f"{alias}.json",
            ])
    if statuses["deviceBrowserStatus"] == 0:
        required.append(
            output / "browser" / "device-consumer" / "web-reader-checkpoints.json"
        )
    if statuses["parityStatus"] == 0:
        required.append(output / "parity" / "report.json")

    failures = []
    for artifact in required:
        actual = artifact_source_fingerprint(artifact)
        label = artifact.relative_to(output).as_posix()
        if actual is None:
            failures.append(f"{label}: missing source fingerprint")
        elif actual != expected:
            failures.append(f"{label}: mixed source fingerprint")
    return failures


def run(command: Sequence[str], cwd: Path) -> int:
    print("+", " ".join(command), flush=True)
    return subprocess.run(list(command), cwd=cwd, check=False).returncode


def validate_node_executable(
    raw_path: str | Path,
    repo: Path,
    *,
    expected_version: str | None = None,
) -> tuple[str, str]:
    path = Path(raw_path).expanduser()
    if not path.is_absolute():
        raise SuiteError("Node.js executable must be an absolute path")
    try:
        resolved = path.resolve(strict=True)
    except (OSError, RuntimeError) as exc:
        raise SuiteError(f"Node.js executable does not exist: {path}") from exc
    if not resolved.is_file():
        raise SuiteError(f"Node.js executable is not a file: {resolved}")
    if os.name != "nt" and not os.access(resolved, os.X_OK):
        raise SuiteError(f"Node.js executable is not executable: {resolved}")
    if os.name != "nt" and resolved.suffix.lower() == ".exe":
        raise SuiteError(
            "a Linux suite controller requires native Linux Node.js, not node.exe"
        )
    try:
        result = subprocess.run(
            [str(resolved), "--version"],
            cwd=repo,
            check=False,
            text=True,
            encoding="utf-8",
            errors="replace",
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except OSError as exc:
        raise SuiteError(f"could not execute Node.js: {resolved}") from exc
    version = (result.stdout or "").strip()
    if result.returncode != 0 or not NODE_VERSION_RE.fullmatch(version):
        detail = (result.stderr or result.stdout or "no version output").strip()
        raise SuiteError(f"Node.js validation failed for {resolved}: {detail}")
    if int(version[1:].split(".", 1)[0]) < NODE_MIN_MAJOR:
        raise SuiteError(
            f"Node.js {NODE_MIN_MAJOR}+ is required; {resolved} reported {version}"
        )
    if expected_version and version != expected_version:
        raise SuiteError(
            f"Node.js version changed after stack preflight: {expected_version} -> {version}"
        )
    return str(resolved), version


def wsl_path(path: Path) -> str:
    result = subprocess.run(
        ["wsl.exe", "wslpath", "-a", str(path)],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    )
    return result.stdout.strip()


def validate_runtime(path: Path) -> dict:
    value = json.loads(path.read_text(encoding="utf-8"))
    books = value.get("books") or []
    if len(books) != 9:
        raise SuiteError(f"enriched runtime requires 9 books, found {len(books)}")
    if sum(book.get("kind") == "synthetic" for book in books) != 1:
        raise SuiteError("enriched runtime requires one synthetic book")
    if sum(book.get("kind") in {"real", "private", "private-real-epub"} for book in books) != 8:
        raise SuiteError("enriched runtime requires eight real EPUBs")
    missing = [book.get("alias") for book in books if "expectedKoreaderMetadata" not in book]
    if missing:
        raise SuiteError("metadata replay is required before the suite: " + ", ".join(missing))
    metadata_cache = value.get("metadataCache") or {}
    if metadata_cache.get("providerNetworkUsed") is not False:
        raise SuiteError("acceptance metadata must be replayed without provider network calls")
    for book in books:
        if book.get("kind") not in {"real", "private", "private-real-epub"}:
            continue
        selection = (book.get("expectedMetadata") or {}).get("providerSelection") or {}
        if selection.get("captureMethod") != "grimmory-web-metadata-selection":
            raise SuiteError(f"{book.get('alias')}: missing real Grimmory metadata capture method")
        if not selection.get("provider") or not selection.get("providerItemId"):
            raise SuiteError(f"{book.get('alias')}: missing captured provider identity")
    return value


def validate_checkpoint(path: Path, runtime: dict) -> None:
    value = json.loads(path.read_text(encoding="utf-8"))
    entries = [
        item
        for item in value.get("checkpoints", [])
        if item.get("journey") == "web-to-koreader-producer"
    ]
    expected = {book["alias"] for book in runtime["books"]}
    actual = {item.get("alias") for item in entries}
    if len(entries) != 9 or actual != expected:
        raise SuiteError(
            "browser producer must leave exactly one checkpoint for synthetic + all 8 real EPUBs"
        )
    descriptors = {book["alias"]: book for book in runtime["books"]}
    for item in entries:
        descriptor = descriptors[item["alias"]]
        if item.get("sourceSha256") != descriptor.get("sourceSha256"):
            raise SuiteError(f"{item.get('alias')}: browser checkpoint source hash mismatch")
        if (item.get("annotation") or {}).get("selectionMethod") != "physical-mouse-drag":
            raise SuiteError(
                f"{item.get('alias')}: browser annotation was not made by a physical drag"
            )
        if not str((item.get("progress") or {}).get("cfi", "")).startswith("epubcfi("):
            raise SuiteError(f"{item.get('alias')}: producer progress omitted a real CFI")
        if not str((item.get("annotation") or {}).get("cfi", "")).startswith("epubcfi("):
            raise SuiteError(f"{item.get('alias')}: producer annotation omitted a real CFI")
        if (item.get("annotation") or {}).get("id") is None:
            raise SuiteError(f"{item.get('alias')}: producer annotation omitted server identity")


def validate_browser_outcomes(
    path: Path,
    contract_path: Path,
    expected_journeys: set[str],
    runtime_aliases: set[str],
) -> None:
    """Require the selected Playwright journeys to emit their exact outcomes."""
    value = json.loads(path.read_text(encoding="utf-8"))
    if value.get("schemaVersion") != 2:
        raise SuiteError("browser checkpoint omitted the executable outcome schema")
    emitted = value.get("outcomeContract") or {}
    if emitted.get("schemaVersion") != 1 or not isinstance(emitted.get("journeys"), list):
        raise SuiteError("browser checkpoint omitted versioned journey outcomes")
    contract = json.loads(contract_path.read_text(encoding="utf-8"))
    if contract.get("schemaVersion") != 1 or not isinstance(contract.get("journeys"), dict):
        raise SuiteError("tracked full-server outcome contract is invalid")
    records = emitted["journeys"]
    names = [record.get("journey") for record in records if isinstance(record, dict)]
    if len(records) != len(names) or len(names) != len(set(names)) \
            or set(names) != expected_journeys:
        raise SuiteError("browser emitted journey set differs from the selected contract")
    tracked = contract["journeys"]
    if not expected_journeys.issubset(tracked):
        raise SuiteError("selected browser journey is absent from the tracked contract")
    for record in records:
        journey = record["journey"]
        if set(record) != {"schemaVersion", "journey", "coverageAliases", "outcomes"} \
                or record.get("schemaVersion") != 1:
            raise SuiteError(f"{journey}: emitted outcome record has the wrong shape")
        coverage_aliases = record.get("coverageAliases")
        if not isinstance(coverage_aliases, list) \
                or any(not isinstance(alias, str) or not alias for alias in coverage_aliases) \
                or len(coverage_aliases) != len(set(coverage_aliases)):
            raise SuiteError(f"{journey}: emitted coverage aliases are invalid")
        coverage = tracked[journey].get("coverage")
        expected_aliases = runtime_aliases if coverage == "all-runtime-books" else set()
        if coverage not in {"none", "all-runtime-books"} \
                or set(coverage_aliases) != expected_aliases:
            raise SuiteError(f"{journey}: emitted book coverage differs from the contract")
        outcomes = record.get("outcomes")
        required = tracked[journey].get("requiredOutcomes")
        if not isinstance(outcomes, dict) or set(outcomes) != set(required or []):
            raise SuiteError(f"{journey}: emitted outcome names differ from the contract")
        if any(result is not True for result in outcomes.values()):
            raise SuiteError(f"{journey}: emitted outcome did not pass")


def validate_device_browser_checkpoint(path: Path, runtime: dict) -> None:
    value = json.loads(path.read_text(encoding="utf-8"))
    expected_journey = (
        "koreader-to-web-consumer resolves the complete device-origin range "
        "before visible cleanup"
    )
    expected_runtime_outcomes = {
        "genuine-koreader-highlight-uploaded-through-production-hooks",
        "fresh-koreader-adopted-exact-device-annotation",
        "live-server-text-equals-complete-koreader-selection",
        "visible-sidebar-row-has-exact-whole-text-identity",
        "device-cfi-resolves-to-noncollapsed-foliate-dom-range",
        "foliate-range-text-equals-complete-koreader-and-server-text",
        "all-epub-selection-crosses-inline-element-boundary",
        "all-epub-selection-stays-in-one-leaf-block",
        "selection-has-no-control-separators",
        "cleanup-occurs-only-after-three-way-text-equality",
        "server-empty-after-visible-browser-cleanup",
        "synthetic-plus-eight-real-epubs-covered-exactly-once",
    }
    outcome_contract = value.get("outcomeContract") or {}
    journey_contracts = outcome_contract.get("journeys") or []
    matching_contracts = [
        item for item in journey_contracts
        if isinstance(item, dict) and item.get("journey") == expected_journey
    ]
    if value.get("schemaVersion") != 2 \
            or outcome_contract.get("schemaVersion") != 1 \
            or len(matching_contracts) != 1:
        raise SuiteError("device-to-web artifact omitted its versioned runtime outcome contract")
    runtime_outcomes = matching_contracts[0].get("outcomes") or {}
    if set(runtime_outcomes) != expected_runtime_outcomes \
            or any(result is not True for result in runtime_outcomes.values()):
        raise SuiteError("device-to-web named runtime outcomes are incomplete")
    entries = [
        item for item in value.get("checkpoints", [])
        if item.get("journey") == "koreader-to-web-consumer"
    ]
    expected = {book["alias"] for book in runtime["books"]}
    actual = {item.get("alias") for item in entries}
    if len(entries) != 9 or actual != expected:
        raise SuiteError(
            "device-to-web consumer must record synthetic + all 8 real EPUBs exactly once"
        )
    descriptors = {book["alias"]: book for book in runtime["books"]}
    required_invariants = {
        "device_selection_uploaded_via_production_hooks",
        "fresh_koreader_adopted_exact_device_annotation",
        "live_server_text_equals_complete_koreader_selection",
        "visible_sidebar_row_has_exact_whole_text_identity",
        "foliate_device_cfi_resolves_noncollapsed_dom_range",
        "foliate_dom_range_text_equals_complete_koreader_selection",
        "foliate_dom_range_text_equals_live_server_text",
        "inline_boundary_requirement_enforced_for_all_epubs",
        "same_leaf_block_requirement_enforced_for_all_epubs",
        "control_separator_free_selection",
        "cleanup_occurs_only_after_three_way_text_equality",
        "server_empty_after_visible_cleanup",
    }
    for item in entries:
        alias = item["alias"]
        if item.get("checkpointContract") != "device-to-web-exact-range/v2" \
                or item.get("coverageSet") != "synthetic-plus-eight-real-epubs":
            raise SuiteError(f"{alias}: device-to-web outcome contract is missing or changed")
        if item.get("sourceSha256") != descriptors[alias].get("sourceSha256"):
            raise SuiteError(f"{alias}: device-to-web source hash mismatch")
        producer = item.get("producer") or {}
        consumer = item.get("consumer") or {}
        selected = item.get("selectedText") or {}
        if producer.get("realSaveHighlightAction") is not True \
                or producer.get("productionUploadHook") is not True \
                or producer.get("freshReaderExactAdoption") is not True:
            raise SuiteError(f"{alias}: device producer provenance is incomplete")
        if consumer.get("exactKoreaderServerDomText") is not True \
                or consumer.get("visibleCleanupAfterResolution") is not True \
                or consumer.get("serverEmptyAfterCleanup") is not True \
                or consumer.get("endpointsAreTextNodes") is not True \
                or consumer.get("sameLeafBlock") is not True \
                or consumer.get("acceptsSameLeafBlockInlineRange") is not True \
                or consumer.get("startLeafBlockPath") != consumer.get("endLeafBlockPath"):
            raise SuiteError(f"{alias}: device-to-web exact oracle or cleanup checkpoint failed")
        if selected.get("hasSmartQuote") is not True:
            raise SuiteError(f"{alias}: selection omitted the required smart punctuation")
        if selected.get("hasNonAscii") is not True:
            raise SuiteError(f"{alias}: non-ASCII regression input was not preserved")
        if selected.get("hasControlSeparators") is not False \
                or not isinstance(selected.get("utf8Bytes"), int) \
                or not 5 <= selected["utf8Bytes"] <= 500:
            raise SuiteError(f"{alias}: selection length or control-separator oracle failed")
        producer_selection = producer.get("selection") or {}
        if producer_selection.get("crossesInlineBoundary") is not True \
                or producer_selection.get("sameRenderedBlock") is not True \
                or producer_selection.get("startBlockPath") != producer_selection.get("endBlockPath") \
                or producer_selection.get("startInlinePath") == producer_selection.get("endInlinePath") \
                or consumer.get("crossesInlineElementBoundary") is not True:
            raise SuiteError(f"{alias}: same-block inline boundary was not exercised")
        invariants = item.get("invariants") or {}
        if set(invariants) != required_invariants \
                or any(value is not True for value in invariants.values()):
            raise SuiteError(f"{alias}: device-to-web named invariants are incomplete")


def koreader_command(repo: Path, runtime: Path, checkpoint: Path, output: Path) -> list[str]:
    script = repo / "scripts" / "run-koreader-real-server-acceptance.sh"
    if os.name == "nt":
        return [
            "wsl.exe",
            "--exec",
            "bash",
            wsl_path(script),
            "--runtime",
            wsl_path(runtime),
            "--checkpoint",
            wsl_path(checkpoint),
            "--output",
            wsl_path(output),
        ]
    return [
        "bash",
        str(script),
        "--runtime",
        str(runtime),
        "--checkpoint",
        str(checkpoint),
        "--output",
        str(output),
    ]


def write_suite_report(output: Path, summary: dict) -> None:
    links = [
        (
            "Browser journeys",
            summary["browserJourneys"],
            output / "browser" / "journeys" / "report" / "index.html",
        ),
        (
            "Browser checkpoint producer",
            summary["browserProducer"],
            output / "browser" / "producer" / "report" / "index.html",
        ),
        (
            "Browser journey runtime outcomes",
            summary["browserJourneys"],
            output / "browser" / "journeys" / "web-reader-checkpoints.json",
        ),
        (
            "Exact live browser checkpoint",
            summary["checkpoint"],
            output / "browser" / "producer" / "web-reader-checkpoints.json",
        ),
        ("KOReader journeys", summary["koreader"], output / "koreader" / "report" / "index.html"),
        ("Exact server handoff", summary["koreader"], output / "koreader" / "reader-server-verification.json"),
        (
            "KOReader to visible web reader",
            summary["deviceBrowser"],
            output / "browser" / "device-consumer" / "report" / "index.html",
        ),
        (
            "Exact device/web checkpoints",
            summary["deviceBrowser"],
            output / "browser" / "device-consumer" / "web-reader-checkpoints.json",
        ),
        ("Cover fingerprints", summary["koreader"], output / "koreader" / "metadata" / "cover-verification.json"),
        ("Fixture/full-server parity", summary["parity"], output / "parity" / "report.json"),
        (
            "Acceptance source provenance",
            summary["sourceProvenance"],
            output / "source-provenance.json",
        ),
        ("Machine summary", "available", output / "suite-summary.json"),
    ]
    rows = []
    for label, state, path in links:
        exists = path.is_file()
        relative = path.relative_to(output).as_posix()
        destination = (
            f'<a href="{html.escape(relative)}">Open</a>' if exists else "Not produced"
        )
        css = "pass" if state in {"passed", "available"} and exists else "fail"
        rows.append(
            f'<tr class="{css}"><th>{html.escape(label)}</th>'
            f'<td>{html.escape(str(state))}</td><td>{destination}</td></tr>'
        )
    document = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Grimmory compatibility suite</title>
<style>
body{{font:16px system-ui,sans-serif;max-width:900px;margin:2rem auto;padding:0 1rem;color:#171717}}
table{{border-collapse:collapse;width:100%}} th,td{{text-align:left;padding:.8rem;border-bottom:1px solid #ccc}}
.pass th{{border-left:7px solid #26834a}} .fail th{{border-left:7px solid #b42318}}
.notice{{padding:1rem;background:#f2f2f2;border-radius:8px}} a{{font-weight:650}}
</style></head><body><h1>Grimmory compatibility suite</h1>
<p class="notice">Private review artifacts from one disposable full-server run.
Screenshots are visual evidence, not strict pixel baselines.</p>
<table><thead><tr><th>Lane</th><th>Status</th><th>Artifact</th></tr></thead>
<tbody>{''.join(rows)}</tbody></table></body></html>"""
    (output / "index.html").write_text(document, encoding="utf-8")


def run_consumers(
    repo: Path,
    node: str,
    runtime_path: Path,
    runtime: dict,
    output: Path,
) -> dict:
    """Run the mutating consumers in the only safe order for one fresh stack."""
    browser_root = output / "browser"
    journeys_output = browser_root / "journeys"
    producer_output = browser_root / "producer"
    device_consumer_output = browser_root / "device-consumer"
    outcome_contract = repo / "tests" / "compatibility" / "full_server_outcome_contracts.json"
    tracked_journeys = set(json.loads(outcome_contract.read_text(encoding="utf-8"))["journeys"])
    producer_journey = (
        "web-to-koreader-producer leaves web-origin checkpoints for the isolated KOReader consumer"
    )
    device_journey = (
        "koreader-to-web-consumer resolves the complete device-origin range before visible cleanup"
    )
    ordinary_journeys = tracked_journeys - {producer_journey, device_journey}
    runtime_aliases = {book["alias"] for book in runtime["books"]}
    browser_journeys_status = run(
        [
            node,
            str(repo / "tests" / "compatibility" / "run-web-reader.js"),
            "--runtime",
            str(runtime_path),
            "--output",
            str(journeys_output),
            "--grep-invert",
            "web-to-koreader-producer|koreader-to-web-consumer",
        ],
        repo,
    )
    browser_outcome_error: str | None = None
    if browser_journeys_status == 0:
        try:
            validate_browser_outcomes(
                journeys_output / "web-reader-checkpoints.json",
                outcome_contract,
                ordinary_journeys,
                runtime_aliases,
            )
        except (OSError, json.JSONDecodeError, SuiteError) as exc:
            browser_outcome_error = str(exc)
            browser_journeys_status = 1

    browser_producer_status: int | None = None
    checkpoint_verifier_status: int | None = None
    koreader_status: int | None = None
    device_browser_status: int | None = None
    device_browser_error: str | None = None
    checkpoint_error: str | None = None
    checkpoint = producer_output / "web-reader-checkpoints.json"
    if browser_journeys_status == 0:
        browser_producer_status = run(
            [
                node,
                str(repo / "tests" / "compatibility" / "run-web-reader.js"),
                "--runtime",
                str(runtime_path),
                "--output",
                str(producer_output),
                "--grep",
                "web-to-koreader-producer",
            ],
            repo,
        )
    if browser_producer_status == 0:
        try:
            validate_browser_outcomes(
                checkpoint, outcome_contract, {producer_journey}, runtime_aliases
            )
            validate_checkpoint(checkpoint, runtime)
        except (OSError, json.JSONDecodeError, SuiteError) as exc:
            checkpoint_error = str(exc)
        else:
            checkpoint_verifier_status = run(
                [
                    node,
                    str(
                        repo
                        / "tests"
                        / "compatibility"
                        / "verify-web-reader-checkpoints.js"
                    ),
                    "--runtime",
                    str(runtime_path),
                    "--checkpoints",
                    str(checkpoint),
                ],
                repo,
            )
    if checkpoint_verifier_status == 0:
        koreader_status = run(
            koreader_command(repo, runtime_path, checkpoint, output / "koreader"),
            repo,
        )
    if koreader_status == 0:
        device_browser_status = run(
            [
                node,
                str(repo / "tests" / "compatibility" / "run-web-reader.js"),
                "--runtime",
                str(runtime_path),
                "--output",
                str(device_consumer_output),
                "--grep",
                "koreader-to-web-consumer",
                "--koreader-output",
                str(output / "koreader"),
            ],
            repo,
        )
        if device_browser_status == 0:
            try:
                validate_browser_outcomes(
                    device_consumer_output / "web-reader-checkpoints.json",
                    outcome_contract,
                    {device_journey},
                    runtime_aliases,
                )
                validate_device_browser_checkpoint(
                    device_consumer_output / "web-reader-checkpoints.json", runtime
                )
            except (OSError, json.JSONDecodeError, SuiteError) as exc:
                device_browser_error = str(exc)
                device_browser_status = 1

    # Parity is deliberately the final consumer. It still runs when an earlier
    # UI lane is red, producing independent evidence before the outer stack
    # controller tears the one disposable server down.
    parity_status = run(
        [
            sys.executable,
            str(repo / "tests" / "compatibility" / "server_contract_parity.py"),
            "--runtime",
            str(runtime_path),
            "--output",
            str(output / "parity" / "report.json"),
        ],
        repo,
    )
    return {
        "browserJourneysStatus": browser_journeys_status,
        "browserOutcomeError": browser_outcome_error,
        "browserProducerStatus": browser_producer_status,
        "checkpointVerifierStatus": checkpoint_verifier_status,
        "checkpointError": checkpoint_error,
        "koreaderStatus": koreader_status,
        "deviceBrowserStatus": device_browser_status,
        "deviceBrowserError": device_browser_error,
        "parityStatus": parity_status,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run all full-server compatibility consumers with one runtime."
    )
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--node", type=Path)
    args = parser.parse_args()

    repo = Path(__file__).resolve().parent.parent
    runtime_path = args.runtime.resolve()
    runtime = validate_runtime(runtime_path)
    output = (args.output or (Path(runtime["runRoot"]) / "compatibility-suite")).resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise SuiteError(f"output directory must be new or empty: {output}")

    validate_realism_policy(repo)

    start_source = acceptance_source_provenance(repo)
    source_fingerprint = start_source["fingerprint"]
    existing_fingerprint = runtime.get("sourceFingerprint")
    if existing_fingerprint and existing_fingerprint != source_fingerprint:
        raise SuiteError(
            "runtime already names a different acceptance source fingerprint"
        )
    runtime["sourceFingerprint"] = source_fingerprint
    write_json(runtime_path, runtime)
    source_report = {
        **start_source,
        "status": "running",
        "startFingerprint": source_fingerprint,
        "endFingerprint": None,
        "unchangedDuringRun": None,
        "artifactPropagation": None,
        "artifactErrors": [],
    }
    write_json(output / "source-provenance.json", source_report)

    raw_node = args.node or os.environ.get(NODE_PATH_ENV)
    if not raw_node:
        raise SuiteError(
            f"Node.js must be supplied with --node or {NODE_PATH_ENV}"
        )
    node, node_version = validate_node_executable(
        raw_node,
        repo,
        expected_version=os.environ.get(NODE_VERSION_ENV),
    )
    recorded_node = ((runtime.get("consumerTools") or {}).get("node") or {})
    if recorded_node and recorded_node != {
        "executable": node,
        "version": node_version,
    }:
        raise SuiteError("Node.js does not match the outer stack preflight record")
    statuses = run_consumers(repo, node, runtime_path, runtime, output)
    end_source = acceptance_source_provenance(repo)
    source_unchanged = end_source["fingerprint"] == source_fingerprint
    artifact_source_errors = validate_artifact_source_fingerprints(
        output, runtime, statuses, source_fingerprint,
    )
    source_report.update({
        "status": "passed" if source_unchanged and not artifact_source_errors else "failed",
        "endFingerprint": end_source["fingerprint"],
        "unchangedDuringRun": source_unchanged,
        "artifactPropagation": not artifact_source_errors,
        "artifactErrors": artifact_source_errors,
    })
    write_json(output / "source-provenance.json", source_report)
    browser_journeys_status = statuses["browserJourneysStatus"]
    browser_outcome_error = statuses["browserOutcomeError"]
    browser_producer_status = statuses["browserProducerStatus"]
    checkpoint_verifier_status = statuses["checkpointVerifierStatus"]
    checkpoint_error = statuses["checkpointError"]
    koreader_status = statuses["koreaderStatus"]
    device_browser_status = statuses["deviceBrowserStatus"]
    device_browser_error = statuses["deviceBrowserError"]
    parity_status = statuses["parityStatus"]

    summary = {
        "schemaVersion": 1,
        "browserJourneys": "passed" if browser_journeys_status == 0 else "failed",
        "browserOutcomeError": browser_outcome_error,
        "browserProducer": (
            "passed" if browser_producer_status == 0
            else "failed" if browser_producer_status is not None else "skipped"
        ),
        "checkpoint": (
            "passed" if checkpoint_verifier_status == 0
            else "failed" if checkpoint_verifier_status is not None or checkpoint_error
            else "skipped"
        ),
        "koreader": (
            "passed" if koreader_status == 0 else "failed" if koreader_status is not None else "skipped"
        ),
        "deviceBrowser": (
            "passed" if device_browser_status == 0
            else "failed" if device_browser_status is not None else "skipped"
        ),
        "deviceBrowserError": device_browser_error,
        "parity": "passed" if parity_status == 0 else "failed",
        "checkpointError": checkpoint_error,
        "privateArtifacts": True,
        "sourceProvenance": source_report["status"],
        "sourceFingerprint": source_fingerprint,
    }
    write_json(output / "suite-summary.json", summary)
    write_suite_report(output, summary)
    passed = browser_journeys_status == 0 and browser_producer_status == 0 \
        and checkpoint_verifier_status == 0 and checkpoint_error is None \
        and koreader_status == 0 and device_browser_status == 0 \
        and device_browser_error is None and parity_status == 0 \
        and source_report["status"] == "passed"
    return 0 if passed else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SuiteError as exc:
        print(f"compatibility-suite: {exc}", file=sys.stderr)
        raise SystemExit(2)
