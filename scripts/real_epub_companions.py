#!/usr/bin/env python3
"""Plan and report privacy-safe real-EPUB companions for visual scenarios."""

from __future__ import annotations

import argparse
import hashlib
import html
import json
from pathlib import Path
import re
import struct
import sys


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CATALOG = ROOT / "tests/emulator/visual_driver.koplugin/visual_scenarios.lua"
DEFAULT_MAPPING = ROOT / "tests/emulator/real_epub_companions.json"
SCENARIO_RE = re.compile(r"^scenarios\.([a-z0-9_]+)\s*=", re.MULTILINE)
OUTCOME_HASH_ALGORITHM = "sha256(sorted-unique-utf8-names-joined-by-lf)"
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def read_json(path: Path) -> dict:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"JSON root must be an object: {path}")
    return value


def scenario_names(path: Path) -> list[str]:
    names = SCENARIO_RE.findall(path.read_text(encoding="utf-8"))
    if not names or len(names) != len(set(names)):
        raise ValueError("scenario catalogue is empty or contains duplicate declarations")
    return names


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_json(value: object) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
    ).encode("utf-8")


def assertion_inventory(names: list[str]) -> dict[str, object]:
    unique = sorted(set(names))
    return {
        "count": len(unique),
        "sha256": hashlib.sha256("\n".join(unique).encode("utf-8")).hexdigest(),
    }


def require_inventory(value: object, label: str, *, allow_empty: bool = False) -> dict:
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be an assertion inventory")
    count = value.get("count")
    digest = value.get("sha256")
    minimum = 0 if allow_empty else 1
    if not isinstance(count, int) or isinstance(count, bool) or count < minimum:
        raise ValueError(f"{label} has an invalid assertion count")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError(f"{label} has an invalid assertion-set SHA-256")
    return value


def validate_outcome_contract(mapping: dict, catalogue: list[str]) -> dict:
    contract = mapping.get("outcomeContract")
    if not isinstance(contract, dict) or contract.get("schemaVersion") != 1:
        raise ValueError("real companion outcomeContract must use schemaVersion 1")
    if contract.get("hashAlgorithm") != OUTCOME_HASH_ALGORITHM:
        raise ValueError("real companion outcomeContract uses an unknown hash algorithm")
    require_inventory(
        contract.get("realProvenanceAssertions"), "real provenance outcome contract"
    )
    scenarios = contract.get("scenarios")
    if not isinstance(scenarios, dict) or set(scenarios) != set(catalogue):
        raise ValueError("outcome contract scenarios must exactly cover the visual catalogue")
    for scenario, record in scenarios.items():
        if not isinstance(record, dict):
            raise ValueError(f"outcome contract for {scenario} must be an object")
        if set(record) != {"portrait", "landscape"}:
            raise ValueError(f"outcome contract for {scenario} must cover both orientations")
        for orientation, oriented in record.items():
            if not isinstance(oriented, dict):
                raise ValueError(f"{scenario} {orientation} outcome contract must be an object")
            synthetic = require_inventory(
                oriented.get("synthetic"), f"{scenario} {orientation} synthetic"
            )
            real = require_inventory(oriented.get("real"), f"{scenario} {orientation} real")
            shared = require_inventory(
                oriented.get("shared"), f"{scenario} {orientation} shared"
            )
            if shared["count"] > min(synthetic["count"], real["count"]):
                raise ValueError(f"{scenario} {orientation} shared outcomes exceed one side")
            divergent = synthetic != real
            rationale = oriented.get("divergenceRationale")
            if divergent and (not isinstance(rationale, str) or len(rationale.strip()) < 20):
                raise ValueError(
                    f"{scenario} {orientation} outcome divergence requires a rationale"
                )
            if not divergent and rationale is not None:
                raise ValueError(f"{scenario} {orientation} has a stale divergence rationale")
    return contract


def png_dimensions(path: Path) -> tuple[int, int]:
    header = path.read_bytes()[:24]
    if len(header) != 24 or header[:8] != PNG_SIGNATURE or header[12:16] != b"IHDR":
        raise ValueError("screenshot is not a valid PNG with an IHDR header")
    return struct.unpack(">II", header[16:24])


