#!/usr/bin/env python3
"""Verify covers fetched by the production KOReader plugin against cache truth."""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path


FRAMED_CONTROLS = {"menu", "search", "close", "Back", "action"}
REQUIRED_DETAIL_CONTROLS = FRAMED_CONTROLS | {"Wi-Fi"}


def valid_rect(value, width: int, height: int) -> bool:
    if not isinstance(value, dict):
        return False
    try:
        x, y, w, h = (int(value[key]) for key in ("x", "y", "w", "h"))
    except (KeyError, TypeError, ValueError):
        return False
    return x >= 0 and y >= 0 and w > 0 and h > 0 \
        and x + w <= width and y + h <= height


def rect_within(child, parent) -> bool:
    if not isinstance(child, dict) or not isinstance(parent, dict):
        return False
    try:
        cx, cy, cw, ch = (int(child[key]) for key in ("x", "y", "w", "h"))
        px, py, pw, ph = (int(parent[key]) for key in ("x", "y", "w", "h"))
    except (KeyError, TypeError, ValueError):
        return False
    return cw > 0 and ch > 0 and pw > 0 and ph > 0 \
        and cx >= px and cy >= py \
        and cx + cw <= px + pw and cy + ch <= py + ph


def control_pixel_check(image, rect: dict, framed: bool) -> dict:
    """Prove the widget model's control is also present in saved pixels."""
    x, y, w, h = (int(rect[key]) for key in ("x", "y", "w", "h"))
    crop = image.crop((x, y, x + w, y + h)).convert("L")
    pixels = list(crop.getdata())
    ink = sum(value < 200 for value in pixels)
    minimum_ink = max(8, int(w * h * 0.004))
    result = {
        "inkPixels": ink,
        "minimumInkPixels": minimum_ink,
        "frameEdgesPresent": None,
        "passed": ink >= minimum_ink,
    }
    if not framed or not result["passed"]:
        return result

    # KOReader Buttons paint a dark rounded rectangle. Requiring ink along all
    # four edges rejects the observed body-only framebuffer, where stray body
    # text happened to overlap the model's footer-control rectangle.
    band = max(2, min(5, w // 12, h // 12))
    top = sum(crop.getpixel((px, py)) < 200
              for py in range(band) for px in range(w))
    bottom = sum(crop.getpixel((px, py)) < 200
                 for py in range(h - band, h) for px in range(w))
    left = sum(crop.getpixel((px, py)) < 200
               for py in range(h) for px in range(band))
    right = sum(crop.getpixel((px, py)) < 200
                for py in range(h) for px in range(w - band, w))
    edge_thresholds = (w * 0.20, w * 0.20, h * 0.20, h * 0.20)
    edges = (top, bottom, left, right)
    result["frameEdgesPresent"] = all(
        value >= threshold for value, threshold in zip(edges, edge_thresholds)
    )
    result["edgeInkPixels"] = {
        "top": top, "bottom": bottom, "left": left, "right": right,
    }
    result["passed"] = result["passed"] and result["frameEdgesPresent"]
    return result


def verify_painted_surfaces(tool, runtime: dict, result: dict,
                            result_path: Path) -> list[dict]:
    screenshot_names = set(result.get("screenshots") or [])
    surfaces = ((result.get("observations") or {}).get("detailSurfaces") or {})
    checks = []
    for book in runtime.get("books", []):
        alias = book["alias"]
        screenshot_name = f"{alias}-metadata-detail-top.png"
        screenshot_path = result_path.parent / screenshot_name
        surface = surfaces.get(alias) or {}
        controls = surface.get("controls") or {}
        item = {
            "alias": alias,
            "screenshot": screenshot_name,
            "passed": screenshot_name in screenshot_names and screenshot_path.is_file(),
            "controls": {},
            "scrollable": surface.get("scrollable"),
        }
        if item["passed"]:
            with tool.Image.open(screenshot_path) as opened:
                image = opened.convert("L")
                width, height = image.size
                item["dimensions"] = {"w": width, "h": height}
                item["passed"] = surface.get("screen") == item["dimensions"]
                for name in sorted(REQUIRED_DETAIL_CONTROLS):
                    rect = controls.get(name)
                    control = {"bounds": rect, "insideScreen": valid_rect(
                        rect, width, height)}
                    if control["insideScreen"]:
                        control.update(control_pixel_check(
                            image, rect, name in FRAMED_CONTROLS))
                    else:
                        control["passed"] = False
                    item["controls"][name] = control
                    item["passed"] = item["passed"] and control["passed"]
        if alias == "synthetic":
            sparse_only_top = surface.get("scrollable") is False \
                and f"{alias}-metadata-detail-middle.png" not in screenshot_names \
                and f"{alias}-metadata-detail-bottom.png" not in screenshot_names
            item["sparseNonScrollableOnlyTop"] = sparse_only_top
            item["passed"] = item["passed"] and sparse_only_top
        checks.append(item)

    dashboard = ((result.get("observations") or {})
                 .get("dashboardVisibleAuthor") or {})
    dashboard_alias = dashboard.get("alias")
    dashboard_book = next((book for book in runtime.get("books", [])
                           if book.get("alias") == dashboard_alias), None)
    expected_authors = ((dashboard_book or {}).get("expectedKoreaderMetadata")
                        or {}).get("authors") or []
    exact_identity = bool(dashboard_book and expected_authors) \
        and dashboard.get("text") == expected_authors[0]
    dashboard_name = "metadata-dashboard.png"
    dashboard_path = result_path.parent / dashboard_name
    dashboard_check = {
        "alias": f"dashboard-{dashboard_alias or 'missing'}-author",
        "screenshot": dashboard_name,
        "passed": dashboard_name in screenshot_names and dashboard_path.is_file()
                  and exact_identity,
        "exactVisibleBookIdentity": exact_identity,
        "expectedAuthor": expected_authors[0] if expected_authors else None,
        "actualAuthor": dashboard.get("text"),
        "bounds": dashboard.get("bounds"),
        "cardBounds": dashboard.get("cardBounds"),
    }
    if dashboard_check["passed"]:
        with tool.Image.open(dashboard_path) as opened:
            image = opened.convert("L")
            width, height = image.size
            bounds = dashboard.get("bounds")
            card = dashboard.get("cardBounds")
            dashboard_check["insideScreen"] = valid_rect(bounds, width, height)
            dashboard_check["insideCard"] = rect_within(bounds, card)
            if dashboard_check["insideScreen"]:
                pixels = control_pixel_check(image, bounds, False)
                dashboard_check["pixelEvidence"] = pixels
            else:
                pixels = {"passed": False}
            dashboard_check["passed"] = dashboard_check["insideScreen"] \
                and dashboard_check["insideCard"] and pixels["passed"]
    checks.append(dashboard_check)
    return checks


def load_metadata_tool(repo: Path):
    source = repo / "scripts" / "grimmory-metadata-cache.py"
    spec = importlib.util.spec_from_file_location("grimmory_metadata_cache", source)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load metadata cache verifier")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def verify(runtime_path: Path, result_path: Path, output: Path) -> int:
    repo = Path(__file__).resolve().parent.parent
    tool = load_metadata_tool(repo)
    runtime = json.loads(runtime_path.read_text(encoding="utf-8"))
    result = json.loads(result_path.read_text(encoding="utf-8"))
    source_fingerprint = runtime.get("sourceFingerprint")
    result_fingerprint = (result.get("provenance") or {}).get("sourceFingerprint")
    source_matches = bool(source_fingerprint) and result_fingerprint == source_fingerprint
    artifacts = result.get("coverArtifacts") or {}
    checks = []
    for book in runtime.get("books", []):
        alias = book["alias"]
        expected = book.get("expectedKoreaderMetadata") or {}
        name = artifacts.get(alias)
        path = result_path.parent / name if name else None
        actual_present = path is not None and path.is_file()
        passed = actual_present == (expected.get("coverPresent") is True)
        distance = None
        aspect_delta = None
        if passed and actual_present:
            actual = tool.cover_visual_fingerprint(path.read_bytes())
            reference = expected.get("coverVisualFingerprint") or {}
            left = actual.get("differenceHash256")
            right = reference.get("differenceHash256")
            distance = tool.hash_distance(left, right) if left and right else 257
            actual_ratio = actual.get("aspectRatio")
            expected_ratio = reference.get("aspectRatio")
            aspect_delta = (
                abs(float(actual_ratio) - float(expected_ratio))
                if actual_ratio is not None and expected_ratio is not None
                else 1.0
            )
            passed = distance <= 20 and aspect_delta <= 0.01
        checks.append(
            {
                "alias": alias,
                "passed": passed,
                "present": actual_present,
                "differenceHashDistance": distance,
                "aspectRatioDelta": aspect_delta,
            }
        )
    surface_checks = verify_painted_surfaces(tool, runtime, result, result_path)
    payload = {
        "schemaVersion": 2,
        "passed": source_matches and all(item["passed"] for item in checks)
            and all(item["passed"] for item in surface_checks),
        "sourceFingerprint": source_fingerprint,
        "sourceFingerprintMatches": source_matches,
        "checks": checks,
        "paintedSurfaceChecks": surface_checks,
        "comparison": "256-bit difference hash <=20; aspect-ratio delta <=0.01",
    }
    output.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return 0 if payload["passed"] else 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--result", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    return verify(args.runtime.resolve(), args.result.resolve(), args.output.resolve())


if __name__ == "__main__":
    raise SystemExit(main())
