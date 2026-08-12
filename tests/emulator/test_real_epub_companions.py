from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
import zlib


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "real_epub_companions", ROOT / "scripts" / "real_epub_companions.py"
)
companions = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(companions)


class RealEpubCompanionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.catalog = root / "visual_scenarios.lua"
        self.catalog.write_text(
            "scenarios.reader = {}\nscenarios.layout = {}\nscenarios.control = {}\n",
            encoding="utf-8",
        )
        body = b"private fixture bytes"
        self.book = root / "book.epub"
        self.book.write_bytes(body)
        self.native_metadata = {"title": "Provider title", "authors": ["Provider author"]}
        projection_sha = hashlib.sha256(
            companions.canonical_json(self.native_metadata)
        ).hexdigest()
        self.cache_manifest = root / "provider-cache-manifest.json"
        manifest = {
            "schemaVersion": 1,
            "books": [{
                "kind": "private-real-epub",
                "cacheKey": hashlib.sha256(body).hexdigest(),
                "sourceSha256": hashlib.sha256(body).hexdigest(),
                "metadata": self.native_metadata,
                "metadataProjectionSha256": projection_sha,
            }],
        }
        manifest["manifestSha256"] = hashlib.sha256(
            companions.canonical_json(manifest)
        ).hexdigest()
        self.cache_manifest.write_text(json.dumps(manifest), encoding="utf-8")
        self.library = root / "visual-library.json"
        self.library.write_text(json.dumps({
            "fixtureMode": "real-epub-companion",
            "metadataProvenance": {"provider": {
                "manifestPath": str(self.cache_manifest),
                "manifestSha256": manifest["manifestSha256"],
            }},
            "books": [{
                "id": 1001,
                "title": "Private test title",
                "sourcePath": str(self.book),
                "sourceSha256": hashlib.sha256(body).hexdigest(),
                "sourceFileId": 5001,
                "primaryFile": {"id": 5001},
                "epubProfile": {
                    "contentDocuments": 3,
                    "spineItems": 3,
                    "contentBytes": 12000,
                },
                "metadataProvenance": {"provider": {
                    "cacheKey": hashlib.sha256(body).hexdigest(),
                    "sourceSha256": hashlib.sha256(body).hexdigest(),
                    "metadataProjectionSha256": projection_sha,
                }},
            }],
        }), encoding="utf-8")
        inventory = companions.assertion_inventory(["visible outcome"])
        provenance = companions.assertion_inventory(["exact provider provenance"])
        self.mapping = root / "mapping.json"
        self.mapping.write_text(json.dumps({
            "schemaVersion": 2,
            "realEpubBehaviorScenarios": ["reader"],
            "realMetadataLayoutScenarios": ["layout"],
            "fixtureIndependentControls": {"control": "No EPUB input is consumed."},
            "scenarios": {
                "reader": [1001], "layout": [1001], "control": [1001],
            },
            "outcomeContract": {
                "schemaVersion": 1,
                "hashAlgorithm": companions.OUTCOME_HASH_ALGORITHM,
                "realProvenanceAssertions": provenance,
                "scenarios": {
                    name: {
                        orientation: {
                            "synthetic": inventory, "real": inventory, "shared": inventory,
                        }
                        for orientation in ("portrait", "landscape")
                    }
                    for name in ("reader", "layout", "control")
                },
            },
        }), encoding="utf-8")

    def tearDown(self):
        self.temp.cleanup()

    def write_png(self, path: Path, width: int = 1, height: int = 2):
        def chunk(kind: bytes, data: bytes) -> bytes:
            return (
                struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
            )
        raw = b"".join(b"\0" + b"\xff\xff\xff" * width for _ in range(height))
        path.write_bytes(
            b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw))
            + chunk(b"IEND", b"")
        )

    def result_contract(self, scenario="reader"):
        mapping = json.loads(self.mapping.read_text(encoding="utf-8"))
        contract = dict(mapping["outcomeContract"]["scenarios"][scenario]["portrait"])
        contract["_realProvenanceAssertions"] = mapping["outcomeContract"][
            "realProvenanceAssertions"
        ]
        return contract

    def write_result(self, *, role="real", scenario="reader"):
        result_path = Path(self.temp.name) / f"{role}-{scenario}.json"
        screenshot = result_path.with_suffix(".png")
        self.write_png(screenshot)
        assertions = [{
            "scope": "scenario", "name": "visible outcome", "pass": True,
            "expected": "visible", "actual": "visible",
        }]
        if role == "real":
            assertions.append({
                "scope": "provenance", "name": "exact provider provenance", "pass": True,
                "expected": "exact", "actual": "exact",
            })
        scenario_names = [item["name"] for item in assertions if item["scope"] == "scenario"]
        provenance_names = [item["name"] for item in assertions if item["scope"] == "provenance"]
        source_sha = hashlib.sha256(b"private fixture bytes").hexdigest()
        manifest = json.loads(self.cache_manifest.read_text(encoding="utf-8"))
        result = {
            "version": 2,
            "scenario": scenario,
            "source_fingerprint": "sha256:" + "d" * 64,
            "status": "passed",
            "error": None,
            "screenshot": str(screenshot),
            "screenshot_sha256": companions.file_sha256(screenshot),
            "screen": {"width": 1, "height": 2, "orientation": "portrait"},
            "assertions": assertions,
            "outcome": {
                "schemaVersion": 1,
                "scenarioAssertions": companions.assertion_inventory(scenario_names),
                "provenanceAssertions": companions.assertion_inventory(provenance_names),
            },
            "data_profile": "real-epub-companion" if role == "real" else "synthetic-ci",
            "real_book_id": 1001 if role == "real" else None,
            "source_book_id": 1001 if role == "real" else None,
            "fixture_mode": "direct-private-epub" if role == "real" else "synthetic-injected",
            "validation_class": "real-epub-behavior" if role == "real" else "synthetic-ci-baseline",
            "epub_sha256": source_sha if role == "real" else None,
            "metadata_provenance": ({
                "cache_manifest_sha256": manifest["manifestSha256"],
                "cache_key": source_sha,
                "source_sha256": source_sha,
                "metadata_projection_sha256": manifest["books"][0]["metadataProjectionSha256"],
                "capture_method": "grimmory-web-metadata-selection",
                "provider_network_used": False,
                "catalog_stress_provider_metadata": False,
            } if role == "real" else None),
            "koreader": {"version": "v1", "commit": "abc"},
        }
        result_path.write_text(json.dumps(result), encoding="utf-8")
        return result_path, result

    def test_exact_catalogue_partition_and_real_asset_pass(self):
        mapping, library = companions.validate(
            self.catalog, self.mapping, self.library
        )
        self.assertEqual(3, len(mapping["scenarios"]))
        self.assertEqual("real-epub-companion", library["fixtureMode"])
        self.assertEqual(
            "real-epub-behavior", companions.validation_class(mapping, "reader")
        )
        self.assertEqual(
            "fixture-independent-control",
            companions.validation_class(mapping, "control"),
        )

    def test_changed_epub_is_rejected(self):
        self.book.write_bytes(b"changed after preparation")
        with self.assertRaisesRegex(ValueError, "changed since preparation"):
            companions.validate(self.catalog, self.mapping, self.library)

    def test_unclassified_scenario_is_rejected(self):
        mapping = json.loads(self.mapping.read_text(encoding="utf-8"))
        mapping["fixtureIndependentControls"] = {}
        self.mapping.write_text(json.dumps(mapping), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "without a realism validation class"):
            companions.validate(self.catalog, self.mapping, self.library)

    def test_result_requires_private_provenance(self):
        source_sha = hashlib.sha256(b"private fixture bytes").hexdigest()
        result_path, result = self.write_result()
        _mapping, library = companions.validate(self.catalog, self.mapping, self.library)
        status, error = companions.load_result(
            result_path,
            1001,
            "real-epub-behavior",
            source_sha,
            expected_scenario="reader",
            expected_orientation="portrait",
            contract=self.result_contract(),
            role="real",
            expected_metadata=library["_validatedMetadataEvidence"][1001],
        )
        self.assertEqual(("passed", ""), (status, error))

        for key in ("cache_manifest_sha256", "metadata_projection_sha256"):
            mutated = json.loads(json.dumps(result))
            mutated["metadata_provenance"][key] = "a" * 64
            result_path.write_text(json.dumps(mutated), encoding="utf-8")
            status, error = companions.load_result(
                result_path, 1001, "real-epub-behavior", source_sha,
                expected_scenario="reader", expected_orientation="portrait",
                contract=self.result_contract(), role="real",
                expected_metadata=library["_validatedMetadataEvidence"][1001],
            )
            self.assertEqual("failed", status)
            self.assertIn(f"recomputed {key}", error)

    def test_empty_or_invented_outcome_contract_is_rejected(self):
        result_path, result = self.write_result()
        for assertions in ([], [{
            "scope": "scenario", "name": "invented outcome", "pass": True,
            "expected": "x", "actual": "x",
        }]):
            mutated = dict(result)
            mutated["assertions"] = assertions
            mutated["outcome"] = {
                "schemaVersion": 1,
                "scenarioAssertions": companions.assertion_inventory(
                    [item["name"] for item in assertions]
                ),
                "provenanceAssertions": companions.assertion_inventory([]),
            }
            result_path.write_text(json.dumps(mutated), encoding="utf-8")
            status, error = companions.load_result(
                result_path, expected_scenario="reader", expected_orientation="portrait",
                contract=self.result_contract(), role="real",
            )
            self.assertEqual("failed", status)
            self.assertRegex(error, "no named outcome|named outcome contract|provenance")

    def test_previously_accepted_minimal_v1_result_is_rejected(self):
        result_path = Path(self.temp.name) / "legacy.json"
        result_path.write_text(json.dumps({
            "status": "passed",
            "data_profile": "real-epub-companion",
            "real_book_id": 1001,
            "source_book_id": 1001,
            "fixture_mode": "direct-private-epub",
            "validation_class": "real-epub-behavior",
            "epub_sha256": hashlib.sha256(b"private fixture bytes").hexdigest(),
            "metadata_provenance": {
                "cache_manifest_sha256": "a" * 64,
                "metadata_projection_sha256": "b" * 64,
            },
        }), encoding="utf-8")
        status, error = companions.load_result(
            result_path, expected_scenario="reader", expected_orientation="portrait",
            contract=self.result_contract(), role="real",
        )
        self.assertEqual("failed", status)
        self.assertIn("schema version 2", error)

    def test_false_duplicate_and_incomplete_assertions_are_rejected(self):
        result_path, result = self.write_result()
        mutations = []
        failed = json.loads(json.dumps(result))
        failed["assertions"][0]["pass"] = False
        mutations.append(failed)
        duplicate = json.loads(json.dumps(result))
        duplicate["assertions"].append(dict(duplicate["assertions"][0]))
        mutations.append(duplicate)
        incomplete = json.loads(json.dumps(result))
        del incomplete["assertions"][0]["actual"]
        mutations.append(incomplete)
        for mutated in mutations:
            result_path.write_text(json.dumps(mutated), encoding="utf-8")
            status, _error = companions.load_result(
                result_path, expected_scenario="reader", expected_orientation="portrait",
                contract=self.result_contract(), role="real",
            )
            self.assertEqual("failed", status)

    def test_screenshot_and_recorded_outcome_hash_are_recomputed(self):
        result_path, result = self.write_result()
        result["screenshot_sha256"] = "0" * 64
        result_path.write_text(json.dumps(result), encoding="utf-8")
        status, error = companions.load_result(
            result_path, expected_scenario="reader", expected_orientation="portrait",
            contract=self.result_contract(), role="real",
        )
        self.assertEqual("failed", status)
        self.assertIn("screenshot SHA-256", error)

        result_path, result = self.write_result()
        result["outcome"]["scenarioAssertions"]["sha256"] = "0" * 64
        result_path.write_text(json.dumps(result), encoding="utf-8")
        status, error = companions.load_result(
            result_path, expected_scenario="reader", expected_orientation="portrait",
            contract=self.result_contract(), role="real",
        )
        self.assertEqual("failed", status)
        self.assertIn("recorded outcome inventory", error)

    def test_pair_rejects_shared_outcome_divergence(self):
        _synthetic_path, synthetic = self.write_result(role="synthetic")
        _real_path, real = self.write_result(role="real")
        contract = self.result_contract()
        self.assertEqual((True, ""), companions.pair_outcomes_match(synthetic, real, contract))
        real["assertions"][0]["name"] = "different real outcome"
        passed, error = companions.pair_outcomes_match(synthetic, real, contract)
        self.assertFalse(passed)
        self.assertIn("diverged", error)

    def test_invented_manifest_or_projection_hash_is_rejected(self):
        library = json.loads(self.library.read_text(encoding="utf-8"))
        library["metadataProvenance"]["provider"]["manifestSha256"] = "f" * 64
        self.library.write_text(json.dumps(library), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "manifest fingerprint differs"):
            companions.validate(self.catalog, self.mapping, self.library)


if __name__ == "__main__":
    unittest.main()
