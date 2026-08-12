#!/usr/bin/env python3
"""Fail when a test or visual scenario has no explicit realism policy.

The private EPUBs cannot run in public CI.  CI can still enforce that every
synthetic test declares what it proves, and that every claim of real coverage
points at a tracked companion validator.  Lua cases are identified by their
source file and normalized first ``it(...)`` argument, never by line number.
"""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
from pathlib import Path
import re
import sys
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_POLICY = ROOT / "tests" / "realism_policy.json"
SCENARIO_RE = re.compile(r"^scenarios\.([a-z0-9_]+)\s*=", re.MULTILINE)
OUTCOME_HASH_ALGORITHM = "sha256(sorted-unique-utf8-names-joined-by-lf)"


class PolicyError(ValueError):
    pass


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise PolicyError(f"cannot read {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise PolicyError(f"JSON root must be an object: {path}")
    return value


def normalize_lua_expression(expression: str) -> str:
    """Collapse insignificant whitespace without changing string contents."""
    output: list[str] = []
    quote: str | None = None
    escaped = False
    pending_space = False
    for char in expression.strip():
        if quote:
            output.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
            continue
        if char in {'"', "'"}:
            if pending_space and output and output[-1] != " ":
                output.append(" ")
            pending_space = False
            quote = char
            output.append(char)
        elif char.isspace():
            pending_space = True
        else:
            if pending_space and output and output[-1] != " ":
                output.append(" ")
            pending_space = False
            output.append(char)
    return "".join(output).strip()


def mask_lua_comments(source: str) -> str:
    """Replace Lua comments with spaces while retaining offsets/newlines."""
    chars = list(source)
    index = 0
    quote: str | None = None
    escaped = False
    while index < len(chars):
        char = chars[index]
        if quote:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
            index += 1
            continue
        if char in {'"', "'"}:
            quote = char
            index += 1
            continue
        if source.startswith("--[[", index):
            end = source.find("]]", index + 4)
            end = len(source) if end < 0 else end + 2
            for offset in range(index, end):
                if chars[offset] not in "\r\n":
                    chars[offset] = " "
            index = end
            continue
        if source.startswith("--", index):
            end = source.find("\n", index + 2)
            end = len(source) if end < 0 else end
            for offset in range(index, end):
                if chars[offset] != "\r":
                    chars[offset] = " "
            index = end
            continue
        index += 1
    return "".join(chars)


def lua_first_arguments(source: str, call_name: str = "it") -> list[str]:
    """Extract first arguments from Lua calls using a small lexical scanner."""
    pattern = re.compile(rf"\b{re.escape(call_name)}\s*\(")
    results: list[str] = []
    searchable = mask_lua_comments(source)
    for match in pattern.finditer(searchable):
        index = match.end()
        start = index
        depth = 0
        quote: str | None = None
        escaped = False
        while index < len(source):
            char = source[index]
            if quote:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == quote:
                    quote = None
            elif char in {'"', "'"}:
                quote = char
            elif char in "({[":
                depth += 1
            elif char in ")}]":
                if depth == 0:
                    raise PolicyError(f"{call_name} call has no first-argument comma")
                depth -= 1
            elif char == "," and depth == 0:
                expression = normalize_lua_expression(source[start:index])
                if not expression:
                    raise PolicyError(f"{call_name} call has an empty first argument")
                results.append(expression)
                break
            index += 1
        else:
            raise PolicyError(f"unterminated {call_name} call")
    return results


def discover_lua_cases(root: Path) -> list[tuple[str, str]]:
    cases: list[tuple[str, str]] = []
    for path in sorted((root / "tests").glob("*_spec.lua")):
        relative = path.relative_to(root).as_posix()
        expressions = lua_first_arguments(path.read_text(encoding="utf-8"))
        if len(expressions) != len(set(expressions)):
            duplicates = sorted({item for item in expressions if expressions.count(item) > 1})
            raise PolicyError(
                f"{relative} has duplicate test-name expressions; give them stable unique names: "
                + ", ".join(duplicates)
            )
        cases.extend((relative, expression) for expression in expressions)
    if not cases:
        raise PolicyError("no Lua spec cases were discovered")
    return cases


def discover_visual_scenarios(root: Path, catalog_relative: str) -> list[str]:
    catalog = root / catalog_relative
    names = SCENARIO_RE.findall(catalog.read_text(encoding="utf-8"))
    if not names or len(names) != len(set(names)):
        raise PolicyError("visual scenario catalogue is empty or contains duplicates")
    return names


def mask_javascript_comments(source: str) -> str:
    """Mask JS comments and string bodies while retaining offsets/newlines."""
    chars = list(source)
    index = 0
    quote: str | None = None
    escaped = False
    while index < len(chars):
        char = chars[index]
        if quote:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
            if chars[index] not in "\r\n":
                chars[index] = " "
            index += 1
            continue
        if char in {'"', "'", "`"}:
            quote = char
            chars[index] = " "
            index += 1
            continue
        if source.startswith("//", index):
            end = source.find("\n", index + 2)
            end = len(source) if end < 0 else end
            for offset in range(index, end):
                if chars[offset] != "\r":
                    chars[offset] = " "
            index = end
            continue
        if source.startswith("/*", index):
            end = source.find("*/", index + 2)
            end = len(source) if end < 0 else end + 2
            for offset in range(index, end):
                if chars[offset] not in "\r\n":
                    chars[offset] = " "
            index = end
            continue
        index += 1
    return "".join(chars)


def normalize_javascript_executable(source: str) -> str:
    """Normalize executable JS while making comments incapable of evidence.

    This is deliberately a source-body seal, not a search for magic assertion
    strings.  Whitespace and comments outside literals are normalized away;
    executable tokens and literal contents remain byte-significant.
    """
    output: list[str] = []
    index = 0
    quote: str | None = None
    escaped = False
    pending_space = False
    while index < len(source):
        char = source[index]
        if quote:
            output.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
            index += 1
            continue
        if char in {'"', "'", "`"}:
            if pending_space and output:
                output.append(" ")
            pending_space = False
            quote = char
            output.append(char)
            index += 1
            continue
        if source.startswith("//", index):
            end = source.find("\n", index + 2)
            index = len(source) if end < 0 else end
            pending_space = True
            continue
        if source.startswith("/*", index):
            end = source.find("*/", index + 2)
            index = len(source) if end < 0 else end + 2
            pending_space = True
            continue
        if char.isspace():
            pending_space = True
            index += 1
            continue
        if pending_space and output:
            output.append(" ")
        pending_space = False
        output.append(char)
        index += 1
    return "".join(output).strip()


def javascript_test_cases(path: Path) -> list[tuple[str, str, int, int]]:
    """Return static name, executable digest and source span for each JS test.

    A span ends at the next executable ``test(...)`` call (or EOF).  This keeps
    the scanner dependency-free for public CI while sealing the complete
    reviewed journey body.  Comment-only and quoted ``test(...)`` text is
    excluded when starts are discovered, and comments do not affect the seal.
    """
    source = path.read_text(encoding="utf-8")
    masked = mask_javascript_comments(source)
    if re.search(r"\btest\s*\.\s*(?:only|skip|fixme)\s*\(", masked):
        raise PolicyError(f"focused or skipped JavaScript test is forbidden: {path}")
    calls = list(re.finditer(r"(?<![\w.])test\s*\(", masked))
    cases: list[tuple[str, str, int, int]] = []
    for index, call in enumerate(calls):
        tail = source[call.end():]
        match = re.match(r"\s*(['\"])((?:\\.|(?!\1).)*)\1\s*,", tail, re.DOTALL)
        if not match:
            raise PolicyError(f"JavaScript test must use a static string name: {path}")
        name = bytes(match.group(2), "utf-8").decode("unicode_escape")
        end = calls[index + 1].start() if index + 1 < len(calls) else len(source)
        executable = normalize_javascript_executable(source[call.start():end])
        digest = hashlib.sha256(executable.encode("utf-8")).hexdigest()
        cases.append((name, digest, call.start(), end))
    names = [name for name, _digest, _start, _end in cases]
    if len(names) != len(set(names)):
        raise PolicyError(f"JavaScript test names must be unique within {path}")
    return cases


def javascript_test_names(path: Path) -> list[str]:
    return [name for name, _digest, _start, _end in javascript_test_cases(path)]


def python_test_names(path: Path) -> list[str]:
    try:
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    except SyntaxError as exc:
        raise PolicyError(f"cannot parse Python tests in {path}: {exc}") from exc
    names: list[str] = []
    parents: list[str] = []

    class Visitor(ast.NodeVisitor):
        def visit_ClassDef(self, node: ast.ClassDef) -> None:
            parents.append(node.name)
            self.generic_visit(node)
            parents.pop()

        def visit_FunctionDef(self, node: ast.FunctionDef) -> None:
            if node.name.startswith("test_"):
                names.append(".".join([*parents, node.name]))

        visit_AsyncFunctionDef = visit_FunctionDef

    Visitor().visit(tree)
    if len(names) != len(set(names)):
        raise PolicyError(f"Python test names must be unique within {path}")
    return names


def discover_external_cases(root: Path) -> list[tuple[str, str, str]]:
    cases: list[tuple[str, str, str]] = []
    for path in sorted((root / "tests/compatibility").glob("*.js")):
        names = javascript_test_names(path)
        relative = path.relative_to(root).as_posix()
        cases.extend(("javascript", relative, name) for name in names)
    for path in sorted((root / "tests").rglob("test*.py")):
        names = python_test_names(path)
        relative = path.relative_to(root).as_posix()
        cases.extend(("python", relative, name) for name in names)
    if not cases:
        raise PolicyError("no JavaScript or Python cases were discovered")
    return cases


def validate_validators(root: Path, policy: dict[str, Any]) -> set[str]:
    validators = policy.get("validators")
    if not isinstance(validators, dict) or not validators:
        raise PolicyError("policy requires a non-empty validators object")
    for validator_id, record in validators.items():
        if not isinstance(record, dict):
            raise PolicyError(f"validator {validator_id} must be an object")
        if "contains" in record:
            raise PolicyError(
                f"validator {validator_id} uses forbidden marker-only evidence"
            )
        relative = record.get("contract")
        if not isinstance(relative, str) or not relative:
            raise PolicyError(f"validator {validator_id} requires an outcome contract")
        path = root / relative
        if not path.is_file():
            raise PolicyError(f"validator {validator_id} contract is missing: {relative}")
        contract = read_json(path)
        kind = record.get("kind")
        if kind == "visual-outcome-contract":
            outcome = contract.get("outcomeContract")
            if contract.get("schemaVersion") != 2 or not isinstance(outcome, dict):
                raise PolicyError(f"validator {validator_id} has no versioned visual outcomes")
            if (
                outcome.get("schemaVersion") != 1
                or outcome.get("hashAlgorithm") != OUTCOME_HASH_ALGORITHM
            ):
                raise PolicyError(f"validator {validator_id} has an invalid outcome schema")
            scenarios = outcome.get("scenarios")
            if not isinstance(scenarios, dict) or not scenarios:
                raise PolicyError(f"validator {validator_id} has no scenario outcomes")
            requested = record.get("scenarios")
            if requested is not None and (
                not isinstance(requested, list)
                or not requested
                or any(item not in scenarios for item in requested)
            ):
                raise PolicyError(f"validator {validator_id} has stale scenario outcomes")
        elif kind == "full-server-outcome-contract":
            if contract.get("schemaVersion") != 1:
                raise PolicyError(f"validator {validator_id} has an invalid full-server schema")
            journeys = contract.get("journeys")
            if not isinstance(journeys, dict) or not journeys:
                raise PolicyError(f"validator {validator_id} has no named full-server journeys")
            for journey, evidence in journeys.items():
                outcomes = evidence.get("requiredOutcomes") if isinstance(evidence, dict) else None
                coverage = evidence.get("coverage") if isinstance(evidence, dict) else None
                if not isinstance(evidence, dict) or set(evidence) != {
                    "coverage", "requiredOutcomes", "executableBodySha256"
                }:
                    raise PolicyError(
                        f"full-server journey {journey} has a stale contract shape"
                    )
                if (
                    not isinstance(outcomes, list)
                    or not outcomes
                    or len(outcomes) != len(set(outcomes))
                    or any(not isinstance(item, str) or not item for item in outcomes)
                ):
                    raise PolicyError(
                        f"full-server journey {journey} has no exact named outcomes"
                    )
                if coverage not in {"none", "all-runtime-books"}:
                    raise PolicyError(
                        f"full-server journey {journey} has no exact coverage contract"
                    )
                executable_digest = evidence.get("executableBodySha256")
                if not isinstance(executable_digest, str) or not re.fullmatch(
                    r"[0-9a-f]{64}", executable_digest
                ):
                    raise PolicyError(
                        f"full-server journey {journey} has no executable body digest"
                    )
            producer = record.get("producer")
            producer_path = root / str(producer or "")
            if not isinstance(producer, str) or not producer_path.is_file():
                raise PolicyError(f"validator {validator_id} has no journey producer")
            produced = {
                name: digest
                for name, digest, _start, _end in javascript_test_cases(producer_path)
            }
            if set(journeys) != set(produced):
                raise PolicyError(
                    f"validator {validator_id} outcome journeys differ from executable tests"
                )
            for journey, evidence in journeys.items():
                if evidence["executableBodySha256"] != produced[journey]:
                    raise PolicyError(
                        f"full-server journey {journey} executable body digest differs"
                    )
        else:
            raise PolicyError(f"validator {validator_id} has unknown kind {kind!r}")
    return set(validators)


def validate_rule_metadata(
    rule: dict[str, Any],
    classes: dict[str, Any],
    validators: set[str],
) -> None:
    rule_id = rule.get("id")
    if not isinstance(rule_id, str) or not rule_id:
        raise PolicyError("every Lua rule requires a stable id")
    class_id = rule.get("class")
    definition = classes.get(class_id)
    if not isinstance(definition, dict):
        raise PolicyError(f"rule {rule_id} uses unknown class {class_id!r}")
    if definition.get("requiresRationale"):
        rationale = rule.get("rationale")
        if not isinstance(rationale, str) or len(rationale.strip()) < 20:
            raise PolicyError(f"rule {rule_id} requires a substantive rationale")
    if definition.get("requiresValidator"):
        validator = rule.get("validator")
        if validator not in validators:
            raise PolicyError(f"rule {rule_id} requires a known companion validator")


def rule_matches_case(rule: dict[str, Any], file_name: str, expression: str) -> bool:
    if file_name not in rule["files"]:
        return False
    selected = rule.get("expressions")
    if selected is not None and expression not in selected:
        return False
    return expression not in rule.get("excludeExpressions", [])


def case_set_digest(cases: list[tuple[str, str]]) -> str:
    """Return an order-independent fingerprint for a rule's exact case set."""
    inventory = "\n".join(sorted(f"{file_name} :: {expression}" for file_name, expression in cases))
    return hashlib.sha256(inventory.encode("utf-8")).hexdigest()


def validate_lua_policy(
    root: Path,
    policy: dict[str, Any],
    classes: dict[str, Any],
    validators: set[str],
) -> int:
    cases = discover_lua_cases(root)
    rules = policy.get("luaRules")
    if not isinstance(rules, list) or not rules:
        raise PolicyError("policy requires non-empty luaRules")
    rule_ids: set[str] = set()
    known_by_file: dict[str, set[str]] = {}
    for file_name, expression in cases:
        known_by_file.setdefault(file_name, set()).add(expression)

    for rule in rules:
        if not isinstance(rule, dict):
            raise PolicyError("every Lua rule must be an object")
        validate_rule_metadata(rule, classes, validators)
        rule_id = rule["id"]
        if rule_id in rule_ids:
            raise PolicyError(f"duplicate Lua rule id: {rule_id}")
        rule_ids.add(rule_id)
        files = rule.get("files")
        if not isinstance(files, list) or not files or any(not isinstance(x, str) for x in files):
            raise PolicyError(f"rule {rule_id} requires a non-empty files list")
        unknown_files = sorted(set(files) - set(known_by_file))
        if unknown_files:
            raise PolicyError(f"rule {rule_id} names files with no cases: {', '.join(unknown_files)}")
        expressions = rule.get("expressions")
        exclusions = rule.get("excludeExpressions", [])
        if expressions is not None and exclusions:
            raise PolicyError(f"rule {rule_id} cannot combine expressions and excludeExpressions")
        for field_name, values in (("expressions", expressions), ("excludeExpressions", exclusions)):
            if values is None:
                continue
            if not isinstance(values, list) or any(not isinstance(x, str) for x in values):
                raise PolicyError(f"rule {rule_id} {field_name} must be a string list")
            normalized = [normalize_lua_expression(item) for item in values]
            rule[field_name] = normalized
            for file_name in files:
                stale = sorted(set(normalized) - known_by_file[file_name])
                if stale:
                    raise PolicyError(
                        f"rule {rule_id} has stale {field_name} entries for {file_name}: "
                        + ", ".join(stale)
                    )

        # Broad file rules are useful for readable policy, but must never let a
        # newly added test silently inherit an exemption.  Pin their complete
        # resolved case set just as explicit selector rules are pinned.
        matched_cases = [
            case for case in cases if rule_matches_case(rule, case[0], case[1])
        ]
        expected_cases = rule.get("expectedCases")
        expected_digest = rule.get("caseSetSha256")
        if not isinstance(expected_cases, int) or expected_cases < 1:
            raise PolicyError(f"rule {rule_id} requires positive expectedCases")
        if expected_cases != len(matched_cases):
            raise PolicyError(
                f"rule {rule_id} case inventory changed: expected {expected_cases}, "
                f"found {len(matched_cases)}"
            )
        actual_digest = case_set_digest(matched_cases)
        if not isinstance(expected_digest, str) or not re.fullmatch(
            r"[0-9a-f]{64}", expected_digest
        ):
            raise PolicyError(f"rule {rule_id} requires a lowercase caseSetSha256")
        if expected_digest != actual_digest:
            raise PolicyError(
                f"rule {rule_id} case inventory digest changed: expected "
                f"{expected_digest}, found {actual_digest}"
            )

    errors: list[str] = []
    for file_name, expression in cases:
        matches = []
        for rule in rules:
            if rule_matches_case(rule, file_name, expression):
                matches.append(rule["id"])
        if len(matches) != 1:
            description = f"{file_name} :: {expression}"
            errors.append(
                f"{description} resolved to {len(matches)} rules"
                + (f" ({', '.join(matches)})" if matches else "")
            )
    if errors:
        raise PolicyError("Lua realism mapping is not exact:\n  " + "\n  ".join(errors))
    return len(cases)


def external_case_set_digest(cases: list[tuple[str, str, str]]) -> str:
    inventory = "\n".join(
        sorted(f"{framework} :: {file_name} :: {name}" for framework, file_name, name in cases)
    )
    return hashlib.sha256(inventory.encode("utf-8")).hexdigest()


def validate_external_policy(
    root: Path,
    policy: dict[str, Any],
    classes: dict[str, Any],
    validators: set[str],
) -> tuple[int, int]:
    cases = discover_external_cases(root)
    rules = policy.get("externalRules")
    if not isinstance(rules, list) or not rules:
        raise PolicyError("policy requires non-empty externalRules")
    matches_by_case: dict[tuple[str, str, str], list[str]] = {case: [] for case in cases}
    known_files = {case[1] for case in cases}
    rule_ids: set[str] = set()
    for rule in rules:
        if not isinstance(rule, dict):
            raise PolicyError("every external rule must be an object")
        validate_rule_metadata(rule, classes, validators)
        rule_id = rule["id"]
        if rule_id in rule_ids:
            raise PolicyError(f"duplicate external rule id: {rule_id}")
        rule_ids.add(rule_id)
        framework = rule.get("framework")
        files = rule.get("files")
        if framework not in {"javascript", "python"}:
            raise PolicyError(f"external rule {rule_id} has an invalid framework")
        if not isinstance(files, list) or not files or any(not isinstance(x, str) for x in files):
            raise PolicyError(f"external rule {rule_id} requires files")
        unknown = sorted(set(files) - known_files)
        if unknown:
            raise PolicyError(f"external rule {rule_id} names files with no tests: {', '.join(unknown)}")
        matched = [case for case in cases if case[0] == framework and case[1] in files]
        expected_cases = rule.get("expectedCases")
        expected_digest = rule.get("caseSetSha256")
        if expected_cases != len(matched):
            raise PolicyError(
                f"external rule {rule_id} inventory changed: expected {expected_cases}, found {len(matched)}"
            )
        actual_digest = external_case_set_digest(matched)
        if not isinstance(expected_digest, str) or expected_digest != actual_digest:
            raise PolicyError(f"external rule {rule_id} inventory digest changed")
        for case in matched:
            matches_by_case[case].append(rule_id)
    errors = [
        f"{framework} :: {file_name} :: {name} resolved to {len(matches)} rules"
        for (framework, file_name, name), matches in matches_by_case.items()
        if len(matches) != 1
    ]
    if errors:
        raise PolicyError("external realism mapping is not exact:\n  " + "\n  ".join(errors))
    return (
        sum(1 for case in cases if case[0] == "javascript"),
        sum(1 for case in cases if case[0] == "python"),
    )


def validate_visual_policy(
    root: Path,
    policy: dict[str, Any],
    classes: dict[str, Any],
    validators: set[str],
) -> int:
    visual = policy.get("visual")
    if not isinstance(visual, dict):
        raise PolicyError("policy requires visual configuration")
    catalog_relative = visual.get("catalog")
    mapping_relative = visual.get("mapping")
    if not isinstance(catalog_relative, str) or not isinstance(mapping_relative, str):
        raise PolicyError("visual catalog and mapping paths are required")
    catalogue = discover_visual_scenarios(root, catalog_relative)
    mapping = read_json(root / mapping_relative)
    if mapping.get("schemaVersion") != 2:
        raise PolicyError("visual companion mapping must use schemaVersion 2")
    scenario_books = mapping.get("scenarios")
    if not isinstance(scenario_books, dict):
        raise PolicyError("visual companion mapping requires scenarios")
    if set(scenario_books) != set(catalogue):
        missing = sorted(set(catalogue) - set(scenario_books))
        stale = sorted(set(scenario_books) - set(catalogue))
        raise PolicyError(
            "visual companion book mapping is not exact"
            + (f"; missing: {', '.join(missing)}" if missing else "")
            + (f"; stale: {', '.join(stale)}" if stale else "")
        )
    for scenario, book_ids in scenario_books.items():
        if (
            not isinstance(book_ids, list)
            or not book_ids
            or any(not isinstance(book_id, int) for book_id in book_ids)
            or len(book_ids) != len(set(book_ids))
        ):
            raise PolicyError(f"visual scenario {scenario} requires unique integer book IDs")

    behavior = mapping.get("realEpubBehaviorScenarios")
    metadata = mapping.get("realMetadataLayoutScenarios")
    controls = mapping.get("fixtureIndependentControls")
    if not isinstance(behavior, list) or any(not isinstance(x, str) for x in behavior):
        raise PolicyError("realEpubBehaviorScenarios must be a string list")
    if not isinstance(metadata, list) or any(not isinstance(x, str) for x in metadata):
        raise PolicyError("realMetadataLayoutScenarios must be a string list")
    if not isinstance(controls, dict):
        raise PolicyError("fixtureIndependentControls must be a scenario-to-rationale object")
    for scenario, rationale in controls.items():
        if not isinstance(rationale, str) or len(rationale.strip()) < 20:
            raise PolicyError(
                f"fixture-independent visual scenario {scenario} needs a substantive rationale"
            )
    groups = [set(behavior), set(metadata), set(controls)]
    union = set().union(*groups)
    overlaps = (groups[0] & groups[1]) | (groups[0] & groups[2]) | (groups[1] & groups[2])
    if overlaps or union != set(catalogue):
        missing = sorted(set(catalogue) - union)
        stale = sorted(union - set(catalogue))
        raise PolicyError(
            "visual realism classes are not an exact partition"
            + (f"; overlaps: {', '.join(sorted(overlaps))}" if overlaps else "")
            + (f"; missing: {', '.join(missing)}" if missing else "")
            + (f"; stale: {', '.join(stale)}" if stale else "")
        )

    class_validators = visual.get("classValidators")
    if not isinstance(class_validators, dict):
        raise PolicyError("visual classValidators are required")
    for class_id in ("real-epub-behavior", "real-metadata-layout"):
        definition = classes.get(class_id)
        if not isinstance(definition, dict) or not definition.get("requiresValidator"):
            raise PolicyError(f"visual class is not defined correctly: {class_id}")
        if class_validators.get(class_id) not in validators:
            raise PolicyError(f"visual class {class_id} requires a known validator")
    if "fixture-independent-control" not in classes:
        raise PolicyError("fixture-independent-control class is missing")
    outcome = mapping.get("outcomeContract")
    if (
        not isinstance(outcome, dict)
        or outcome.get("schemaVersion") != 1
        or outcome.get("hashAlgorithm") != OUTCOME_HASH_ALGORITHM
    ):
        raise PolicyError("visual mapping requires a versioned named outcome contract")
    outcome_scenarios = outcome.get("scenarios")
    if not isinstance(outcome_scenarios, dict) or set(outcome_scenarios) != set(catalogue):
        raise PolicyError("visual outcome contract must exactly cover the catalogue")

    def inventory(value: object, label: str) -> dict[str, Any]:
        if not isinstance(value, dict):
            raise PolicyError(f"{label} must be an assertion inventory")
        count, digest = value.get("count"), value.get("sha256")
        if (
            not isinstance(count, int) or isinstance(count, bool) or count < 1
            or not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest)
        ):
            raise PolicyError(f"{label} has an invalid count or assertion-set digest")
        return value

    inventory(outcome.get("realProvenanceAssertions"), "real provenance outcomes")
    for scenario, record in outcome_scenarios.items():
        if not isinstance(record, dict):
            raise PolicyError(f"visual outcome contract {scenario} must be an object")
        if set(record) != {"portrait", "landscape"}:
            raise PolicyError(f"{scenario} outcomes must cover both orientations")
        for orientation, oriented in record.items():
            if not isinstance(oriented, dict):
                raise PolicyError(f"{scenario} {orientation} outcomes must be an object")
            synthetic = inventory(
                oriented.get("synthetic"), f"{scenario} {orientation} synthetic outcomes"
            )
            real = inventory(
                oriented.get("real"), f"{scenario} {orientation} real outcomes"
            )
            shared = inventory(
                oriented.get("shared"), f"{scenario} {orientation} shared outcomes"
            )
            if shared["count"] > min(synthetic["count"], real["count"]):
                raise PolicyError(f"{scenario} {orientation} shared count is impossible")
            rationale = oriented.get("divergenceRationale")
            if synthetic != real:
                if not isinstance(rationale, str) or len(rationale.strip()) < 20:
                    raise PolicyError(
                        f"{scenario} {orientation} divergence requires a rationale"
                    )
            elif rationale is not None:
                raise PolicyError(f"{scenario} {orientation} has a stale rationale")
    return len(catalogue)


