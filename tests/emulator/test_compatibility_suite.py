from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "run-grimmory-compatibility-suite.py"
SPEC = importlib.util.spec_from_file_location("grimmory_compatibility_suite", SCRIPT)
assert SPEC and SPEC.loader
suite = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = suite
SPEC.loader.exec_module(suite)


class CompatibilitySuiteProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.original_directories = suite.SOURCE_DIRECTORIES
        self.original_files = suite.SOURCE_FILES
        self.addCleanup(setattr, suite, "SOURCE_DIRECTORIES", self.original_directories)
        self.addCleanup(setattr, suite, "SOURCE_FILES", self.original_files)

    def test_source_fingerprint_is_canonical_and_detects_a_changed_input(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            (repo / "plugin").mkdir()
            (repo / "plugin" / "b.lua").write_text("return 2\n", encoding="utf-8")
            (repo / "plugin" / "a.lua").write_text("return 1\n", encoding="utf-8")
            (repo / "runner.py").write_text("print('run')\n", encoding="utf-8")
            suite.SOURCE_DIRECTORIES = (Path("plugin"),)
            suite.SOURCE_FILES = (Path("runner.py"),)

            first = suite.acceptance_source_provenance(repo)
            second = suite.acceptance_source_provenance(repo)
            self.assertEqual(first, second)
            self.assertEqual(
                [item["path"] for item in first["files"]],
                ["plugin/a.lua", "plugin/b.lua", "runner.py"],
            )

            (repo / "plugin" / "a.lua").write_text("return 3\n", encoding="utf-8")
            changed = suite.acceptance_source_provenance(repo)
            self.assertNotEqual(first["fingerprint"], changed["fingerprint"])

    def test_source_fingerprint_refuses_a_missing_required_file(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            (repo / "plugin").mkdir()
            (repo / "plugin" / "main.lua").write_text("return true\n", encoding="utf-8")
            suite.SOURCE_DIRECTORIES = (Path("plugin"),)
            suite.SOURCE_FILES = (Path("missing.py"),)
            with self.assertRaisesRegex(suite.SuiteError, "source file is missing"):
                suite.acceptance_source_provenance(repo)

    def test_green_artifact_must_propagate_the_exact_fingerprint(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            artifact = output / "browser" / "journeys" / "web-reader-checkpoints.json"
            artifact.parent.mkdir(parents=True)
            artifact.write_text(json.dumps({"sourceFingerprint": "exact"}), encoding="utf-8")
            statuses = {
                "browserJourneysStatus": 0,
                "browserProducerStatus": None,
                "koreaderStatus": None,
                "deviceBrowserStatus": None,
                "parityStatus": 1,
            }
            self.assertEqual(
                suite.validate_artifact_source_fingerprints(
                    output, {"books": []}, statuses, "exact"
                ),
                [],
            )
            artifact.write_text(json.dumps({"sourceFingerprint": "mixed"}), encoding="utf-8")
            self.assertIn(
                "mixed source fingerprint",
                suite.validate_artifact_source_fingerprints(
                    output, {"books": []}, statuses, "exact"
                )[0],
            )

    def test_runtime_outcomes_must_match_the_exact_named_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            contract = root / "contract.json"
            contract.write_text(json.dumps({
                "schemaVersion": 1,
                "journeys": {
                    "real journey": {
                        "coverage": "all-runtime-books",
                        "requiredOutcomes": ["visible-action", "exact-server-state"],
                        "executableBodySha256": "0" * 64,
                    }
                },
            }), encoding="utf-8")
            artifact = root / "web-reader-checkpoints.json"
            artifact.write_text(json.dumps({
                "schemaVersion": 2,
                "outcomeContract": {
                    "schemaVersion": 1,
                    "journeys": [{
                        "schemaVersion": 1,
                        "journey": "real journey",
                        "coverageAliases": ["real-1", "synthetic"],
                        "outcomes": {
                            "visible-action": True,
                            "exact-server-state": True,
                        },
                    }],
                },
            }), encoding="utf-8")
            suite.validate_browser_outcomes(
                artifact, contract, {"real journey"}, {"synthetic", "real-1"}
            )

            value = json.loads(artifact.read_text(encoding="utf-8"))
            value["outcomeContract"]["journeys"][0]["coverageAliases"] = ["real-1"]
            artifact.write_text(json.dumps(value), encoding="utf-8")
            with self.assertRaisesRegex(suite.SuiteError, "book coverage differs"):
                suite.validate_browser_outcomes(
                    artifact, contract, {"real journey"}, {"synthetic", "real-1"}
                )
            value["outcomeContract"]["journeys"][0]["coverageAliases"] = [
                "real-1", "synthetic"
            ]
            value["outcomeContract"]["journeys"][0]["outcomes"] = {
                "invented-marker": True
            }
            artifact.write_text(json.dumps(value), encoding="utf-8")
            with self.assertRaisesRegex(suite.SuiteError, "outcome names differ"):
                suite.validate_browser_outcomes(
                    artifact, contract, {"real journey"}, {"synthetic", "real-1"}
                )

    def test_runtime_outcomes_reject_noop_or_empty_artifact(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            contract = root / "contract.json"
            contract.write_text(json.dumps({
                "schemaVersion": 1,
                "journeys": {
                    "same title but noop": {
                        "coverage": "none",
                        "requiredOutcomes": ["visible-action"],
                        "executableBodySha256": "0" * 64,
                    }
                },
            }), encoding="utf-8")
            artifact = root / "web-reader-checkpoints.json"
            artifact.write_text(json.dumps({
                "schemaVersion": 2,
                "outcomeContract": {"schemaVersion": 1, "journeys": []},
            }), encoding="utf-8")
            with self.assertRaisesRegex(suite.SuiteError, "journey set differs"):
                suite.validate_browser_outcomes(
                    artifact, contract, {"same title but noop"}, set()
                )


if __name__ == "__main__":
    unittest.main()
