#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
VISUAL_RUNNER="$REPO_ROOT/scripts/run-koreader-visual-tests.sh"
COMPANION_TOOL="$REPO_ROOT/scripts/real_epub_companions.py"
PREPARE_TOOL="$REPO_ROOT/scripts/prepare-grimmory-visual-library.py"
PRIVATE_BUILD="$REPO_ROOT/build/grimmory-fixture"

die() {
    echo "run-real-epub-companions: $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: scripts/run-real-epub-companions.sh --source-dir DIR --output DIR [options]

Runs the selected visual tests once with deterministic synthetic data and then
again with the mapped private EPUB(s). Private files, covers, metadata and
screenshots remain below ignored build output.

Options:
  --source-dir DIR      directory containing the eight private EPUBs
  --metadata-cache DIR  ignored cache used to match source files by SHA-256
  --source-map FILE     ignored ID-to-path map used before a cache exists
  --output DIR          new/empty paired-run output directory
  --scenario NAME       limit to one scenario (repeatable)
  --orientation VALUE   portrait, landscape, or both (default: both)
  --capture-only        skip approved-reference comparison for synthetic lane
  --headful             show KOReader instead of using SDL's dummy driver
  --fail-fast           stop after the first failing inner run
  -h, --help            show this help
EOF
}

source_dir="${GRIMMORY_REAL_EPUB_DIR:-}"
metadata_cache="${GRIMMORY_METADATA_CACHE:-}"
private_source_map="${GRIMMORY_PRIVATE_EPUB_MAP:-}"
output_arg=""
orientation="both"
capture_only=0
headful=0
fail_fast=0
scenarios=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-dir) [[ $# -ge 2 ]] || die "--source-dir requires a value"; source_dir="$2"; shift 2 ;;
        --metadata-cache) [[ $# -ge 2 ]] || die "--metadata-cache requires a value"; metadata_cache="$2"; shift 2 ;;
        --source-map) [[ $# -ge 2 ]] || die "--source-map requires a value"; private_source_map="$2"; shift 2 ;;
        --output) [[ $# -ge 2 ]] || die "--output requires a value"; output_arg="$2"; shift 2 ;;
        --scenario) [[ $# -ge 2 ]] || die "--scenario requires a value"; scenarios+=("$2"); shift 2 ;;
        --orientation) [[ $# -ge 2 ]] || die "--orientation requires a value"; orientation="$2"; shift 2 ;;
        --capture-only) capture_only=1; shift ;;
        --headful) headful=1; shift ;;
        --fail-fast) fail_fast=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
done

[[ -n "$source_dir" ]] || die "--source-dir or GRIMMORY_REAL_EPUB_DIR is required"
[[ -d "$source_dir" ]] || die "source directory does not exist: $source_dir"
[[ -n "$output_arg" ]] || die "--output is required"
case "$orientation" in portrait|landscape|both) ;; *) die "invalid orientation: $orientation" ;; esac

PYTHON_BIN="${GRIMMORY_VISUAL_PYTHON:-python3}"
command -v "$PYTHON_BIN" >/dev/null 2>&1 || die "missing Python executable: $PYTHON_BIN"
for path in "$VISUAL_RUNNER" "$COMPANION_TOOL" "$PREPARE_TOOL"; do
    [[ -r "$path" ]] || die "missing required tool: $path"
done

mkdir -p "$output_arg"
OUTPUT_DIR="$(cd "$output_arg" && pwd -P)"
if find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    die "output directory must be new or empty: $OUTPUT_DIR"
fi

echo "Preparing ignored private EPUB metadata and bounded covers..."
prepare_args=(--source-dir "$source_dir" --output "$PRIVATE_BUILD")
if [[ -n "$metadata_cache" ]]; then prepare_args+=(--metadata-cache "$metadata_cache"); fi
if [[ -n "$private_source_map" ]]; then prepare_args+=(--private-source-map "$private_source_map"); fi
"$PYTHON_BIN" "$PREPARE_TOOL" "${prepare_args[@]}"
PRIVATE_LIBRARY="$PRIVATE_BUILD/visual-library.json"
PRIVATE_COVERS="$PRIVATE_BUILD/cover-map.json"

scenario_args=()
tool_scenario_args=()
for scenario in "${scenarios[@]}"; do
    scenario_args+=(--scenario "$scenario")
    tool_scenario_args+=(--scenario "$scenario")
done

PLAN="$OUTPUT_DIR/companion-plan.tsv"
"$PYTHON_BIN" "$COMPANION_TOOL" plan \
    --library "$PRIVATE_LIBRARY" \
    "${tool_scenario_args[@]}" >"$PLAN"

synthetic_args=(
    --orientation "$orientation"
    --output "$OUTPUT_DIR/synthetic"
    "${scenario_args[@]}"
)
[[ "$capture_only" -eq 1 ]] && synthetic_args+=(--capture-only)
[[ "$headful" -eq 1 ]] && synthetic_args+=(--headful)
[[ "$fail_fast" -eq 1 ]] && synthetic_args+=(--fail-fast)

echo "Running deterministic synthetic side of each pair..."
bash "$VISUAL_RUNNER" "${synthetic_args[@]}"

failures=0
while IFS=$'\t' read -r scenario book_id file_id validation_class asset_sha book_title epub_path; do
    [[ -n "$scenario" ]] || continue
    echo "Running private companion: $scenario with fixture book $book_id"
    real_output="$OUTPUT_DIR/real/$book_id/$scenario"
    inner_args=(
        --scenario "$scenario"
        --orientation "$orientation"
        --output "$real_output"
        --capture-only
    )
    [[ "$headful" -eq 1 ]] && inner_args+=(--headful)
    if ! GRIMMORY_VISUAL_LIBRARY_JSON="$PRIVATE_LIBRARY" \
        GRIMMORY_VISUAL_COVERS_JSON="$PRIVATE_COVERS" \
        GRIMMORY_VISUAL_EPUB="$epub_path" \
        GRIMMORY_VISUAL_BOOK_ID="$book_id" \
        GRIMMORY_VISUAL_FILE_ID="$file_id" \
        GRIMMORY_VISUAL_BOOK_TITLE="$book_title" \
        GRIMMORY_VISUAL_EPUB_SHA256="$asset_sha" \
        GRIMMORY_VISUAL_FIXTURE_MODE=direct-private-epub \
        GRIMMORY_VISUAL_VALIDATION_CLASS="$validation_class" \
        GRIMMORY_VISUAL_REQUIRE_REAL_EPUB=1 \
        bash "$VISUAL_RUNNER" "${inner_args[@]}"; then
        failures=$((failures + 1))
        if [[ "$fail_fast" -eq 1 ]]; then break; fi
    fi
done <"$PLAN"

report_status=0
"$PYTHON_BIN" "$COMPANION_TOOL" report \
    --library "$PRIVATE_LIBRARY" \
    --run-root "$OUTPUT_DIR" \
    --output "$OUTPUT_DIR/report" \
    --orientation "$orientation" \
    "${tool_scenario_args[@]}" || report_status=$?

if [[ "$failures" -ne 0 || "$report_status" -ne 0 ]]; then
    echo "Real companion inner-run failures: $failures" >&2
    exit 1
fi
