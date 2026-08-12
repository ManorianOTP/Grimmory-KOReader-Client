#!/usr/bin/env python3
"""Strict visual-reference comparison and approval workflow.

The ``compare`` command is deliberately read-only with respect to reference
images.  References can only be created with ``bootstrap`` and can only be
replaced with ``approve``.
"""

from __future__ import print_function

import argparse
import hashlib
import html
import json
import os
import shutil
import sys
import tempfile
from collections import Counter
from pathlib import Path

try:
    from PIL import Image, ImageChops, ImageDraw
    _PILLOW_ERROR = None
except ImportError as exc:  # Keep --help usable when the optional dependency is absent.
    Image = None
    ImageChops = None
    ImageDraw = None
    _PILLOW_ERROR = exc


MAX_CHANNEL_TOLERANCE = 8
MAX_CHANGED_PIXELS = 1000
MAX_CHANGED_RATIO = 0.005
SOURCE_FINGERPRINT_PREFIX = "sha256:"


class VisualRegressionError(Exception):
    """A user-facing configuration or workflow error."""


def _hash_field(digest, value):
    """Hash one length-delimited byte field without concatenation ambiguity."""
    digest.update(len(value).to_bytes(8, byteorder="big"))
    digest.update(value)


def source_fingerprint(source_roots):
    """Fingerprint installed production and visual-driver trees deterministically."""
    roots = []
    labels = set()
    for value in source_roots:
        root = Path(value)
        if not root.is_dir():
            raise VisualRegressionError("Source root is not a directory: {}".format(root))
        label = root.name
        if label in labels:
            raise VisualRegressionError("Duplicate source-root name: {}".format(label))
        labels.add(label)
        roots.append((label, root))

    if not roots:
        raise VisualRegressionError("At least one --source root is required.")

    digest = hashlib.sha256()
    digest.update(b"grimmory-visual-sources-v1\0")
    for label, root in sorted(roots, key=lambda item: item[0]):
        entries = []
        for path in root.rglob("*"):
            if path.is_symlink() or path.is_file():
                entries.append(path)
        for path in sorted(entries, key=lambda item: item.relative_to(root).as_posix()):
            relative = "{}/{}".format(label, path.relative_to(root).as_posix())
            if path.is_symlink():
                kind = b"symlink"
                content = os.readlink(str(path)).encode("utf-8", "surrogateescape")
            else:
                kind = b"file"
                try:
                    content = path.read_bytes()
                except OSError as exc:
                    raise VisualRegressionError(
                        "Could not read source file {}: {}".format(path, exc)
                    ) from exc
            _hash_field(digest, kind)
            _hash_field(digest, relative.encode("utf-8", "surrogateescape"))
            _hash_field(digest, content)
    return SOURCE_FINGERPRINT_PREFIX + digest.hexdigest()


def run_fingerprint(args):
    print(source_fingerprint(args.source))
    return 0


def _capture_ids(root, suffix):
    root = Path(root)
    if not root.is_dir():
        raise VisualRegressionError("Capture root is not a directory: {}".format(root))
    return {
        path.relative_to(root).with_suffix("").as_posix(): path
        for path in root.rglob("*" + suffix)
        if path.is_file()
    }


