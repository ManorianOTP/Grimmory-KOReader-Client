"""Policy tests for the disposable full-Grimmory acceptance stack."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]


def load_script(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / filename)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


stack = load_script("grimmory_real_stack", "grimmory-real-stack.py")
seed = load_script("seed_grimmory_real_server", "seed-grimmory-real-server.py")


class RealStackPolicyTests(unittest.TestCase):
    def test_compose_accepts_cli_project_and_immutable_images(self):
        compose = (ROOT / "tests" / "emulator" / "grimmory-real-server.compose.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("${GRIMMORY_COMPOSE_PROJECT", compose)
        self.assertIn("${GRIMMORY_IMAGE", compose)
        self.assertIn("${GRIMMORY_MARIADB_IMAGE", compose)
        self.assertIn('127.0.0.1:${GRIMMORY_REAL_PORT', compose)
        self.assertIn("read_only: true", compose)
        self.assertNotIn('"${GRIMMORY_REAL_PORT:-16060}:6060"', compose)

    def test_redaction_removes_credentials_and_bearer_tokens(self):
        result = stack.redacted(
            "password=correct-horse Authorization: Bearer aaa.bbb.ccc correct-horse",
            ["correct-horse"],
        )
        self.assertNotIn("correct-horse", result)
        self.assertNotIn("aaa.bbb.ccc", result)
        self.assertEqual(result.count("<redacted>"), 2)
        self.assertIn("Bearer <redacted-token>", result)

    def test_compose_control_rejects_any_unowned_project(self):
        with self.assertRaises(stack.StackError):
            stack.compose_command({"composeProject": "my-production-library"}, "down")
        command = stack.compose_command(
            {"composeProject": "grimmory-compat-deadbeef"}, "ps"
        )
        self.assertIn("grimmory-compat-deadbeef", command)

    def test_destructive_cleanup_is_confined_to_ignored_parent(self):
        with tempfile.TemporaryDirectory() as outside:
            with self.assertRaises(stack.StackError):
                stack.assert_owned_run_root(Path(outside))

    def test_tracked_fixture_declares_eight_neutral_unique_file_names(self):
        fixture = json.loads(
            (ROOT / "tests" / "emulator" / "grimmory_library_fixture.json").read_text(
                encoding="utf-8"
            )
        )
        names = [book["fileName"] for book in fixture["books"]]
        self.assertEqual(len(names), 8)
        self.assertEqual(len(set(names)), 8)
        self.assertTrue(all("sourceBasename" not in book for book in fixture["books"]))

    def test_seed_matches_all_file_shape_variants_without_database_ids(self):
        book = {
            "primaryFile": {"fileName": "primary.epub"},
            "alternativeFormats": [{"fileName": "alternate.pdf"}],
            "files": [{"filename": "legacy.mobi"}],
        }
        self.assertEqual(
            seed.file_names(book), {"primary.epub", "alternate.pdf", "legacy.mobi"}
        )

    def test_source_manifest_requires_a_book_array(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.json"
            path.write_text('{"books": {}}', encoding="utf-8")
            with self.assertRaises(SystemExit):
                seed.source_entries(path)

    def test_preflight_failure_removes_any_staged_private_inputs(self):
        stack.DEFAULT_PARENT.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=stack.DEFAULT_PARENT) as parent:
            run_root = Path(parent) / "failed-preflight"
            empty_sources = Path(parent) / "empty-sources"
            empty_sources.mkdir()
            args = SimpleNamespace(
                output=run_root,
                source_dir=empty_sources,
                keep_on_failure=False,
            )
            with self.assertRaises(stack.StackError):
                stack.start_stack(args)
            self.assertFalse((run_root / "input" / "books").exists())

    def test_wrapped_mode_rejects_a_missing_command_before_startup(self):
        with self.assertRaisesRegex(stack.StackError, "requires a command"):
            stack.run_wrapped(SimpleNamespace(command=[]))

    def test_node_preflight_failure_happens_before_stack_start(self):
        missing = ROOT / "build" / "definitely-missing-node"
        args = SimpleNamespace(command=["consumer"], node=missing)
        with mock.patch.object(stack, "start_stack") as start:
            with self.assertRaisesRegex(stack.StackError, "does not exist"):
                stack.run_wrapped(args)
        start.assert_not_called()

    def test_node_preflight_rejects_relative_path_before_stack_start(self):
        args = SimpleNamespace(command=["consumer"], node=Path("node"))
        with mock.patch.object(stack, "start_stack") as start:
            with self.assertRaisesRegex(stack.StackError, "absolute path"):
                stack.run_wrapped(args)
        start.assert_not_called()

    def test_node_preflight_rejects_bad_version_before_stack_start(self):
        args = SimpleNamespace(command=["consumer"], node=Path(sys.executable))
        failed = stack.subprocess.CompletedProcess(
            [sys.executable, "--version"], 0, "not-node", ""
        )
        with mock.patch.object(stack, "run_command", return_value=failed), \
                mock.patch.object(stack, "start_stack") as start:
            with self.assertRaisesRegex(stack.StackError, "preflight failed"):
                stack.run_wrapped(args)
        start.assert_not_called()

    def test_node_preflight_rejects_non_executable_on_posix(self):
        with tempfile.TemporaryDirectory() as directory:
            candidate = Path(directory) / "node"
            candidate.write_text("not executable", encoding="utf-8")
            with mock.patch.object(stack.os, "name", "posix"), \
                    mock.patch.object(stack.os, "access", return_value=False):
                with self.assertRaisesRegex(stack.StackError, "not executable"):
                    stack.validate_node_executable(candidate)

    def test_node_preflight_rejects_unsupported_major(self):
        completed = stack.subprocess.CompletedProcess(
            [sys.executable, "--version"], 0, "v18.20.8\n", ""
        )
        with mock.patch.object(stack, "run_command", return_value=completed):
            with self.assertRaisesRegex(stack.StackError, r"20\+"):
                stack.validate_node_executable(Path(sys.executable))

    def test_subprocesses_are_pinned_to_the_absolute_repository_root(self):
        completed = stack.subprocess.CompletedProcess(["probe"], 0, "", "")
        with mock.patch.object(stack.subprocess, "run", return_value=completed) as run:
            stack.run_command(["probe"])
        self.assertEqual(ROOT, run.call_args.kwargs["cwd"])

    def test_wrapped_consumer_uses_stable_root_and_still_tears_down(self):
        completed = stack.subprocess.CompletedProcess(["consumer"], 0, "", "")
        runtime = ROOT / "build" / "grimmory-compatibility" / "probe" / "runtime.json"
        args = SimpleNamespace(
            command=["--", "consumer"], keep_on_failure=False,
            node=Path(sys.executable),
        )
        node = {"executable": str(Path(sys.executable).resolve()), "version": "v24.0.0"}
        with mock.patch.object(stack, "validate_node_executable", return_value=node), \
                mock.patch.object(stack, "start_stack", return_value=runtime), \
                mock.patch.object(stack, "record_consumer_tools") as record, \
                mock.patch.object(stack, "stop_stack") as stop, \
                mock.patch.object(stack.subprocess, "run", return_value=completed) as run:
            self.assertEqual(0, stack.run_wrapped(args))
        self.assertEqual(ROOT, run.call_args.kwargs["cwd"])
        self.assertEqual(node["executable"], run.call_args.kwargs["env"][stack.NODE_PATH_ENV])
        self.assertEqual(node["version"], run.call_args.kwargs["env"][stack.NODE_VERSION_ENV])
        record.assert_called_once_with(runtime, node)
        stop.assert_called_once_with(runtime)


if __name__ == "__main__":
    unittest.main()
