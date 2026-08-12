#!/usr/bin/env python3
"""Build a small, private visual review page from KOReader acceptance JSON."""

from __future__ import annotations

import argparse
import html
import json
from pathlib import Path


def load_results(root: Path) -> list[tuple[Path, dict]]:
    rows: list[tuple[Path, dict]] = []
    for path in sorted(root.glob("*/*.json")):
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if payload.get("schemaVersion") == 1 and payload.get("mode") in {
            "metadata",
            "reader",
        }:
            rows.append((path, payload))
    return rows


def build_report(root: Path, output: Path) -> int:
    rows = load_results(root)
    output.mkdir(parents=True, exist_ok=True)
    passed = sum(item.get("passed") is True for _, item in rows)
    summary = {
        "schemaVersion": 1,
        "passed": passed,
        "failed": len(rows) - passed,
        "journeys": [
            {
                "mode": item.get("mode"),
                "phase": item.get("phase"),
                "alias": item.get("alias"),
                "passed": item.get("passed") is True,
                "assertionCount": len(item.get("assertions", [])),
                "screenshotCount": len(item.get("screenshots", [])),
                "durationSeconds": item.get("durationSeconds"),
            }
            for _, item in rows
        ],
    }
    (output / "summary.json").write_text(
        json.dumps(summary, indent=2) + "\n", encoding="utf-8"
    )

    cards: list[str] = []
    for result_path, item in rows:
        key = " / ".join(
            str(part) for part in (item.get("alias") or item.get("mode"), item.get("phase"))
            if part
        ) or result_path.parent.name
        state = "pass" if item.get("passed") else "fail"
        shots: list[str] = []
        for screenshot in item.get("screenshots", []):
            source = result_path.parent / screenshot
            if not source.is_file():
                continue
            relative = source.relative_to(output.parent).as_posix()
            shots.append(
                f'<figure><a href="../{html.escape(relative)}">'
                f'<img loading="lazy" src="../{html.escape(relative)}" '
                f'alt="{html.escape(str(key))} acceptance screenshot"></a>'
                f'<figcaption>{html.escape(Path(screenshot).stem)}</figcaption></figure>'
            )
        cards.append(
            f'<section class="card {state}"><h2>{html.escape(str(key))}</h2>'
            f'<p>{html.escape(str(item.get("mode")))} &middot; '
            f'{html.escape(str(item.get("phase") or "single phase"))} &middot; '
            f'{len(item.get("assertions", []))} checks &middot; '
            f'{html.escape(str(item.get("durationSeconds", "?")))} seconds &middot; '
            f'<strong>{state.upper()}</strong></p>'
            f'<div class="shots">{"".join(shots)}</div></section>'
        )

    document = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>KOReader full-server acceptance</title>
<style>
body{{font:16px system-ui,sans-serif;margin:2rem;background:#f4f4f4;color:#171717}}
.summary,.card{{background:white;border:1px solid #bbb;border-radius:12px;padding:1rem;margin:1rem 0}}
.pass{{border-left:8px solid #26834a}} .fail{{border-left:8px solid #b42318}}
.shots{{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:1rem}}
figure{{margin:0}} img{{width:100%;height:auto;border:1px solid #888;background:white}}
figcaption{{font-size:.85rem;overflow-wrap:anywhere;margin-top:.25rem}}
</style></head><body>
<h1>KOReader full-server acceptance</h1>
<div class="summary"><strong>{passed}/{len(rows)} journeys passed</strong>.
Screenshots are review artifacts from real server state, not strict pixel baselines.</div>
{"".join(cards)}
</body></html>"""
    (output / "index.html").write_text(document, encoding="utf-8")
    return 0 if rows and passed == len(rows) else 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    return build_report(args.input.resolve(), args.output.resolve())


if __name__ == "__main__":
    raise SystemExit(main())
