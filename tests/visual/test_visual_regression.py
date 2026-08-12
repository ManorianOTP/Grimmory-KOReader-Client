import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
TOOL_PATH = ROOT / "scripts" / "visual_regression.py"
SPEC = importlib.util.spec_from_file_location("visual_regression", str(TOOL_PATH))
visual_regression = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(visual_regression)


@unittest.skipIf(visual_regression.Image is None, "Pillow is required for visual tests")
class VisualRegressionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.current = self.root / "current"
        self.references = self.root / "references"
        self.artifacts = self.root / "artifacts"
        self.current.mkdir()
        self.references.mkdir()

    def tearDown(self):
        self.temporary.cleanup()

    def image(self, root, case, colour, size=(8, 8), changed_pixel=None):
        target = root / (case + ".png")
        target.parent.mkdir(parents=True, exist_ok=True)
        image = visual_regression.Image.new("RGBA", size, colour)
        if changed_pixel is not None:
            image.putpixel(changed_pixel[0], changed_pixel[1])
        image.save(str(target), "PNG")
        return target

    def run_main(self, argv):
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = visual_regression.main(argv)
        return code, stdout.getvalue(), stderr.getvalue()

    def compare(self, extra=None):
        argv = [
            "compare",
            "--current",
            str(self.current),
            "--references",
            str(self.references),
            "--artifacts",
            str(self.artifacts),
        ]
        argv.extend(extra or [])
        return self.run_main(argv)

    def report(self):
        return json.loads((self.artifacts / "report.json").read_text(encoding="utf-8"))

    def test_exact_match_passes_and_writes_review_artifacts(self):
        self.image(self.current, "wifi/badge-1", (255, 255, 255, 255))
        self.image(self.references, "wifi/badge-1", (255, 255, 255, 255))

        code, _, _ = self.compare()

        self.assertEqual(code, 0)
        report = self.report()
        self.assertTrue(report["passed"])
        self.assertEqual(report["cases"][0]["changed_pixels"], 0)
        case_dir = self.artifacts / "cases" / "wifi" / "badge-1"
        self.assertTrue((case_dir / "before.png").is_file())
        self.assertTrue((case_dir / "current.png").is_file())
        self.assertTrue((case_dir / "diff.png").is_file())
        self.assertIn("Before / current / diff", (self.artifacts / "index.html").read_text())
        gallery = (self.artifacts / "gallery.html").read_text(encoding="utf-8")
        self.assertIn("KOReader visual gallery", gallery)
        self.assertIn("wifi/badge-1", gallery)
        self.assertIn("Click any image for its original pixels", gallery)

    def test_single_pixel_change_fails_exact_comparison(self):
        self.image(self.references, "badge", (255, 255, 255, 255))
        self.image(
            self.current,
            "badge",
            (255, 255, 255, 255),
            changed_pixel=((3, 4), (0, 0, 0, 255)),
        )

        code, _, _ = self.compare()

        self.assertEqual(code, 1)
        case = self.report()["cases"][0]
        self.assertEqual(case["status"], "pixel_mismatch")
        self.assertEqual(case["changed_pixels"], 1)

    def test_tightly_bounded_pixel_threshold_can_be_opted_into(self):
        self.image(self.references, "badge", (255, 255, 255, 255))
        self.image(
            self.current,
            "badge",
            (255, 255, 255, 255),
            changed_pixel=((0, 0), (0, 0, 0, 255)),
        )

        code, _, _ = self.compare(["--max-changed-pixels", "1"])

        self.assertEqual(code, 0)
        self.assertEqual(self.report()["cases"][0]["changed_pixels"], 1)

    def test_thresholds_over_safety_caps_are_rejected(self):
        code, _, stderr = self.compare(
            ["--max-changed-ratio", str(visual_regression.MAX_CHANGED_RATIO + 0.001)]
        )

        self.assertEqual(code, 2)
        self.assertIn("--max-changed-ratio", stderr)

    def test_missing_reference_fails_and_is_not_created(self):
        self.image(self.current, "new-screen", (1, 2, 3, 255))

        code, _, _ = self.compare()

        self.assertEqual(code, 1)
        self.assertEqual(self.report()["cases"][0]["status"], "missing_reference")
        self.assertFalse((self.references / "new-screen.png").exists())

    def test_bootstrap_is_explicit_and_never_overwrites(self):
        capture = self.image(self.current, "new-screen", (1, 2, 3, 255))
        argv = [
            "bootstrap",
            "--current",
            str(self.current),
            "--references",
            str(self.references),
            "--case",
            "new-screen",
        ]

        code, _, _ = self.run_main(argv)
        self.assertEqual(code, 0)
        reference = self.references / "new-screen.png"
        self.assertEqual(reference.read_bytes(), capture.read_bytes())

        self.image(self.current, "new-screen", (9, 9, 9, 255))
        code, _, stderr = self.run_main(argv)
        self.assertEqual(code, 2)
        self.assertIn("never overwrites", stderr)
        self.assertNotEqual(reference.read_bytes(), capture.read_bytes())

    def test_approve_replaces_existing_but_will_not_create(self):
        self.image(self.references, "existing", (0, 0, 0, 255))
        current = self.image(self.current, "existing", (10, 20, 30, 255))
        base = [
            "approve",
            "--current",
            str(self.current),
            "--references",
            str(self.references),
        ]

        code, _, _ = self.run_main(base + ["--case", "existing"])
        self.assertEqual(code, 0)
        self.assertEqual((self.references / "existing.png").read_bytes(), current.read_bytes())

        self.image(self.current, "missing", (5, 5, 5, 255))
        code, _, stderr = self.run_main(base + ["--case", "missing"])
        self.assertEqual(code, 2)
        self.assertIn("Bootstrap first", stderr)
        self.assertFalse((self.references / "missing.png").exists())

    def test_bootstrap_rejects_invalid_png_data(self):
        invalid = self.current / "invalid.png"
        invalid.write_text("not an image", encoding="utf-8")

        code, _, stderr = self.run_main(
            [
                "bootstrap",
                "--current",
                str(self.current),
                "--references",
                str(self.references),
                "--case",
                "invalid",
            ]
        )

        self.assertEqual(code, 2)
        self.assertIn("Cannot use current capture", stderr)
        self.assertFalse((self.references / "invalid.png").exists())

    def test_atomic_write_failure_leaves_no_reference_or_temporary_file(self):
        self.image(self.current, "new-screen", (1, 2, 3, 255))
        argv = [
            "bootstrap",
            "--current",
            str(self.current),
            "--references",
            str(self.references),
            "--case",
            "new-screen",
        ]

        with mock.patch.object(
            visual_regression.os, "replace", side_effect=OSError("simulated failure")
        ):
            code, _, stderr = self.run_main(argv)

        self.assertEqual(code, 2)
        self.assertIn("Could not atomically write reference", stderr)
        self.assertFalse((self.references / "new-screen.png").exists())
        self.assertEqual(list(self.references.glob(".new-screen.png-*.tmp")), [])

    def test_staged_copy_is_validated_before_it_becomes_a_reference(self):
        self.image(self.current, "new-screen", (1, 2, 3, 255))
        argv = [
            "bootstrap",
            "--current",
            str(self.current),
            "--references",
            str(self.references),
            "--case",
            "new-screen",
        ]

        def corrupt_copy(_source, target):
            Path(target).write_text("corrupt staged data", encoding="utf-8")
            return str(target)

        with mock.patch.object(visual_regression.shutil, "copy2", side_effect=corrupt_copy):
            code, _, stderr = self.run_main(argv)

        self.assertEqual(code, 2)
        self.assertIn("Could not atomically write reference", stderr)
        self.assertFalse((self.references / "new-screen.png").exists())
        self.assertEqual(list(self.references.glob(".new-screen.png-*.tmp")), [])

    def test_interrupted_approval_preserves_old_reference_and_cleans_temporary_file(self):
        old_reference = self.image(self.references, "existing", (1, 1, 1, 255))
        old_bytes = old_reference.read_bytes()
        self.image(self.current, "existing", (2, 2, 2, 255))
        argv = [
            "approve",
            "--current",
            str(self.current),
            "--references",
            str(self.references),
            "--case",
            "existing",
        ]

        with mock.patch.object(visual_regression.os, "replace", side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                self.run_main(argv)

        self.assertEqual(old_reference.read_bytes(), old_bytes)
        self.assertEqual(list(self.references.glob(".existing.png-*.tmp")), [])

    def test_dimension_change_fails_with_diff(self):
        self.image(self.references, "menu", (0, 0, 0, 255), size=(8, 8))
        self.image(self.current, "menu", (0, 0, 0, 255), size=(10, 8))

        code, _, _ = self.compare()

        self.assertEqual(code, 1)
        self.assertEqual(self.report()["cases"][0]["status"], "dimension_mismatch")
        self.assertTrue((self.artifacts / "cases" / "menu" / "diff.png").is_file())

    def test_approved_case_missing_from_capture_fails(self):
        self.image(self.references, "expected", (0, 0, 0, 255))

        code, _, _ = self.compare()

        self.assertEqual(code, 1)
        self.assertEqual(self.report()["cases"][0]["status"], "missing_current")

    def test_source_fingerprint_is_stable_and_changes_with_content(self):
        first = self.root / "first.plugin"
        second = self.root / "second.plugin"
        first.mkdir()
        second.mkdir()
        (first / "main.lua").write_text("return 1\n", encoding="utf-8")
        (second / "nested").mkdir()
        (second / "nested" / "main.lua").write_text("return 2\n", encoding="utf-8")

        original = visual_regression.source_fingerprint([second, first])
        reordered = visual_regression.source_fingerprint([first, second])
        self.assertEqual(original, reordered)
        self.assertRegex(original, r"^sha256:[0-9a-f]{64}$")

        (first / "main.lua").write_text("return 3\n", encoding="utf-8")
        self.assertNotEqual(
            original, visual_regression.source_fingerprint([first, second])
        )

    def test_verify_provenance_rejects_stale_and_mixed_results(self):
        source = self.root / "plugin"
        source.mkdir()
        (source / "main.lua").write_text("return true\n", encoding="utf-8")
        fingerprint = visual_regression.source_fingerprint([source])
        captures = self.root / "captures"
        captures.mkdir()
        self.image(captures, "portrait/current", (255, 255, 255, 255))
        result = captures / "portrait" / "current.json"
        result.write_text(
            json.dumps({"source_fingerprint": fingerprint}), encoding="utf-8"
        )
        record = self.root / "provenance.json"
        argv = [
            "verify-provenance", "--captures", str(captures),
            "--source", str(source), "--record", str(record),
        ]

        code, _, _ = self.run_main(argv)
        self.assertEqual(code, 0)
        self.assertEqual(
            json.loads(record.read_text(encoding="utf-8"))["source_fingerprint"],
            fingerprint,
        )

        (source / "main.lua").write_text("return false\n", encoding="utf-8")
        code, _, stderr = self.run_main(argv)
        self.assertEqual(code, 2)
        self.assertIn("does not match current sources", stderr)

        (captures / "portrait" / "orphan.png").write_bytes(
            (captures / "portrait" / "current.png").read_bytes()
        )
        code, _, stderr = self.run_main(argv)
        self.assertEqual(code, 2)
        self.assertIn("mixed or incomplete", stderr)


if __name__ == "__main__":
    unittest.main()