def validated_metadata_evidence(library: dict, referenced: set[int]) -> dict[int, dict]:
    top_provider = (library.get("metadataProvenance") or {}).get("provider") or {}
    manifest_path = Path(str(top_provider.get("manifestPath") or ""))
    if not manifest_path.is_file():
        raise ValueError("private provider cache manifest is missing")
    manifest = read_json(manifest_path)
    unsigned = dict(manifest)
    claimed = unsigned.pop("manifestSha256", None)
    actual_manifest = hashlib.sha256(canonical_json(unsigned)).hexdigest()
    if claimed != actual_manifest or top_provider.get("manifestSha256") != actual_manifest:
        raise ValueError("private provider cache manifest fingerprint differs")
    entries = {
        item.get("sourceSha256"): item
        for item in manifest.get("books", [])
        if isinstance(item, dict) and item.get("kind") == "private-real-epub"
    }
    books = {int(book["id"]): book for book in library["books"]}
    evidence: dict[int, dict] = {}
    for book_id in referenced:
        book = books[book_id]
        source_sha = book.get("sourceSha256")
        entry = entries.get(source_sha)
        if not isinstance(entry, dict) or entry.get("cacheKey") != source_sha:
            raise ValueError(f"private provider cache has no exact-SHA entry for book {book_id}")
        native = entry.get("metadata")
        if not isinstance(native, dict):
            raise ValueError(f"private provider metadata is missing for book {book_id}")
        actual_projection = hashlib.sha256(canonical_json(native)).hexdigest()
        provider = (book.get("metadataProvenance") or {}).get("provider") or {}
        if (
            entry.get("metadataProjectionSha256") != actual_projection
            or provider.get("metadataProjectionSha256") != actual_projection
            or provider.get("cacheKey") != source_sha
            or provider.get("sourceSha256") != source_sha
        ):
            raise ValueError(f"private provider metadata projection differs for book {book_id}")
        evidence[book_id] = {
            "cache_manifest_sha256": actual_manifest,
            "metadata_projection_sha256": actual_projection,
        }
    return evidence


def validation_class(mapping: dict, scenario: str) -> str:
    if scenario in mapping.get("realEpubBehaviorScenarios", []):
        return "real-epub-behavior"
    if scenario in mapping.get("realMetadataLayoutScenarios", []):
        return "real-metadata-layout"
    if scenario in mapping.get("fixtureIndependentControls", {}):
        return "fixture-independent-control"
    raise ValueError(f"scenario has no realism validation class: {scenario}")


def validate(catalog: Path, mapping_path: Path, library_path: Path) -> tuple[dict, dict]:
    catalogue = scenario_names(catalog)
    mapping = read_json(mapping_path)
    if mapping.get("schemaVersion") != 2:
        raise ValueError("real companion mapping schemaVersion must be 2")
    configured = mapping.get("scenarios")
    if not isinstance(configured, dict):
        raise ValueError("real companion mapping requires a scenarios object")

    missing = sorted(set(catalogue) - set(configured))
    unknown = sorted(set(configured) - set(catalogue))
    if missing or unknown:
        parts = []
        if missing:
            parts.append("missing: " + ", ".join(missing))
        if unknown:
            parts.append("unknown: " + ", ".join(unknown))
        raise ValueError("companion mapping does not exactly cover the catalogue (" + "; ".join(parts) + ")")

    # The committed mapping must be non-sensitive and portable.  Its scenario
    # values are IDs only; paths and titles come from ignored preparation output.
    for scenario, book_ids in configured.items():
        if not isinstance(book_ids, list) or not book_ids:
            raise ValueError(f"{scenario} must map to at least one real book ID")
        if any(not isinstance(book_id, int) for book_id in book_ids):
            raise ValueError(f"{scenario} mapping may contain integer book IDs only")
        if len(book_ids) != len(set(book_ids)):
            raise ValueError(f"{scenario} contains a duplicate real book ID")
    controls = mapping.get("fixtureIndependentControls")
    if not isinstance(controls, dict) or any(
        not isinstance(reason, str) or not reason.strip()
        for reason in controls.values()
    ):
        raise ValueError("fixtureIndependentControls requires a non-empty rationale per scenario")
    classified = [
        *mapping.get("realEpubBehaviorScenarios", []),
        *mapping.get("realMetadataLayoutScenarios", []),
        *controls,
    ]
    if len(classified) != len(set(classified)):
        raise ValueError("a scenario appears in more than one companion validation class")
    invalid_classes = sorted(set(classified) - set(catalogue))
    if invalid_classes:
        raise ValueError("validation class contains unknown scenarios: " + ", ".join(invalid_classes))
    unclassified = sorted(set(catalogue) - set(classified))
    if unclassified:
        raise ValueError("scenarios without a realism validation class: " + ", ".join(unclassified))
    validate_outcome_contract(mapping, catalogue)

    library = read_json(library_path)
    if library.get("fixtureMode") != "real-epub-companion":
        raise ValueError("prepare the private visual-library.json before running companions")
    books = library.get("books")
    if not isinstance(books, list) or not books:
        raise ValueError("private companion library contains no books")
    by_id = {int(book["id"]): book for book in books}
    referenced = {book_id for ids in configured.values() for book_id in ids}
    unavailable = sorted(referenced - set(by_id))
    if unavailable:
        raise ValueError("private companion library is missing book IDs: " + ", ".join(map(str, unavailable)))
    for book_id in sorted(referenced):
        book = by_id[book_id]
        source = Path(book.get("sourcePath", ""))
        profile = book.get("epubProfile") or {}
        if not source.is_file():
            raise ValueError(f"real book {book_id} is no longer readable; run prepare again")
        actual_sha = file_sha256(source)
        if actual_sha != book.get("sourceSha256"):
            raise ValueError(f"real book {book_id} changed since preparation; run prepare again")
        if (
            int(profile.get("contentDocuments", 0)) <= 1
            or int(profile.get("spineItems", 0)) <= 1
            or int(profile.get("contentBytes", 0)) <= 10_000
        ):
            raise ValueError(
                f"real book {book_id} is not a meaningful multi-document reading fixture"
            )
    library["_validatedMetadataEvidence"] = validated_metadata_evidence(
        library, referenced
    )
    return mapping, library