def run_verify_provenance(args):
    expected = source_fingerprint(args.source)
    json_results = _capture_ids(args.captures, ".json")
    png_results = _capture_ids(args.captures, ".png")
    if not json_results and not png_results:
        raise VisualRegressionError("No JSON results or PNG captures were found.")

    missing_json = sorted(set(png_results) - set(json_results))
    missing_png = sorted(set(json_results) - set(png_results))
    if missing_json or missing_png:
        details = []
        if missing_json:
            details.append("PNG without JSON: {}".format(", ".join(missing_json)))
        if missing_png:
            details.append("JSON without PNG: {}".format(", ".join(missing_png)))
        raise VisualRegressionError(
            "Capture/result set is mixed or incomplete; " + "; ".join(details)
        )

    mismatches = []
    for case_id, path in sorted(json_results.items()):
        try:
            result = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise VisualRegressionError("Could not read result {}: {}".format(path, exc)) from exc
        actual = result.get("source_fingerprint")
        if actual != expected:
            mismatches.append("{} ({})".format(case_id, actual or "missing"))
    if mismatches:
        raise VisualRegressionError(
            "Capture provenance does not match current sources {}: {}".format(
                expected, ", ".join(mismatches)
            )
        )

    record = {
        "format_version": 1,
        "source_fingerprint": expected,
        "results": len(json_results),
    }
    if args.record:
        target = Path(args.record)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(
            json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
    print(json.dumps(record, sort_keys=True))
    return 0


def require_pillow():
    if Image is None:
        raise VisualRegressionError(
            "Pillow is required for visual comparison. Install it with "
            "`python -m pip install Pillow`, then rerun the command. "
            "Import error: {}".format(_PILLOW_ERROR)
        )


def normalise_case_id(value):
    value = value.replace("\\", "/").strip("/")
    if value.lower().endswith(".png"):
        value = value[:-4]
    parts = value.split("/")
    if not value or any(part in ("", ".", "..") for part in parts):
        raise VisualRegressionError("Invalid case name: {!r}".format(value))
    return value


def discover_images(root):
    root = Path(root)
    if not root.exists():
        return {}
    if not root.is_dir():
        raise VisualRegressionError("Image root is not a directory: {}".format(root))

    images = {}
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.suffix.lower() != ".png":
            continue
        relative = path.relative_to(root)
        case_id = relative.with_suffix("").as_posix()
        if case_id in images:
            raise VisualRegressionError(
                "Two PNGs resolve to the same case name {!r} under {}".format(case_id, root)
            )
        images[case_id] = path
    return images


def selected_case_ids(current, references, requested):
    if requested:
        return sorted(set(normalise_case_id(case_id) for case_id in requested))
    return sorted(set(current) | set(references))


def validate_thresholds(args):
    if not 0 <= args.channel_tolerance <= MAX_CHANNEL_TOLERANCE:
        raise VisualRegressionError(
            "--channel-tolerance must be between 0 and {}".format(MAX_CHANNEL_TOLERANCE)
        )
    if args.max_changed_pixels is not None and not (
        0 <= args.max_changed_pixels <= MAX_CHANGED_PIXELS
    ):
        raise VisualRegressionError(
            "--max-changed-pixels must be between 0 and {}".format(MAX_CHANGED_PIXELS)
        )
    if args.max_changed_ratio is not None and not (
        0.0 <= args.max_changed_ratio <= MAX_CHANGED_RATIO
    ):
        raise VisualRegressionError(
            "--max-changed-ratio must be between 0 and {}".format(MAX_CHANGED_RATIO)
        )


def artifact_case_dir(artifacts_root, case_id):
    return Path(artifacts_root) / "cases" / Path(*case_id.split("/"))


def copy_artifact(source, target):
    if source is None:
        return None
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(str(source), str(target))
    return target


def load_png(path):
    with Image.open(str(path)) as opened:
        if opened.format != "PNG":
            raise VisualRegressionError(
                "Expected PNG image data in {}, found {}.".format(path, opened.format or "unknown")
            )
        return opened.convert("RGBA")


def make_pixel_diff(current_image, target, changed_mask):
    """Write a high-contrast diff: dim greyscale unchanged pixels, magenta changes."""
    dimmed = current_image.convert("L").point(
        [max(16, int(value * 0.22)) for value in range(256)]
    )
    dimmed_rgba = Image.merge(
        "RGBA",
        (dimmed, dimmed, dimmed, Image.new("L", current_image.size, 255)),
    )
    changed_rgba = Image.new("RGBA", current_image.size, (255, 0, 255, 255))
    diff_image = Image.composite(changed_rgba, dimmed_rgba, changed_mask)
    target.parent.mkdir(parents=True, exist_ok=True)
    diff_image.save(str(target), "PNG")


def make_dimension_diff(current_image, reference_size, target):
    width = max(current_image.width, reference_size[0], 80)
    height = max(current_image.height, reference_size[1], 40)
    canvas = Image.new("RGBA", (width, height), (30, 30, 30, 255))
    canvas.paste(current_image, (0, 0))
    draw = ImageDraw.Draw(canvas)
    draw.rectangle((0, 0, width - 1, height - 1), outline=(255, 0, 255, 255), width=3)
    draw.line((reference_size[0] - 1, 0, reference_size[0] - 1, height), fill=(255, 255, 0, 255), width=2)
    draw.line((0, reference_size[1] - 1, width, reference_size[1] - 1), fill=(255, 255, 0, 255), width=2)
    target.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(str(target), "PNG")


def threshold_passes(changed_pixels, total_pixels, args):
    if args.max_changed_pixels is None and args.max_changed_ratio is None:
        return changed_pixels == 0
    if args.max_changed_pixels is not None and changed_pixels > args.max_changed_pixels:
        return False
    changed_ratio = float(changed_pixels) / total_pixels if total_pixels else 0.0
    if args.max_changed_ratio is not None and changed_ratio > args.max_changed_ratio:
        return False
    return True


def compare_pair(case_id, reference_path, current_path, artifacts_root, args):
    case_dir = artifact_case_dir(artifacts_root, case_id)
    before_artifact = copy_artifact(reference_path, case_dir / "before.png")
    current_artifact = copy_artifact(current_path, case_dir / "current.png")
    result = {
        "case": case_id,
        "status": None,
        "passed": False,
        "reference": str(reference_path) if reference_path else None,
        "current": str(current_path) if current_path else None,
        "artifacts": {
            "before": str(before_artifact) if before_artifact else None,
            "current": str(current_artifact) if current_artifact else None,
            "diff": None,
        },
    }

    if reference_path is None:
        result["status"] = "missing_reference"
        result["message"] = (
            "No approved reference exists. Use the explicit bootstrap command after review."
        )
        return result
    if current_path is None:
        result["status"] = "missing_current"
        result["message"] = "The approved case was not captured in this run."
        return result

    try:
        reference_image = load_png(reference_path)
        current_image = load_png(current_path)
    except Exception as exc:
        result["status"] = "invalid_image"
        result["message"] = "Could not decode PNG: {}".format(exc)
        return result

    result["reference_size"] = list(reference_image.size)
    result["current_size"] = list(current_image.size)
    diff_path = case_dir / "diff.png"
    result["artifacts"]["diff"] = str(diff_path)

    if reference_image.size != current_image.size:
        make_dimension_diff(current_image, reference_image.size, diff_path)
        result["status"] = "dimension_mismatch"
        result["message"] = "Reference is {}x{}; current is {}x{}.".format(
            reference_image.width,
            reference_image.height,
            current_image.width,
            current_image.height,
        )
        return result

    difference = ImageChops.difference(reference_image, current_image)
    channels = difference.split()
    maximum_delta = channels[0]
    for channel in channels[1:]:
        maximum_delta = ImageChops.lighter(maximum_delta, channel)
    max_channel_delta = maximum_delta.getextrema()[1]
    changed_mask = maximum_delta.point(
        [0] * (args.channel_tolerance + 1)
        + [255] * (255 - args.channel_tolerance)
    )
    changed_pixels = changed_mask.histogram()[255]

    total_pixels = reference_image.width * reference_image.height
    changed_ratio = float(changed_pixels) / total_pixels if total_pixels else 0.0
    make_pixel_diff(current_image, diff_path, changed_mask)
    result.update(
        {
            "changed_pixels": changed_pixels,
            "total_pixels": total_pixels,
            "changed_ratio": changed_ratio,
            "max_channel_delta": max_channel_delta,
        }
    )
    result["passed"] = threshold_passes(changed_pixels, total_pixels, args)
    result["status"] = "matched" if result["passed"] else "pixel_mismatch"
    result["message"] = (
        "Pixel-identical within configured limits."
        if result["passed"]
        else "{} of {} pixels changed ({:.6%}).".format(
            changed_pixels, total_pixels, changed_ratio
        )
    )
    return result


def relative_artifact(report_root, value):
    if not value:
        return None
    try:
        return Path(value).resolve().relative_to(Path(report_root).resolve()).as_posix()
    except ValueError:
        return Path(value).as_posix()


def write_html_report(report, target):
    rows = []
    for case in report["cases"]:
        links = []
        for label in ("before", "current", "diff"):
            relative = relative_artifact(target.parent, case["artifacts"].get(label))
            if relative:
                links.append(
                    '<a href="{}"><img src="{}" alt="{} {}"></a>'.format(
                        html.escape(relative, quote=True),
                        html.escape(relative, quote=True),
                        html.escape(case["case"], quote=True),
                        label,
                    )
                )
        css_class = "pass" if case["passed"] else "fail"
        rows.append(
            '<tr class="{}"><td><code>{}</code></td><td>{}</td><td>{}</td><td class="images">{}</td></tr>'.format(
                css_class,
                html.escape(case["case"]),
                html.escape(case["status"]),
                html.escape(case.get("message", "")),
                "".join(links),
            )
        )

    document = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Visual regression report</title>
<style>
body{{font-family:system-ui,sans-serif;margin:2rem;color:#202124}}table{{border-collapse:collapse;width:100%}}
th,td{{border:1px solid #dadce0;padding:.6rem;text-align:left;vertical-align:top}}.pass{{background:#e6f4ea}}.fail{{background:#fce8e6}}
.images{{display:flex;gap:.5rem;flex-wrap:wrap}}.images img{{max-width:240px;max-height:180px;border:1px solid #888;background:#fff}}
code{{white-space:nowrap}}
</style></head><body>
<h1>Visual regression report</h1><p>{summary}</p>
<table><thead><tr><th>Case</th><th>Status</th><th>Details</th><th>Before / current / diff</th></tr></thead>
<tbody>{rows}</tbody></table></body></html>
""".format(
        summary=html.escape(
            "{} passed, {} failed".format(
                report["summary"]["passed"], report["summary"]["failed"]
            )
        ),
        rows="".join(rows),
    )
    target.write_text(document, encoding="utf-8")


def write_gallery(report, target):
    """Write a compact current-state gallery for human visual approval."""
    groups = {}
    for case in report["cases"]:
        case_id = case["case"]
        group = case_id.split("/", 1)[0] if "/" in case_id else "other"
        groups.setdefault(group, []).append(case)

    sections = []
    for group, cases in sorted(groups.items()):
        cards = []
        for case in cases:
            artifact = case["artifacts"].get("current") or case["artifacts"].get("before")
            relative = relative_artifact(target.parent, artifact)
            if relative:
                preview = (
                    '<a href="{path}"><img src="{path}" alt="{case}"></a>'.format(
                        path=html.escape(relative, quote=True),
                        case=html.escape(case["case"], quote=True),
                    )
                )
            else:
                preview = '<div class="missing">No image captured</div>'
            css_class = "pass" if case["passed"] else "fail"
            cards.append(
                '<article class="card {css}"><h3>{case}</h3><p>{status}</p>{preview}</article>'.format(
                    css=css_class,
                    case=html.escape(case["case"]),
                    status=html.escape(case["status"]),
                    preview=preview,
                )
            )
        sections.append(
            "<section><h2>{}</h2><div class=\"grid\">{}</div></section>".format(
                html.escape(group.title()), "".join(cards)
            )
        )

    document = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>KOReader visual gallery</title>
<style>
body{{font-family:system-ui,sans-serif;margin:1.5rem;color:#202124;background:#f5f5f5}}
h1,h2{{margin-bottom:.5rem}}.grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:1rem}}
.card{{background:white;border:2px solid #b8b8b8;border-radius:8px;padding:.75rem;overflow:hidden}}
.card.pass{{border-color:#2e7d32}}.card.fail{{border-color:#c62828}}.card h3{{font-size:1rem;margin:0;word-break:break-word}}
.card p{{margin:.3rem 0;color:#555}}.card img{{display:block;width:100%;height:auto;max-height:640px;object-fit:contain;background:white}}
.missing{{min-height:12rem;display:grid;place-items:center;background:#eee;color:#666}}
</style></head><body><h1>KOReader visual gallery</h1>
<p>{summary}. Click any image for its original pixels.</p>{sections}</body></html>
""".format(
        summary=html.escape(
            "{} passed, {} failed".format(
                report["summary"]["passed"], report["summary"]["failed"]
            )
        ),
        sections="".join(sections),
    )
    target.write_text(document, encoding="utf-8")


def run_compare(args):
    require_pillow()
    validate_thresholds(args)
    current = discover_images(args.current)
    references = discover_images(args.references)
    case_ids = selected_case_ids(current, references, args.case)
    artifacts = Path(args.artifacts)
    artifacts.mkdir(parents=True, exist_ok=True)

    cases = [
        compare_pair(
            case_id,
            references.get(case_id),
            current.get(case_id),
            artifacts,
            args,
        )
        for case_id in case_ids
    ]
    if not cases:
        cases.append(
            {
                "case": "<suite>",
                "status": "no_cases",
                "passed": False,
                "message": "No PNG captures or references were found.",
                "artifacts": {"before": None, "current": None, "diff": None},
            }
        )

    status_counts = Counter(case["status"] for case in cases)
    passed = sum(1 for case in cases if case["passed"])
    report = {
        "format_version": 1,
        "passed": passed == len(cases),
        "config": {
            "current": str(Path(args.current).resolve()),
            "references": str(Path(args.references).resolve()),
            "channel_tolerance": args.channel_tolerance,
            "max_changed_pixels": args.max_changed_pixels,
            "max_changed_ratio": args.max_changed_ratio,
        },
        "summary": {
            "total": len(cases),
            "passed": passed,
            "failed": len(cases) - passed,
            "statuses": dict(sorted(status_counts.items())),
        },
        "cases": cases,
    }
    json_target = artifacts / "report.json"
    html_target = artifacts / "index.html"
    gallery_target = artifacts / "gallery.html"
    json_target.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    write_html_report(report, html_target)
    write_gallery(report, gallery_target)
    print(json.dumps(report["summary"], sort_keys=True))
    print("JSON: {}".format(json_target))
    print("Review: {}".format(html_target))
    print("Gallery: {}".format(gallery_target))
    return 0 if report["passed"] else 1


def approval_case_ids(args, current):
    if args.all:
        selected = sorted(current)
    else:
        selected = sorted(set(normalise_case_id(case_id) for case_id in args.case))
    if not selected:
        raise VisualRegressionError("No current PNG captures were selected.")
    missing = [case_id for case_id in selected if case_id not in current]
    if missing:
        raise VisualRegressionError(
            "Current captures are missing for: {}".format(", ".join(missing))
        )
    return selected


def reference_target(root, case_id):
    return Path(root) / Path(*case_id.split("/")).with_suffix(".png")


def atomic_copy_reference(source, target):
    """Validate and atomically replace one reference, cleaning staging on any exit."""
    target = Path(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".{}-".format(target.name), suffix=".tmp", dir=str(target.parent)
    )
    os.close(descriptor)
    temporary_path = Path(temporary_name)
    try:
        shutil.copy2(str(source), str(temporary_path))
        load_png(temporary_path)
        os.replace(str(temporary_path), str(target))
    except Exception as exc:
        raise VisualRegressionError(
            "Could not atomically write reference {}: {}".format(target, exc)
        ) from exc
    finally:
        # Also runs for BaseException subclasses such as KeyboardInterrupt.
        try:
            temporary_path.unlink()
        except FileNotFoundError:
            pass


def run_reference_change(args, bootstrap):
    require_pillow()
    current = discover_images(args.current)
    selected = approval_case_ids(args, current)
    references = discover_images(args.references)

    # Validate every source before changing references. Each individual write is
    # atomic; a multi-case command may still have completed earlier cases if a
    # later filesystem operation fails.
    for case_id in selected:
        try:
            load_png(current[case_id])
        except Exception as exc:
            raise VisualRegressionError(
                "Cannot use current capture {!r} as a reference: {}".format(case_id, exc)
            )

    if bootstrap:
        invalid = [case_id for case_id in selected if case_id in references]
        action = "bootstrap"
        if invalid:
            raise VisualRegressionError(
                "Bootstrap never overwrites references; already present: {}".format(
                    ", ".join(invalid)
                )
            )
    else:
        invalid = [case_id for case_id in selected if case_id not in references]
        action = "approve"
        if invalid:
            raise VisualRegressionError(
                "Approve only replaces existing references. Bootstrap first: {}".format(
                    ", ".join(invalid)
                )
            )

    changed = []
    for case_id in selected:
        target = reference_target(args.references, case_id)
        atomic_copy_reference(current[case_id], target)
        changed.append({"case": case_id, "reference": str(target)})
    result = {"action": action, "count": len(changed), "references": changed}
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


def add_selection_arguments(parser):
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument("--case", action="append", help="Case name to change; repeatable")
    selection.add_argument("--all", action="store_true", help="Change every current capture")


def build_parser():
    parser = argparse.ArgumentParser(
        description="Compare KOReader screenshots with explicitly approved references."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    fingerprint = subparsers.add_parser(
        "fingerprint", help="Fingerprint production and visual-driver source trees"
    )
    fingerprint.add_argument(
        "--source", action="append", required=True, help="Source tree; repeatable"
    )
    fingerprint.set_defaults(handler=run_fingerprint)

    verify = subparsers.add_parser(
        "verify-provenance", help="Reject stale or mixed visual captures"
    )
    verify.add_argument("--captures", required=True, help="Capture/result root")
    verify.add_argument(
        "--source", action="append", required=True, help="Current source tree; repeatable"
    )
    verify.add_argument("--record", help="Write successful run provenance JSON here")
    verify.set_defaults(handler=run_verify_provenance)

    compare = subparsers.add_parser("compare", help="Compare captures; never changes references")
    compare.add_argument("--current", required=True, help="Directory containing current PNG captures")
    compare.add_argument("--references", required=True, help="Directory containing approved PNGs")
    compare.add_argument("--artifacts", required=True, help="Directory for JSON, HTML, and image artifacts")
    compare.add_argument("--case", action="append", help="Only compare this case; repeatable")
    compare.add_argument(
        "--channel-tolerance",
        type=int,
        default=0,
        help="Ignore per-channel deltas up to this value (default 0; maximum {})".format(
            MAX_CHANNEL_TOLERANCE
        ),
    )
    compare.add_argument(
        "--max-changed-pixels",
        type=int,
        help="Allow this many changed pixels (maximum {})".format(MAX_CHANGED_PIXELS),
    )
    compare.add_argument(
        "--max-changed-ratio",
        type=float,
        help="Allow this changed-pixel ratio (maximum {})".format(MAX_CHANGED_RATIO),
    )
    compare.set_defaults(handler=run_compare)

    bootstrap = subparsers.add_parser(
        "bootstrap", help="Explicitly register new references; never overwrites"
    )
    bootstrap.add_argument("--current", required=True)
    bootstrap.add_argument("--references", required=True)
    add_selection_arguments(bootstrap)
    bootstrap.set_defaults(handler=lambda args: run_reference_change(args, True))

    approve = subparsers.add_parser(
        "approve", help="Explicitly replace existing references; never creates new ones"
    )
    approve.add_argument("--current", required=True)
    approve.add_argument("--references", required=True)
    add_selection_arguments(approve)
    approve.set_defaults(handler=lambda args: run_reference_change(args, False))
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.handler(args)
    except VisualRegressionError as exc:
        print("visual-regression: {}".format(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
