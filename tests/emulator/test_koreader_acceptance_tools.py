import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

from PIL import Image, ImageDraw


REPO = Path(__file__).resolve().parents[2]


def load_script(name: str):
    path = REPO / "scripts" / name
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


suite = load_script("run-grimmory-compatibility-suite.py")
report = load_script("koreader_acceptance_report.py")
reader_verifier = load_script("verify-koreader-reader-artifacts.py")
metadata_verifier = load_script("verify-koreader-metadata-artifacts.py")


class CompatibilityControllerTests(unittest.TestCase):
    def runtime(self):
        books = [
            {
                "alias": "synthetic",
                "kind": "synthetic",
                "sourceSha256": "hash-synthetic",
                "serverBookId": 1,
                "expectedKoreaderMetadata": {},
            }
        ]
        books += [
            {
                "alias": f"real-{index}",
                "kind": "real",
                "sourceSha256": f"hash-real-{index}",
                "serverBookId": index + 2,
                "expectedKoreaderMetadata": {},
                "expectedMetadata": {
                    "providerSelection": {
                        "captureMethod": "grimmory-web-metadata-selection",
                        "provider": "GoodReads",
                        "providerItemId": str(index),
                    }
                },
            }
            for index in range(8)
        ]
        return {
            "books": books,
            "runRoot": "/private/run",
            "metadataCache": {"providerNetworkUsed": False},
            "baseUrl": "http://fixture.invalid",
            "username": "private-user",
            "password": "private-password",
        }

    def test_runtime_requires_enriched_synthetic_and_eight_real_books(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "runtime.json"
            path.write_text(json.dumps(self.runtime()), encoding="utf-8")
            self.assertEqual(9, len(suite.validate_runtime(path)["books"]))
            value = self.runtime()
            del value["books"][3]["expectedKoreaderMetadata"]
            path.write_text(json.dumps(value), encoding="utf-8")
            with self.assertRaises(suite.SuiteError):
                suite.validate_runtime(path)

    def test_checkpoint_requires_one_real_cfi_pair_per_book(self):
        runtime = self.runtime()
        entries = [
            {
                "journey": "web-to-koreader-producer",
                "alias": book["alias"],
                "sourceSha256": book["sourceSha256"],
                "progress": {"cfi": "epubcfi(/6/2)"},
                "annotation": {
                    "id": 100,
                    "cfi": "epubcfi(/6/2,/1:0,/1:4)",
                    "selectionMethod": "physical-mouse-drag",
                    "text": "selected",
                    "color": "#FACC15",
                    "style": "highlight",
                    "note": None,
                },
            }
            for book in runtime["books"]
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "checkpoint.json"
            path.write_text(json.dumps({"checkpoints": entries}), encoding="utf-8")
            suite.validate_checkpoint(path, runtime)
            entries[0]["annotation"]["selectionMethod"] = "scripted-dom-range"
            path.write_text(json.dumps({"checkpoints": entries}), encoding="utf-8")
            with self.assertRaises(suite.SuiteError):
                suite.validate_checkpoint(path, runtime)

    def test_device_browser_checkpoint_requires_exact_nine_book_oracle(self):
        runtime = self.runtime()
        entries = []
        for book in runtime["books"]:
            entries.append({
                "journey": "koreader-to-web-consumer",
                "checkpointContract": "device-to-web-exact-range/v2",
                "coverageSet": "synthetic-plus-eight-real-epubs",
                "alias": book["alias"],
                "sourceSha256": book["sourceSha256"],
                "producer": {
                    "realSaveHighlightAction": True,
                    "productionUploadHook": True,
                    "freshReaderExactAdoption": True,
                    "selection": {
                        "crossesInlineBoundary": True,
                        "sameRenderedBlock": True,
                        "startBlockPath": "/body/DocFragment[1]/body/p[1]",
                        "endBlockPath": "/body/DocFragment[1]/body/p[1]",
                        "startInlinePath": "",
                        "endInlinePath": "em[1]",
                    },
                },
                "consumer": {
                    "exactKoreaderServerDomText": True,
                    "visibleCleanupAfterResolution": True,
                    "serverEmptyAfterCleanup": True,
                    "crossesInlineElementBoundary": True,
                    "endpointsAreTextNodes": True,
                    "sameLeafBlock": True,
                    "acceptsSameLeafBlockInlineRange": True,
                    "startLeafBlockPath": "/html[1]/body[1]/p[1]",
                    "endLeafBlockPath": "/html[1]/body[1]/p[1]",
                },
                "selectedText": {
                    "hasSmartQuote": True,
                    "hasAsciiApostrophe": False,
                    "hasNonAscii": True,
                    "hasControlSeparators": False,
                    "utf8Bytes": 42,
                },
                "invariants": {
                    "device_selection_uploaded_via_production_hooks": True,
                    "fresh_koreader_adopted_exact_device_annotation": True,
                    "live_server_text_equals_complete_koreader_selection": True,
                    "visible_sidebar_row_has_exact_whole_text_identity": True,
                    "foliate_device_cfi_resolves_noncollapsed_dom_range": True,
                    "foliate_dom_range_text_equals_complete_koreader_selection": True,
                    "foliate_dom_range_text_equals_live_server_text": True,
                    "inline_boundary_requirement_enforced_for_all_epubs": True,
                    "same_leaf_block_requirement_enforced_for_all_epubs": True,
                    "control_separator_free_selection": True,
                    "cleanup_occurs_only_after_three_way_text_equality": True,
                    "server_empty_after_visible_cleanup": True,
                },
            })
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "device.json"
            outcomes = {
                "genuine-koreader-highlight-uploaded-through-production-hooks": True,
                "fresh-koreader-adopted-exact-device-annotation": True,
                "live-server-text-equals-complete-koreader-selection": True,
                "visible-sidebar-row-has-exact-whole-text-identity": True,
                "device-cfi-resolves-to-noncollapsed-foliate-dom-range": True,
                "foliate-range-text-equals-complete-koreader-and-server-text": True,
                "all-epub-selection-crosses-inline-element-boundary": True,
                "all-epub-selection-stays-in-one-leaf-block": True,
                "selection-has-no-control-separators": True,
                "cleanup-occurs-only-after-three-way-text-equality": True,
                "server-empty-after-visible-browser-cleanup": True,
                "synthetic-plus-eight-real-epubs-covered-exactly-once": True,
            }
            artifact = {
                "schemaVersion": 2,
                "checkpoints": entries,
                "outcomeContract": {
                    "schemaVersion": 1,
                    "journeys": [{
                        "schemaVersion": 1,
                        "journey": "koreader-to-web-consumer resolves the complete device-origin range before visible cleanup",
                        "outcomes": outcomes,
                    }],
                },
            }
            path.write_text(json.dumps(artifact), encoding="utf-8")
            suite.validate_device_browser_checkpoint(path, runtime)
            entries[0]["consumer"]["exactKoreaderServerDomText"] = False
            path.write_text(json.dumps(artifact), encoding="utf-8")
            with self.assertRaises(suite.SuiteError):
                suite.validate_device_browser_checkpoint(path, runtime)
            entries[0]["consumer"]["exactKoreaderServerDomText"] = True
            entries[0]["producer"]["selection"]["sameRenderedBlock"] = False
            path.write_text(json.dumps(artifact), encoding="utf-8")
            with self.assertRaises(suite.SuiteError):
                suite.validate_device_browser_checkpoint(path, runtime)
            entries[0]["producer"]["selection"]["sameRenderedBlock"] = True
            entries[0]["consumer"]["endLeafBlockPath"] = "/html[1]/body[1]/p[2]"
            path.write_text(json.dumps(artifact), encoding="utf-8")
            with self.assertRaises(suite.SuiteError):
                suite.validate_device_browser_checkpoint(path, runtime)

    def test_controller_runs_producer_last_then_verifier_koreader_and_parity(self):
        runtime = self.runtime()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "output"
            output.mkdir()
            runtime_path = root / "runtime.json"
            runtime_path.write_text(json.dumps(runtime), encoding="utf-8")
            with mock.patch.object(suite, "run", side_effect=[0, 0, 0, 0, 0, 0]) as run_mock, \
                    mock.patch.object(suite, "validate_browser_outcomes") as outcomes_mock, \
                    mock.patch.object(suite, "validate_checkpoint") as validate_mock, \
                    mock.patch.object(suite, "validate_device_browser_checkpoint") as device_validate_mock, \
                    mock.patch.object(suite, "koreader_command", return_value=["koreader"]):
                statuses = suite.run_consumers(
                    REPO, "node", runtime_path, runtime, output
                )

            commands = [call.args[0] for call in run_mock.call_args_list]
            self.assertIn("--grep-invert", commands[0])
            self.assertEqual("web-to-koreader-producer|koreader-to-web-consumer", commands[0][-1])
            self.assertIn("--grep", commands[1])
            self.assertEqual("web-to-koreader-producer", commands[1][-1])
            self.assertTrue(commands[2][1].endswith("verify-web-reader-checkpoints.js"))
            self.assertEqual(["koreader"], commands[3])
            self.assertIn("koreader-to-web-consumer", commands[4])
            self.assertIn("--koreader-output", commands[4])
            self.assertTrue(commands[5][1].endswith("server_contract_parity.py"))
            checkpoint = output / "browser" / "producer" / "web-reader-checkpoints.json"
            validate_mock.assert_called_once_with(checkpoint, runtime)
            device_validate_mock.assert_called_once()
            self.assertEqual(3, outcomes_mock.call_count)
            self.assertEqual(0, statuses["parityStatus"])
            self.assertEqual(0, statuses["deviceBrowserStatus"])

    def test_controller_fail_fast_skips_invalid_dependants_but_runs_parity_last(self):
        runtime = self.runtime()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "output"
            output.mkdir()
            runtime_path = root / "runtime.json"
            runtime_path.write_text(json.dumps(runtime), encoding="utf-8")
            with mock.patch.object(suite, "run", side_effect=[1, 0]) as run_mock:
                statuses = suite.run_consumers(
                    REPO, "node", runtime_path, runtime, output
                )
            commands = [call.args[0] for call in run_mock.call_args_list]
            self.assertEqual(2, len(commands))
            self.assertIn("--grep-invert", commands[0])
            self.assertTrue(commands[1][1].endswith("server_contract_parity.py"))
            self.assertIsNone(statuses["browserProducerStatus"])
            self.assertIsNone(statuses["koreaderStatus"])
            self.assertIsNone(statuses["deviceBrowserStatus"])

    def test_controller_validates_the_exact_outer_node_version(self):
        completed = suite.subprocess.CompletedProcess(
            [sys.executable, "--version"], 0, "v24.1.0\n", ""
        )
        with mock.patch.object(suite.subprocess, "run", return_value=completed):
            executable, version = suite.validate_node_executable(
                Path(sys.executable), REPO, expected_version="v24.1.0"
            )
            self.assertEqual(str(Path(sys.executable).resolve()), executable)
            self.assertEqual("v24.1.0", version)
            with self.assertRaisesRegex(suite.SuiteError, "version changed"):
                suite.validate_node_executable(
                    Path(sys.executable), REPO, expected_version="v22.0.0"
                )

    def test_controller_rejects_relative_or_missing_node(self):
        with self.assertRaisesRegex(suite.SuiteError, "absolute path"):
            suite.validate_node_executable(Path("node"), REPO)
        with self.assertRaisesRegex(suite.SuiteError, "does not exist"):
            suite.validate_node_executable(REPO / "build" / "missing-node", REPO)

    def test_controller_rejects_unsupported_node_major(self):
        completed = suite.subprocess.CompletedProcess(
            [sys.executable, "--version"], 0, "v18.20.8\n", ""
        )
        with mock.patch.object(suite.subprocess, "run", return_value=completed):
            with self.assertRaisesRegex(suite.SuiteError, r"20\+"):
                suite.validate_node_executable(Path(sys.executable), REPO)


class AcceptanceReportTests(unittest.TestCase):
    def test_synthetic_highlight_fixture_forces_a_real_inline_boundary(self):
        fixture_path = REPO / "tests" / "emulator" / "grimmory_fixture_server.py"
        spec = importlib.util.spec_from_file_location(
            "inline_boundary_fixture", fixture_path)
        fixture = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fixture)
        epub = fixture.synthetic_epub({
            "id": 9000,
            "title": "Synthetic",
            "authors": ["Fixture Author"],
        })
        with zipfile.ZipFile(io.BytesIO(epub)) as archive:
            chapter = archive.read("OEBPS/chapter-01.xhtml").decode("utf-8")
        self.assertIn("<em>“Record</em> what changed", chapter)
        self.assertNotIn("<p>“Record what changed", chapter)

        driver = (REPO / "tests" / "emulator" / "acceptance_driver.koplugin"
                  / "main.lua").read_text(encoding="utf-8")
        self.assertIn("exercises a real EPUB inline-element boundary", driver)
        self.assertNotIn('if self.book.kind ~= "synthetic" then', driver)

    def test_session_uses_koreaders_broadcast_device_lifecycle(self):
        driver = (REPO / "tests" / "emulator" / "acceptance_driver.koplugin"
                  / "main.lua").read_text(encoding="utf-8")
        self.assertIn('UIManager:broadcastEvent(resume_event)', driver)
        self.assertIn('UIManager:broadcastEvent(suspend_event)', driver)
        self.assertIn('resume_event.handler == "onResume"', driver)
        self.assertIn('suspend_event.handler == "onSuspend"', driver)
        self.assertNotIn('self.reader:handleEvent(Event:new("Resume"))', driver)
        self.assertNotIn('self.reader:handleEvent(Event:new("Suspend"))', driver)

    def test_session_toggle_rejects_the_stale_filemanager_owner(self):
        driver = (REPO / "tests" / "emulator" / "acceptance_driver.koplugin"
                  / "main.lua").read_text(encoding="utf-8")
        session = driver.split("function Driver:_sessionJourney()", 1)[1]
        session = session.split("function Driver:_finish", 1)[0]
        self.assertIn("local reader_app = self.reader and self.reader.grimmory", session)
        self.assertIn("reader_app.ui == self.reader", session)
        self.assertIn("reader_app.ui.grimmory_sync == self.sync", session)
        self.assertIn("self.app ~= reader_app", session)
        self.assertIn("self.app.ui.grimmory_sync ~= self.sync", session)
        self.assertNotIn('self.app:_setSyncOption("sync_reading_sessions"', session)
        self.assertIn('item.action == "toggle_sessions"', session)
        self.assertIn("connection_menu.onMenuChoice(connection_menu, session_item)", session)
        self.assertIn("self.sync.sync_reading_sessions == false", session)
        self.assertIn("self.sync.sync_reading_sessions == true", session)

    def test_footer_visibility_poll_has_no_geometry_toctou_or_forced_click(self):
        source = (REPO / "tests" / "compatibility"
                  / "browser_helpers.js").read_text(encoding="utf-8")
        body = source.split("async function visibleSectionControl", 1)[1]
        body = body.split("async function clickSectionControlLikeUser", 1)[0]
        self.assertIn("await expect.poll", body)
        self.assertEqual(1, body.count("boundingBox()"))
        self.assertNotIn("const box =", body)
        self.assertNotIn("force: true", body)

    def test_device_annotation_cross_engine_oracle_precedes_cleanup(self):
        driver = (REPO / "tests" / "emulator" / "acceptance_driver.koplugin"
                  / "main.lua").read_text(encoding="utf-8")
        browser = (REPO / "tests" / "compatibility"
                   / "web_reader_journeys.spec.js").read_text(encoding="utf-8")
        helpers = (REPO / "tests" / "compatibility"
                   / "browser_helpers.js").read_text(encoding="utf-8")
        self.assertIn("_waitForDeviceAnnotationForBrowser", driver)
        self.assertNotIn("_waitForDeviceAnnotationThenDelete", driver)
        self.assertIn("deviceAnnotationAdopted", driver)
        self.assertIn("resolveLoadedCfiRange", browser)
        self.assertIn(".toBe(device.text)", browser)
        self.assertIn(".toBe(server.text)", browser)
        self.assertIn("expect(annotation.text).toBe(selection.text)", helpers)
        self.assertNotIn("selection.text.slice(0, Math.min(12", helpers)
        self.assertIn("pos0 = pos0", driver)
        self.assertIn("pos1 = pos1", driver)

        start = reader_verifier.parse_selection_xpointer(
            "/body/DocFragment[25]/body/div/p[172]/text().0"
        )
        end = reader_verifier.parse_selection_xpointer(
            "/body/DocFragment[25]/body/div/p[172]/span/text().5"
        )
        self.assertEqual("/body/DocFragment[25]/body/div/p[172]",
                         start["blockPath"])
        self.assertEqual(start["blockPath"], end["blockPath"])
        self.assertEqual("", start["inlinePath"])
        self.assertEqual("span", end["inlinePath"])
        valid_selection = {
            "pos0": "/body/DocFragment[25]/body/div/p[172]/text().0",
            "pos1": "/body/DocFragment[25]/body/div/p[172]/span/text().5",
            "startBlockPath": "/body/DocFragment[25]/body/div/p[172]",
            "endBlockPath": "/body/DocFragment[25]/body/div/p[172]",
            "startInlinePath": "",
            "endInlinePath": "span",
        }
        self.assertEqual(
            valid_selection,
            reader_verifier.require_device_selection_evidence(
                {"selection": valid_selection}, "real-1001"
            ),
        )
        for malformed in (
            None,
            "body/DocFragment[25]/body/div/p[172]/text().0",
            "/body/DocFragment[25]/div/p[172]/text().0",
            "/body/DocFragment[0]/body/div/p[172]/text().0",
            "/body/DocFragment[25]/body/div/p[172]/text()",
            "/body/DocFragment[25]/body/div/p[172]/text().0.trailing",
            "/body/DocFragment[25]/body/div/p[172]/span[0]/text().5",
        ):
            with self.subTest(malformed=malformed):
                self.assertIsNone(
                    reader_verifier.parse_selection_xpointer(malformed)
                )
                mutated = dict(valid_selection, pos0=malformed)
                with self.assertRaises(reader_verifier.VerificationError):
                    reader_verifier.require_device_selection_evidence(
                        {"selection": mutated}, "real-1001"
                    )
        with self.assertRaises(reader_verifier.VerificationError):
            reader_verifier.require_device_selection_evidence({}, "real-1001")
        with self.assertRaises(reader_verifier.VerificationError):
            reader_verifier.require_device_selection_evidence(
                {"selection": dict(valid_selection,
                                   pos1=valid_selection["pos0"])},
                "real-1001",
            )
        with self.assertRaises(reader_verifier.VerificationError):
            reader_verifier.require_device_selection_evidence(
                {"selection": dict(valid_selection,
                                   endInlinePath="em[1]")},
                "real-1001",
            )

    def test_driver_uses_native_event_handler_and_actual_dashboard_selection(self):
        source = (REPO / "tests" / "emulator" / "acceptance_driver.koplugin"
                  / "main.lua").read_text(encoding="utf-8")
        self.assertIn("handler = event.handler", source)
        self.assertIn('event.handler == "onGotoXPointer"', source)
        self.assertIn('event.handler == "onGotoPercent"', source)
        self.assertNotIn("name = event.name", source)
        self.assertIn("local dashboard_cards = self:_assertDashboardMetadata()", source)
        self.assertIn("self.observations.dashboardVisibleAuthor", source)
        self.assertIn("text = author_widget and author_widget.text", source)
        self.assertNotIn("self.observations.dashboardSyntheticAuthor", source)

    def test_painted_control_oracle_rejects_blank_or_unframed_pixels(self):
        rect = {"x": 0, "y": 0, "w": 100, "h": 50}
        blank = Image.new("L", (100, 50), 255)
        self.assertFalse(metadata_verifier.control_pixel_check(
            blank, rect, True)["passed"])

        text_only = blank.copy()
        ImageDraw.Draw(text_only).rectangle((35, 20, 65, 30), fill=0)
        self.assertFalse(metadata_verifier.control_pixel_check(
            text_only, rect, True)["passed"])

        painted_button = blank.copy()
        ImageDraw.Draw(painted_button).rectangle((0, 0, 99, 49),
                                                  outline=0, width=2)
        self.assertTrue(metadata_verifier.control_pixel_check(
            painted_button, rect, True)["passed"])

    def test_widget_bounds_must_be_inside_screen_and_card(self):
        child = {"x": 20, "y": 30, "w": 80, "h": 20}
        card = {"x": 10, "y": 10, "w": 100, "h": 50}
        self.assertTrue(metadata_verifier.valid_rect(child, 1072, 1448))
        self.assertTrue(metadata_verifier.rect_within(child, card))
        clipped = dict(child, y=50)
        self.assertFalse(metadata_verifier.rect_within(clipped, card))

    def test_metadata_verifier_rejects_expected_text_reported_as_actual(self):
        with tempfile.TemporaryDirectory() as directory:
            result_path = Path(directory) / "metadata.json"
            (result_path.parent / "metadata-dashboard.png").write_bytes(b"painted")
            checks = metadata_verifier.verify_painted_surfaces(
                metadata_verifier,
                {"books": [{
                    "alias": "visible-real",
                    "expectedKoreaderMetadata": {"authors": ["Expected Author"]},
                }]},
                {
                    "screenshots": ["metadata-dashboard.png"],
                    "observations": {"dashboardVisibleAuthor": {
                        "alias": "visible-real",
                        "text": "Different Rendered Author",
                        "bounds": {"x": 10, "y": 10, "w": 80, "h": 20},
                        "cardBounds": {"x": 0, "y": 0, "w": 100, "h": 100},
                    }},
                },
                result_path,
            )
            dashboard = checks[-1]
            self.assertFalse(dashboard["exactVisibleBookIdentity"])
            self.assertFalse(dashboard["passed"])

    def test_session_verifier_requires_exact_koreader_fingerprint(self):
        expected = {
            "bookId": 3,
            "bookType": "EPUB",
            "startTime": "2026-08-10T10:00:00Z",
            "endTime": "2026-08-10T10:00:31Z",
            "durationSeconds": 31,
            "startProgress": 38.1,
            "endProgress": 47.2,
            "progressDelta": 9.1,
            "startLocation": "epubcfi(start)",
            "endLocation": "epubcfi(end)",
        }
        self.assertTrue(reader_verifier.session_matches(dict(expected), expected))
        self.assertEqual("2026-08-10T10:00:00Z", reader_verifier.utc_timestamp(1786356000))
        old_match = dict(expected, id=10)
        new_match = dict(expected, id=11)
        self.assertEqual(
            [new_match],
            reader_verifier.sessions_created_since([old_match, new_match], ["10"]),
        )
        self.assertEqual(
            [], reader_verifier.sessions_created_since([old_match], [10]),
            "an old exact payload must not masquerade as this run's upload",
        )
        for field, mutation in {
            "startTime": "2026-08-10T09:00:00Z",
            "durationSeconds": 32,
            # This was inside the old 0.0001 epsilon and must still be rejected.
            "progressDelta": 9.10005,
            "startLocation": "epubcfi(other-start)",
            "endLocation": "epubcfi(other-end)",
        }.items():
            with self.subTest(field=field):
                self.assertFalse(reader_verifier.session_matches(
                    dict(expected, **{field: mutation}), expected
                ))

    def test_progress_verifier_models_exact_server_float_persistence(self):
        self.assertEqual(9.55,
                         reader_verifier.progress_percentage_at_server_precision(9.55))
        self.assertEqual(80.2024,
                         reader_verifier.progress_percentage_at_server_precision(
                             80.20244378595966))
        self.assertEqual(0.0489749,
                         reader_verifier.progress_percentage_at_server_precision(
                             0.048974891144804356))
        self.assertNotEqual(9.6,
                            reader_verifier.progress_percentage_at_server_precision(
                                9.55))
        self.assertNotEqual(80.202,
                            reader_verifier.progress_percentage_at_server_precision(
                                80.20244378595966))

    def test_suite_report_links_all_private_review_surfaces(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            paths = [
                output / "browser" / "journeys" / "report" / "index.html",
                output / "browser" / "journeys" / "web-reader-checkpoints.json",
                output / "browser" / "producer" / "report" / "index.html",
                output / "browser" / "producer" / "web-reader-checkpoints.json",
                output / "koreader" / "report" / "index.html",
                output / "koreader" / "reader-server-verification.json",
                output / "browser" / "device-consumer" / "report" / "index.html",
                output / "browser" / "device-consumer" / "web-reader-checkpoints.json",
                output / "koreader" / "metadata" / "cover-verification.json",
                output / "parity" / "report.json",
                output / "source-provenance.json",
                output / "suite-summary.json",
            ]
            for path in paths:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("{}", encoding="utf-8")
            suite.write_suite_report(output, {
                "browserJourneys": "passed", "browserProducer": "passed",
                "checkpoint": "passed", "koreader": "passed", "deviceBrowser": "passed",
                "parity": "passed",
                "sourceProvenance": "passed",
            })
            document = (output / "index.html").read_text(encoding="utf-8")
            self.assertIn("browser/journeys/report/index.html", document)
            self.assertIn("browser/journeys/web-reader-checkpoints.json", document)
            self.assertIn("browser/producer/report/index.html", document)
            self.assertIn("browser/producer/web-reader-checkpoints.json", document)
            self.assertIn("reader-server-verification.json", document)
            self.assertIn("browser/device-consumer/report/index.html", document)
            self.assertIn("browser/device-consumer/web-reader-checkpoints.json", document)
            self.assertIn("parity/report.json", document)
            self.assertIn("source-provenance.json", document)

    def test_documented_complete_command_has_outer_teardown_owner(self):
        document = (REPO / "tests" / "README.md").read_text(encoding="utf-8")
        self.assertIn("grimmory-real-stack.py run", document)
        self.assertIn("run-grimmory-compatibility-suite.py", document)
        self.assertIn("--runtime '{runtime}'", document)
        self.assertIn("tears down", document)

    def test_report_uses_aliases_and_links_private_screenshots(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            journey = root / "reader-real-1"
            journey.mkdir()
            (journey / "shot.png").write_bytes(b"png")
            (journey / "real-1.json").write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "mode": "reader",
                        "alias": "real-1",
                        "passed": True,
                        "assertions": [{"pass": True}],
                        "screenshots": ["shot.png"],
                        "durationSeconds": 4,
                    }
                ),
                encoding="utf-8",
            )
            output = root / "report"
            self.assertEqual(0, report.build_report(root, output))
            summary = json.loads((output / "summary.json").read_text(encoding="utf-8"))
            self.assertEqual(1, summary["passed"])
            document = (output / "index.html").read_text(encoding="utf-8")
            self.assertIn("real-1", document)
            self.assertIn("shot.png", document)


if __name__ == "__main__":
    unittest.main()