def plan(args: argparse.Namespace) -> int:
    mapping, library = validate(args.catalog, args.mapping, args.library)
    by_id = {int(book["id"]): book for book in library["books"]}
    wanted = args.scenario or scenario_names(args.catalog)
    unknown = sorted(set(wanted) - set(mapping["scenarios"]))
    if unknown:
        raise ValueError("unknown requested scenarios: " + ", ".join(unknown))
    for scenario in wanted:
        for book_id in mapping["scenarios"][scenario]:
            book = by_id[book_id]
            file_id = int(book.get("sourceFileId") or book["primaryFile"]["id"])
            asset_sha = file_sha256(Path(book["sourcePath"]))
            # Shell runner reads tab-separated fields. EPUB filenames and
            # paths may contain spaces, punctuation and Unicode but not tabs.
            values = (
                scenario,
                str(book_id),
                str(file_id),
                validation_class(mapping, scenario),
                asset_sha,
                str(book.get("title") or f"Book {book_id}"),
                str(book["sourcePath"]),
            )
            if any("\t" in value or "\n" in value for value in values):
                raise ValueError(f"book {book_id} has an unsupported tab/newline in its path")
            print("\t".join(values))
    return 0


def validate_result_outcomes(result: dict, contract: dict, role: str) -> dict[str, set[str]]:
    assertions = result.get("assertions")
    if not isinstance(assertions, list) or not assertions:
        raise ValueError("passed result contains no named outcome assertions")
    names: dict[str, list[str]] = {"scenario": [], "provenance": []}
    seen: dict[str, set[str]] = {"scenario": set(), "provenance": set()}
    required_fields = {"scope", "name", "pass", "expected", "actual"}
    for index, assertion in enumerate(assertions):
        if not isinstance(assertion, dict) or set(assertion) != required_fields:
            raise ValueError(f"assertion {index} does not use the exact outcome record shape")
        scope = assertion["scope"]
        name = assertion["name"]
        if scope not in names:
            raise ValueError(f"assertion {index} has an invalid outcome scope")
        if not isinstance(name, str) or not name.strip():
            raise ValueError(f"assertion {index} has no stable outcome name")
        if name in seen[scope]:
            raise ValueError(f"duplicate {scope} outcome name: {name}")
        if assertion["pass"] is not True:
            raise ValueError(f"passed result contains a failed outcome: {name}")
        seen[scope].add(name)
        names[scope].append(name)

    actual = {
        "schemaVersion": 1,
        "scenarioAssertions": assertion_inventory(names["scenario"]),
        "provenanceAssertions": assertion_inventory(names["provenance"]),
    }
    if result.get("outcome") != actual:
        raise ValueError("recorded outcome inventory differs from named assertions")
    expected = contract[role]
    if actual["scenarioAssertions"] != expected:
        raise ValueError(f"{role} named outcome contract differs")
    expected_provenance = (
        contract["_realProvenanceAssertions"] if role == "real"
        else assertion_inventory([])
    )
    if actual["provenanceAssertions"] != expected_provenance:
        raise ValueError(f"{role} provenance outcome contract differs")
    return {scope: set(values) for scope, values in names.items()}