def validate_repository(
    root: Path = ROOT, policy_path: Path | None = None
) -> tuple[int, int, int, int]:
    policy = read_json(policy_path or (root / "tests" / "realism_policy.json"))
    if policy.get("schemaVersion") != 2:
        raise PolicyError("realism policy schemaVersion must be 2")
    classes = policy.get("classes")
    if not isinstance(classes, dict) or not classes:
        raise PolicyError("policy requires class definitions")
    validators = validate_validators(root, policy)
    lua_count = validate_lua_policy(root, policy, classes, validators)
    javascript_count, python_count = validate_external_policy(
        root, policy, classes, validators
    )
    visual_count = validate_visual_policy(root, policy, classes, validators)
    used = {
        rule.get("validator")
        for rule in [*policy.get("luaRules", []), *policy.get("externalRules", [])]
        if rule.get("validator")
    }
    used.update((policy.get("visual") or {}).get("classValidators", {}).values())
    unused = sorted(validators - used)
    if unused:
        raise PolicyError("unused realism validators: " + ", ".join(unused))
    return lua_count, visual_count, javascript_count, python_count


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--policy", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    try:
        lua_count, visual_count, javascript_count, python_count = validate_repository(
            root, args.policy
        )
    except (OSError, PolicyError) as exc:
        print(f"test realism policy: {exc}", file=sys.stderr)
        return 1
    print(
        f"test realism policy OK: {lua_count} Lua cases and "
        f"{visual_count} visual scenarios, {javascript_count} JavaScript tests, and "
        f"{python_count} Python tests mapped exactly once"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
