import copy
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
TOOL_PATH = ROOT / "scripts" / "check-test-realism.py"
SPEC = importlib.util.spec_from_file_location("check_test_realism", str(TOOL_PATH))
realism = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(realism)


class RealismPolicyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.temp_dir = Path(self.temporary.name)
        self.policy = json.loads(
            (ROOT / "tests" / "realism_policy.json").read_text(encoding="utf-8")
        )

    def tearDown(self):
        self.temporary.cleanup()

    def write_policy(self, policy):
        path = self.temp_dir / "policy.json"
        path.write_text(json.dumps(policy), encoding="utf-8")
        return path

    def rule(self, policy, rule_id):
        return next(rule for rule in policy["luaRules"] if rule["id"] == rule_id)

    def test_repository_policy_resolves_every_current_case_and_scenario(self):
        lua_count, visual_count, javascript_count, python_count = realism.validate_repository(ROOT)
        self.assertGreater(lua_count, 0)
        self.assertGreater(visual_count, 0)
        self.assertGreater(javascript_count, 0)
        self.assertGreater(python_count, 0)

    def test_broad_file_rule_is_pinned_against_silent_case_growth(self):
        policy = copy.deepcopy(self.policy)
        rule = self.rule(policy, "async-queue-unit")
        rule["expectedCases"] += 1

        with self.assertRaisesRegex(realism.PolicyError, "case inventory changed"):
            realism.validate_repository(ROOT, self.write_policy(policy))

    def test_case_set_digest_detects_a_renamed_or_reclassified_case(self):
        policy = copy.deepcopy(self.policy)
        rule = self.rule(policy, "async-queue-unit")
        rule["caseSetSha256"] = "0" * 64

        with self.assertRaisesRegex(realism.PolicyError, "case inventory digest changed"):
            realism.validate_repository(ROOT, self.write_policy(policy))

    def test_removing_a_rule_leaves_its_cases_unmapped(self):
        policy = copy.deepcopy(self.policy)
        policy["luaRules"] = [
            rule for rule in policy["luaRules"] if rule["id"] != "annotation-planning-unit"
        ]

        with self.assertRaisesRegex(realism.PolicyError, "resolved to 0 rules"):
            realism.validate_repository(ROOT, self.write_policy(policy))

    def test_overlapping_rule_is_rejected(self):
        policy = copy.deepcopy(self.policy)
        duplicate = copy.deepcopy(self.rule(policy, "async-queue-unit"))
        duplicate["id"] = "overlapping-async-rule"
        policy["luaRules"].append(duplicate)

        with self.assertRaisesRegex(realism.PolicyError, "resolved to 2 rules"):
            realism.validate_repository(ROOT, self.write_policy(policy))

    def test_visual_catalogue_requires_an_exact_book_mapping(self):
        policy = copy.deepcopy(self.policy)
        source = ROOT / policy["visual"]["mapping"]
        mapping = json.loads(source.read_text(encoding="utf-8"))
        missing = next(iter(mapping["scenarios"]))
        del mapping["scenarios"][missing]
        mapping_path = self.temp_dir / "visual-mapping.json"
        mapping_path.write_text(json.dumps(mapping), encoding="utf-8")
        policy["visual"]["mapping"] = str(mapping_path)

        with self.assertRaisesRegex(realism.PolicyError, "book mapping is not exact"):
            realism.validate_repository(ROOT, self.write_policy(policy))

    def test_lua_scanner_ignores_comments_and_normalizes_dynamic_names(self):
        source = '''
            -- it("commented out", function() end)
            --[[ it("also commented out", function() end) ]]
            it(
                "pulls " .. case.name,
                function() end
            )
        '''
        self.assertEqual(
            realism.lua_first_arguments(source),
            ['"pulls " .. case.name'],
        )

    def test_legacy_comment_or_dead_string_validator_is_rejected(self):
        policy = copy.deepcopy(self.policy)
        validator = policy["validators"]["reader-sync-round-trip"]
        validator.pop("contract")
        validator["path"] = "tests/emulator/visual_driver.koplugin/main.lua"
        validator["contains"] = "Jump Ahead moves the real reader forward"
        with self.assertRaisesRegex(realism.PolicyError, "forbidden marker-only evidence"):
            realism.validate_repository(ROOT, self.write_policy(policy))

    def test_javascript_discovery_ignores_comments_and_dead_strings(self):
        source = self.temp_dir / "sample.test.js"
        source.write_text('''
            // test('commented out', () => {});
            const dead = "test('inside a string', () => {})";
            test('real executable case', () => {});
        ''', encoding="utf-8")
        self.assertEqual(
            ["real executable case"], realism.javascript_test_names(source)
        )

    def test_visual_outcome_contract_rejects_missing_or_stale_scenario(self):
        policy = copy.deepcopy(self.policy)
        source = ROOT / policy["visual"]["mapping"]
        mapping = json.loads(source.read_text(encoding="utf-8"))
        missing = next(iter(mapping["outcomeContract"]["scenarios"]))
        del mapping["outcomeContract"]["scenarios"][missing]
        mapping_path = self.temp_dir / "outcomes-missing.json"
        mapping_path.write_text(json.dumps(mapping), encoding="utf-8")
        policy["visual"]["mapping"] = str(mapping_path)
        policy["validators"]["private-visual-companion-runner"]["contract"] = str(mapping_path)
        policy["validators"]["reader-sync-round-trip"]["contract"] = str(mapping_path)
        with self.assertRaisesRegex(realism.PolicyError, "outcome contract"):
            realism.validate_repository(ROOT, self.write_policy(policy))

    def test_visual_outcome_contract_rejects_invented_digest(self):
        policy = copy.deepcopy(self.policy)
        source = ROOT / policy["visual"]["mapping"]
        mapping = json.loads(source.read_text(encoding="utf-8"))
        first = next(iter(mapping["outcomeContract"]["scenarios"].values()))["portrait"]
        first["synthetic"]["sha256"] = "invented"
        mapping_path = self.temp_dir / "outcomes-invented.json"
        mapping_path.write_text(json.dumps(mapping), encoding="utf-8")
        policy["visual"]["mapping"] = str(mapping_path)
        policy["validators"]["private-visual-companion-runner"]["contract"] = str(mapping_path)
        policy["validators"]["reader-sync-round-trip"]["contract"] = str(mapping_path)
        with self.assertRaisesRegex(realism.PolicyError, "invalid count or assertion-set digest"):
            realism.validate_repository(ROOT, self.write_policy(policy))

    def test_external_inventory_rejects_silent_javascript_or_python_growth(self):
        for rule_id in ("browser-oracle-unit-tests", "python-harness-unit-tests"):
            policy = copy.deepcopy(self.policy)
            rule = next(rule for rule in policy["externalRules"] if rule["id"] == rule_id)
            rule["expectedCases"] += 1
            with self.assertRaisesRegex(realism.PolicyError, "inventory changed"):
                realism.validate_repository(ROOT, self.write_policy(policy))

    def test_full_server_contract_must_exactly_cover_executable_journeys(self):
        policy = copy.deepcopy(self.policy)
        validator = policy["validators"]["pinned-real-grimmory-lane"]
        contract = json.loads((ROOT / validator["contract"]).read_text(encoding="utf-8"))
        del contract["journeys"][next(iter(contract["journeys"]))]
        contract_path = self.temp_dir / "full-server-contract.json"
        contract_path.write_text(json.dumps(contract), encoding="utf-8")
        validator["contract"] = str(contract_path)
        with self.assertRaisesRegex(realism.PolicyError, "differ from executable tests"):
            realism.validate_repository(ROOT, self.write_policy(policy))

    def test_full_server_contract_rejects_same_name_noop_and_dead_markers(self):
        policy = copy.deepcopy(self.policy)
        validator = policy["validators"]["pinned-real-grimmory-lane"]
        producer = ROOT / validator["producer"]
        source = producer.read_text(encoding="utf-8")
        name, _digest, start, end = realism.javascript_test_cases(producer)[0]
        dead_markers = " ".join(
            json.loads((ROOT / validator["contract"]).read_text(encoding="utf-8"))["journeys"][name]["requiredOutcomes"]
        )
        replacement = (
            f"test({json.dumps(name)}, async () => {{ /* {dead_markers} */ }});\n\n"
        )
        noop_producer = self.temp_dir / "noop-web-reader-journeys.spec.js"
        noop_producer.write_text(
            source[:start] + replacement + source[end:], encoding="utf-8"
        )
        validator["producer"] = str(noop_producer)

        with self.assertRaisesRegex(realism.PolicyError, "executable body digest differs"):
            realism.validate_repository(ROOT, self.write_policy(policy))

    def test_unused_validator_is_rejected(self):
        policy = copy.deepcopy(self.policy)
        policy["validators"]["unused"] = copy.deepcopy(
            policy["validators"]["private-visual-companion-runner"]
        )
        with self.assertRaisesRegex(realism.PolicyError, "unused realism validators"):
            realism.validate_repository(ROOT, self.write_policy(policy))


if __name__ == "__main__":
    unittest.main()