def load_result(
    path: Path,
    expected_book_id: int | None = None,
    expected_class: str | None = None,
    expected_sha: str | None = None,
    *,
    expected_scenario: str,
    expected_orientation: str,
    contract: dict,
    role: str,
    expected_metadata: dict | None = None,
) -> tuple[str, str]:
    if not path.is_file():
        return "missing", "result JSON was not produced"
    try:
        result = read_json(path)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        return "invalid", str(exc)
    if result.get("status") != "passed":
        return "failed", str(result.get("error") or "one or more assertions failed")
    try:
        if result.get("version") != 2:
            raise ValueError("passed result must use visual result schema version 2")
        if result.get("scenario") != expected_scenario:
            raise ValueError("result scenario differs from its outcome contract")
        if result.get("error") is not None:
            raise ValueError("passed result retained a fatal error")
        source_fingerprint = result.get("source_fingerprint")
        if not isinstance(source_fingerprint, str) or not re.fullmatch(
            r"sha256:[0-9a-f]{64}", source_fingerprint
        ):
            raise ValueError("result has no canonical source fingerprint")
        koreader = result.get("koreader")
        if not isinstance(koreader, dict) or not koreader.get("version") or not koreader.get("commit"):
            raise ValueError("result omitted pinned KOReader provenance")
        screen = result.get("screen")
        if not isinstance(screen, dict) or screen.get("orientation") != expected_orientation:
            raise ValueError("result screen orientation differs")
        width, height = screen.get("width"), screen.get("height")
        if not isinstance(width, int) or not isinstance(height, int) or width <= 0 or height <= 0:
            raise ValueError("result screen has invalid dimensions")
        if (expected_orientation == "portrait") != (height > width):
            raise ValueError("result dimensions contradict screen orientation")
        screenshot = path.with_suffix(".png")
        if not screenshot.is_file() or screenshot.stat().st_size == 0:
            raise ValueError("result screenshot is missing or empty")
        recorded_screenshot = result.get("screenshot")
        if not isinstance(recorded_screenshot, str) or Path(recorded_screenshot).name != screenshot.name:
            raise ValueError("result screenshot path differs from its adjacent evidence")
        if png_dimensions(screenshot) != (width, height):
            raise ValueError("result screenshot dimensions differ from screen evidence")
        if result.get("screenshot_sha256") != file_sha256(screenshot):
            raise ValueError("result screenshot SHA-256 differs")
        scenario_contract = dict(contract)
        scenario_contract["_realProvenanceAssertions"] = contract[
            "_realProvenanceAssertions"
        ]
        validate_result_outcomes(result, scenario_contract, role)
    except (OSError, ValueError) as exc:
        return "failed", str(exc)
    if expected_book_id is not None:
        if result.get("data_profile") != "real-epub-companion":
            return "failed", "result did not identify the real-EPUB companion profile"
        if int(result.get("real_book_id") or -1) != expected_book_id:
            return "failed", "result used a different real book ID"
        if int(result.get("source_book_id") or -1) != expected_book_id:
            return "failed", "result omitted or changed sourceBookId provenance"
        if result.get("fixture_mode") != "direct-private-epub":
            return "failed", "result did not identify direct private EPUB fixture mode"
        if expected_class and result.get("validation_class") != expected_class:
            return "failed", "result used the wrong validation class"
        if expected_sha and result.get("epub_sha256") != expected_sha:
            return "failed", "result EPUB digest does not match the validated asset"
        provenance = result.get("metadata_provenance") or {}
        if (
            provenance.get("cache_key") != expected_sha
            or provenance.get("source_sha256") != expected_sha
        ):
            return "failed", "result metadata provenance is not bound to the exact EPUB SHA"
        if not isinstance(expected_metadata, dict):
            return "failed", "reporter has no independently verified metadata evidence"
        for key in ("cache_manifest_sha256", "metadata_projection_sha256"):
            if provenance.get(key) != expected_metadata.get(key):
                return "failed", f"result metadata provenance differs from recomputed {key}"
        if provenance.get("capture_method") != "grimmory-web-metadata-selection":
            return "failed", "result metadata was not captured through visible Grimmory selection"
        if provenance.get("provider_network_used") is not False:
            return "failed", "result metadata replay was not proven offline"
        if provenance.get("catalog_stress_provider_metadata") is not False:
            return "failed", "local catalogue stress data was claimed as provider metadata"
    return "passed", ""


def pair_outcomes_match(synthetic: dict, real: dict, contract: dict) -> tuple[bool, str]:
    synthetic_names = {
        item["name"] for item in synthetic["assertions"] if item["scope"] == "scenario"
    }
    real_names = {
        item["name"] for item in real["assertions"] if item["scope"] == "scenario"
    }
    shared = assertion_inventory(sorted(synthetic_names & real_names))
    if shared != contract["shared"]:
        return False, "synthetic and real shared named outcomes diverged"
    return True, ""


def report(args: argparse.Namespace) -> int:
    mapping, library = validate(args.catalog, args.mapping, args.library)
    by_id = {int(book["id"]): book for book in library["books"]}
    metadata_evidence = library["_validatedMetadataEvidence"]
    outcome_contract = mapping["outcomeContract"]
    wanted = args.scenario or scenario_names(args.catalog)
    orientations = [args.orientation] if args.orientation != "both" else ["portrait", "landscape"]
    rows = []
    failures = 0
    for orientation in orientations:
        for scenario in wanted:
            scenario_contract = dict(
                outcome_contract["scenarios"][scenario][orientation]
            )
            scenario_contract["_realProvenanceAssertions"] = outcome_contract[
                "realProvenanceAssertions"
            ]
            synthetic_json = args.run_root / "synthetic/captures" / orientation / f"{scenario}.json"
            synthetic_png = synthetic_json.with_suffix(".png")
            synthetic_status, synthetic_error = load_result(
                synthetic_json,
                expected_scenario=scenario,
                expected_orientation=orientation,
                contract=scenario_contract,
                role="synthetic",
            )
            # load_result already turns malformed JSON into an auditable row.
            # Only decode it again after validation, otherwise one truncated
            # child result would abort the whole paired report.
            synthetic_record = (
                read_json(synthetic_json) if synthetic_status == "passed" else {}
            )
            if synthetic_status == "passed" and (
                synthetic_record.get("fixture_mode") != "synthetic-injected"
                or synthetic_record.get("validation_class") != "synthetic-ci-baseline"
            ):
                synthetic_status = "failed"
                synthetic_error = "synthetic result has incorrect fixture provenance"
            for book_id in mapping["scenarios"][scenario]:
                real_root = args.run_root / "real" / str(book_id) / scenario
                real_json = real_root / "captures" / orientation / f"{scenario}.json"
                real_png = real_json.with_suffix(".png")
                expected_class = validation_class(mapping, scenario)
                expected_sha = by_id[book_id].get("sourceSha256")
                real_status, real_error = load_result(
                    real_json,
                    book_id,
                    expected_class,
                    expected_sha,
                    expected_scenario=scenario,
                    expected_orientation=orientation,
                    contract=scenario_contract,
                    role="real",
                    expected_metadata=metadata_evidence[book_id],
                )
                real_record = read_json(real_json) if real_status == "passed" else {}
                if real_status == "passed" and synthetic_status == "passed" and (
                    real_record.get("source_fingerprint")
                    != synthetic_record.get("source_fingerprint")
                    or real_record.get("koreader") != synthetic_record.get("koreader")
                ):
                    real_status = "failed"
                    real_error = (
                        "synthetic and real sides used different source or KOReader provenance"
                    )
                if real_status == "passed" and synthetic_status == "passed":
                    pair_ok, pair_error = pair_outcomes_match(
                        synthetic_record, real_record, scenario_contract
                    )
                    if not pair_ok:
                        real_status = "failed"
                        real_error = pair_error
                passed = synthetic_status == "passed" and real_status == "passed"
                failures += 0 if passed else 1
                profile = by_id[book_id].get("epubProfile") or {}
                rows.append({
                    "orientation": orientation,
                    "scenario": scenario,
                    "bookId": book_id,
                    "bookTitle": by_id[book_id].get("title") or f"Book {book_id}",
                    "validationClass": validation_class(mapping, scenario),
                    "outcomeContract": scenario_contract,
                    "fixtureIndependentRationale": mapping.get(
                        "fixtureIndependentControls", {}
                    ).get(scenario),
                    "assetSha256": by_id[book_id].get("sourceSha256"),
                    "epubProfile": {
                        "contentDocuments": profile.get("contentDocuments"),
                        "spineItems": profile.get("spineItems"),
                        "contentBytes": profile.get("contentBytes"),
                    },
                    "syntheticStatus": synthetic_status,
                    "syntheticError": synthetic_error,
                    "realStatus": real_status,
                    "realError": real_error,
                    "passed": passed,
                    "syntheticImage": synthetic_png,
                    "realImage": real_png,
                })

    args.output.mkdir(parents=True, exist_ok=True)
    public_rows = [
        {key: value for key, value in row.items() if key not in {"syntheticImage", "realImage"}}
        for row in rows
    ]
    (args.output / "report.json").write_text(
        json.dumps({
            "schemaVersion": 2,
            "outcomeContractSchemaVersion": outcome_contract["schemaVersion"],
            "pairs": len(rows),
            "passed": len(rows) - failures,
            "failed": failures,
            "results": public_rows,
        }, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    cards = []
    for row in rows:
        def image_tag(path: Path, label: str) -> str:
            if not path.is_file():
                return f'<div class="missing">{html.escape(label)} missing</div>'
            rel = Path("..") / path.relative_to(args.run_root)
            return f'<a href="{html.escape(rel.as_posix())}"><img src="{html.escape(rel.as_posix())}" alt="{html.escape(label)}"></a>'

        status_class = "pass" if row["passed"] else "fail"
        profile = row["epubProfile"]
        rationale = row.get("fixtureIndependentRationale")
        rationale_html = (
            f'<p><em>Control rationale:</em> {html.escape(rationale)}</p>'
            if rationale else ""
        )
        cards.append(f'''<article class="card {status_class}">
  <h2>{html.escape(row["scenario"])} · {html.escape(row["orientation"])}</h2>
  <p>Validation: <strong>{html.escape(row["validationClass"])}</strong> · real companion: <strong>{html.escape(row["bookTitle"])}</strong> (fixture ID {row["bookId"]}) · {profile["contentDocuments"]} content documents · {profile["spineItems"]} spine items</p>
  {rationale_html}
  <div class="pair"><figure><figcaption>Synthetic CI baseline · {row["syntheticStatus"]}</figcaption>{image_tag(row["syntheticImage"], "synthetic")}</figure>
  <figure><figcaption>Private real EPUB · {row["realStatus"]}</figcaption>{image_tag(row["realImage"], "real EPUB")}</figure></div>
</article>''')

    page = f'''<!doctype html><meta charset="utf-8"><title>Real EPUB companion report</title>
<style>
body{{font:16px system-ui;margin:2rem;background:#f3f3f3;color:#171717}}h1{{margin-bottom:.25rem}}.summary{{margin-bottom:2rem}}
.card{{background:white;border:3px solid #b42318;border-radius:12px;padding:1rem;margin:1rem 0}}.card.pass{{border-color:#16803c}}
.card h2{{margin:.1rem 0}}.pair{{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:1rem}}figure{{margin:0}}figcaption{{font-weight:650;margin:.5rem 0}}
img{{display:block;max-width:100%;max-height:760px;border:1px solid #888}}.missing{{padding:4rem;background:#fee}}
@media(max-width:900px){{.pair{{grid-template-columns:1fr}}}}
</style><h1>Real EPUB companion report</h1>
<p class="summary">{len(rows) - failures} of {len(rows)} synthetic ↔ real pairs passed. Real files and extracted metadata remain in ignored local build output.</p>
{''.join(cards)}'''
    (args.output / "index.html").write_text(page, encoding="utf-8")
    print(f"real EPUB companions: {len(rows) - failures} passed, {failures} failed")
    print(f"paired report: {args.output / 'index.html'}")
    return 1 if failures else 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name in ("validate", "plan", "report"):
        command = subparsers.add_parser(name)
        command.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
        command.add_argument("--mapping", type=Path, default=DEFAULT_MAPPING)
        command.add_argument("--library", type=Path, required=True)
        if name in {"plan", "report"}:
            command.add_argument("--scenario", action="append")
        if name == "report":
            command.add_argument("--run-root", type=Path, required=True)
            command.add_argument("--output", type=Path, required=True)
            command.add_argument("--orientation", choices=("portrait", "landscape", "both"), default="both")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.command == "validate":
            mapping, _library = validate(args.catalog, args.mapping, args.library)
            print(f"companion mapping covers {len(mapping['scenarios'])} scenarios")
            return 0
        if args.command == "plan":
            return plan(args)
        return report(args)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"real_epub_companions: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
