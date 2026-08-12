#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PIN_FILE="$REPO_ROOT/tests/emulator/koreader-emulator.env"
SETUP_SCRIPT="$REPO_ROOT/scripts/setup-koreader-emulator.sh"

die() {
    echo "run-koreader-visual-tests: $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: scripts/run-koreader-visual-tests.sh [options]

Runs Grimmory's visual scenarios in the pinned KOReader emulator. By default,
all scenarios run in portrait and landscape, each with completely fresh data.

Options:
  --scenario NAME       run one scenario (repeatable)
  --orientation VALUE   portrait, landscape, or both (default: both)
  --output DIR          write results to a new/empty directory
  --references DIR      approved PNG root (default: tests/visual/references)
  --capture-only        skip approved-reference comparison
  --headful             use the current desktop instead of SDL's dummy driver
  --fail-fast           stop after the first failed scenario
  --list                list scenario names and exit
  -h, --help            show this help

Environment:
  GRIMMORY_KOREADER_CACHE  cache outside the repository
  GRIMMORY_VISUAL_PYTHON   Python executable containing Pillow (default: python3)
  GRIMMORY_VISUAL_TIMEOUT  seconds allowed per scenario (default: 30)
  GRIMMORY_VISUAL_FAKETIME fixed time understood by libfaketime; optional
  GRIMMORY_VISUAL_COVERS_JSON  optional book-ID to local-cover JSON map
  GRIMMORY_VISUAL_EPUB         optional local EPUB used by reader scenarios
  GRIMMORY_VISUAL_LIBRARY_JSON optional normalized private library snapshot
EOF
}

(( BASH_VERSINFO[0] >= 4 )) || die "Bash 4 or newer is required"

# The Lua data table is the single scenario catalogue used by both the driver
# and this shell runner. Keep declarations in the documented
# `scenarios.name = ...` form; new scenarios then appear in --list and the full
# matrix automatically instead of requiring a second shell list to be updated.
SCENARIO_CATALOG="$REPO_ROOT/tests/emulator/visual_driver.koplugin/visual_scenarios.lua"
command -v sed >/dev/null 2>&1 || die "missing dependency: sed"
[[ -r "$SCENARIO_CATALOG" ]] || die "missing scenario catalogue: $SCENARIO_CATALOG"
mapfile -t ALL_SCENARIOS < <(
    sed -nE 's/^scenarios\.([a-z0-9_]+)[[:space:]]*=.*$/\1/p' \
        "$SCENARIO_CATALOG"
)
[[ ${#ALL_SCENARIOS[@]} -gt 0 ]] \
    || die "no scenarios found in Lua catalogue: $SCENARIO_CATALOG"
declare -A SEEN_SCENARIOS=()
for catalogue_name in "${ALL_SCENARIOS[@]}"; do
    [[ -z "${SEEN_SCENARIOS[$catalogue_name]:-}" ]] \
        || die "duplicate scenario in Lua catalogue: $catalogue_name"
    SEEN_SCENARIOS[$catalogue_name]=1
done

scenario_args=()
orientation="both"
output_arg=""
references_arg="$REPO_ROOT/tests/visual/references"
capture_only=0
headful=0
fail_fast=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scenario)
            [[ $# -ge 2 ]] || die "--scenario requires a name"
            scenario_args+=("$2")
            shift 2
            ;;
        --orientation)
            [[ $# -ge 2 ]] || die "--orientation requires a value"
            orientation="$2"
            shift 2
            ;;
        --output)
            [[ $# -ge 2 ]] || die "--output requires a directory"
            output_arg="$2"
            shift 2
            ;;
        --references)
            [[ $# -ge 2 ]] || die "--references requires a directory"
            references_arg="$2"
            shift 2
            ;;
        --capture-only) capture_only=1; shift ;;
        --headful) headful=1; shift ;;
        --fail-fast) fail_fast=1; shift ;;
        --list) printf '%s\n' "${ALL_SCENARIOS[@]}"; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
done

case "$orientation" in
    portrait|landscape|both) ;;
    *) die "invalid orientation: $orientation" ;;
esac

[[ -r "$PIN_FILE" ]] || die "missing pin file: $PIN_FILE"
# shellcheck source=../tests/emulator/koreader-emulator.env
source "$PIN_FILE"

for command_name in chmod cp curl find grep kill mkdir mktemp tail timeout; do
    command -v "$command_name" >/dev/null 2>&1 \
        || die "missing dependency: $command_name"
done

is_known_scenario() {
    local wanted="$1"
    local candidate
    for candidate in "${ALL_SCENARIOS[@]}"; do
        [[ "$candidate" == "$wanted" ]] && return 0
    done
    return 1
}

if [[ ${#scenario_args[@]} -eq 0 ]]; then
    scenarios=("${ALL_SCENARIOS[@]}")
else
    scenarios=("${scenario_args[@]}")
fi
for scenario_name in "${scenarios[@]}"; do
    is_known_scenario "$scenario_name" || die "unknown scenario: $scenario_name"
done

if [[ "$orientation" == "both" ]]; then
    orientations=(portrait landscape)
else
    orientations=("$orientation")
fi

PYTHON_BIN="${GRIMMORY_VISUAL_PYTHON:-python3}"
command -v "$PYTHON_BIN" >/dev/null 2>&1 || die "missing Python executable: $PYTHON_BIN"
"$PYTHON_BIN" -c 'from PIL import Image' >/dev/null 2>&1 \
    || die "missing Python dependency: Pillow (install python3-pil or pip install Pillow)"

VISUAL_ASSET_DIR="$REPO_ROOT/build/grimmory-fixture/synthetic-covers"
"$PYTHON_BIN" "$REPO_ROOT/tests/emulator/export_synthetic_covers.py" \
    --output "$VISUAL_ASSET_DIR" >/dev/null
visual_covers_json="${GRIMMORY_VISUAL_COVERS_JSON:-$VISUAL_ASSET_DIR/covers.json}"
visual_epub="${GRIMMORY_VISUAL_EPUB:-$VISUAL_ASSET_DIR/synthetic-reader.epub}"
[[ -r "$visual_covers_json" ]] || die "missing visual cover map: $visual_covers_json"
[[ -r "$visual_epub" ]] || die "missing visual reader EPUB: $visual_epub"

RUNTIME_DIR="$(bash "$SETUP_SCRIPT" --print-runtime)"
KOREADER_DIR="$RUNTIME_DIR/lib/koreader"
[[ -x "$KOREADER_DIR/luajit" && -r "$KOREADER_DIR/reader.lua" ]] \
    || die "setup returned an invalid runtime: $RUNTIME_DIR"

if [[ -n "${GRIMMORY_KOREADER_CACHE:-}" ]]; then
    CACHE_ROOT="$GRIMMORY_KOREADER_CACHE"
elif [[ -n "${XDG_CACHE_HOME:-}" ]]; then
    CACHE_ROOT="$XDG_CACHE_HOME/grimmory-koreader"
elif [[ -n "${HOME:-}" ]]; then
    CACHE_ROOT="$HOME/.cache/grimmory-koreader"
else
    die "set GRIMMORY_KOREADER_CACHE; no user cache directory could be found"
fi
mkdir -p "$CACHE_ROOT/runs"
CACHE_ROOT="$(cd "$CACHE_ROOT" && pwd -P)"

RUN_ROOT="$(mktemp -d "$CACHE_ROOT/runs/run.XXXXXX")"
if [[ -n "$output_arg" ]]; then
    mkdir -p "$output_arg"
    OUTPUT_DIR="$(cd "$output_arg" && pwd -P)"
    if find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
        die "output directory must be new or empty: $OUTPUT_DIR"
    fi
else
    OUTPUT_DIR="$RUN_ROOT/results"
    mkdir -p "$OUTPUT_DIR"
fi
CAPTURE_DIR="$OUTPUT_DIR/captures"
REPORT_DIR="$OUTPUT_DIR/report"
mkdir -p "$CAPTURE_DIR"

# A real HTTP boundary is part of the download/open journey. Start the
# deterministic Grimmory fixture once per isolated run on an OS-selected port.
# Private companion runs point it at the ignored prepared library, whose
# sourcePath fields make the server stream the exact supplied EPUB bytes.
FIXTURE_READY="$RUN_ROOT/fixture-ready.json"
FIXTURE_LOG="$RUN_ROOT/fixture-server.log"
FIXTURE_INPUT="${GRIMMORY_VISUAL_LIBRARY_JSON:-$REPO_ROOT/tests/emulator/grimmory_library_fixture.json}"
"$PYTHON_BIN" "$REPO_ROOT/tests/emulator/grimmory_fixture_server.py" \
    --fixture "$FIXTURE_INPUT" --host 127.0.0.1 --port 0 \
    --ready-file "$FIXTURE_READY" --quiet >"$FIXTURE_LOG" 2>&1 &
FIXTURE_PID=$!
stop_fixture() {
    if kill -0 "$FIXTURE_PID" 2>/dev/null; then
        kill "$FIXTURE_PID" 2>/dev/null || true
        wait "$FIXTURE_PID" 2>/dev/null || true
    fi
}
trap stop_fixture EXIT
fixture_server_url=""
for _ in {1..100}; do
    if [[ -s "$FIXTURE_READY" ]]; then
        fixture_server_url="$("$PYTHON_BIN" -c \
            'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["url"])' \
            "$FIXTURE_READY")"
        if curl -fsS "$fixture_server_url/api/v1/healthcheck" >/dev/null; then
            break
        fi
    fi
    if ! kill -0 "$FIXTURE_PID" 2>/dev/null; then
        tail -n 60 "$FIXTURE_LOG" >&2 || true
        die "fixture server exited before readiness"
    fi
    sleep 0.05
done
[[ -n "$fixture_server_url" ]] \
    && curl -fsS "$fixture_server_url/api/v1/healthcheck" >/dev/null \
    || die "fixture server did not become ready"

if [[ "$references_arg" != /* ]]; then
    references_arg="$REPO_ROOT/$references_arg"
fi
REFERENCES_DIR="$references_arg"

for plugin_source in \
    "$REPO_ROOT/grimmory.koplugin" \
    "$REPO_ROOT/grimmory_sync.koplugin" \
    "$REPO_ROOT/tests/emulator/visual_driver.koplugin"; do
    [[ -d "$plugin_source" ]] || die "missing plugin directory: $plugin_source"
done
[[ -r "$REPO_ROOT/tests/emulator/settings.reader.lua" ]] \
    || die "missing emulator settings fixture"

SOURCE_ROOTS=(
    "$REPO_ROOT/grimmory.koplugin"
    "$REPO_ROOT/grimmory_sync.koplugin"
    "$REPO_ROOT/tests/emulator/visual_driver.koplugin"
)
fingerprint_args=()
for source_root in "${SOURCE_ROOTS[@]}"; do
    fingerprint_args+=(--source "$source_root")
done
SOURCE_FINGERPRINT="$(
    "$PYTHON_BIN" "$REPO_ROOT/scripts/visual_regression.py" fingerprint \
        "${fingerprint_args[@]}"
)" || die "could not fingerprint visual-test sources"
[[ "$SOURCE_FINGERPRINT" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || die "visual source fingerprint has an invalid format: $SOURCE_FINGERPRINT"

timeout_seconds="${GRIMMORY_VISUAL_TIMEOUT:-30}"
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] \
    || die "GRIMMORY_VISUAL_TIMEOUT must be a positive whole number"

fake_time="${GRIMMORY_VISUAL_FAKETIME:-}"
if [[ -n "$fake_time" ]] && ! command -v faketime >/dev/null 2>&1; then
    die "GRIMMORY_VISUAL_FAKETIME requires the faketime command"
fi

failures=0
passes=0

run_scenario() {
    local scenario_name="$1"
    local orientation_name="$2"
    local screen_width screen_height
    if [[ "$orientation_name" == "portrait" ]]; then
        screen_width="$KOREADER_SCREEN_WIDTH"
        screen_height="$KOREADER_SCREEN_HEIGHT"
    else
        screen_width="$KOREADER_SCREEN_HEIGHT"
        screen_height="$KOREADER_SCREEN_WIDTH"
    fi

    local state_dir="$RUN_ROOT/state/$orientation_name/$scenario_name"
    local ko_home="$state_dir/ko-home"
    local result_dir="$CAPTURE_DIR/$orientation_name"
    local log_path="$result_dir/$scenario_name.log"
    mkdir -p "$ko_home/plugins" "$result_dir" \
        "$state_dir/xdg-cache" "$state_dir/xdg-config" \
        "$state_dir/xdg-data" "$state_dir/xdg-runtime"
    chmod 700 "$state_dir/xdg-runtime"

    cp -a -- "$REPO_ROOT/grimmory.koplugin" "$ko_home/plugins/"
    cp -a -- "$REPO_ROOT/grimmory_sync.koplugin" "$ko_home/plugins/"
    cp -a -- "$REPO_ROOT/tests/emulator/visual_driver.koplugin" "$ko_home/plugins/"
    cp -- "$REPO_ROOT/tests/emulator/settings.reader.lua" "$ko_home/settings.reader.lua"

    echo "[$orientation_name] $scenario_name"
    local status=0
    (
        cd "$KOREADER_DIR"
        unset APPIMAGE FLATPAK KO_MULTIUSER UBUNTU_APPLICATION_ISOLATION
        export KO_HOME="$ko_home"
        export XDG_CACHE_HOME="$state_dir/xdg-cache"
        export XDG_CONFIG_HOME="$state_dir/xdg-config"
        export XDG_DATA_HOME="$state_dir/xdg-data"
        export XDG_RUNTIME_DIR="$state_dir/xdg-runtime"
        export EMULATE_READER_W="$screen_width"
        export EMULATE_READER_H="$screen_height"
        export EMULATE_READER_DPI="$KOREADER_SCREEN_DPI"
        export GRIMMORY_VISUAL_SCENARIO="$scenario_name"
        export GRIMMORY_VISUAL_OUTPUT="$result_dir"
        export GRIMMORY_VISUAL_SOURCE_FINGERPRINT="$SOURCE_FINGERPRINT"
        export GRIMMORY_VISUAL_KOREADER_VERSION="$KOREADER_VERSION"
        export GRIMMORY_VISUAL_KOREADER_COMMIT="$KOREADER_COMMIT"
        export GRIMMORY_VISUAL_FIXTURE_MODE="${GRIMMORY_VISUAL_FIXTURE_MODE:-synthetic-injected}"
        export GRIMMORY_VISUAL_VALIDATION_CLASS="${GRIMMORY_VISUAL_VALIDATION_CLASS:-synthetic-ci-baseline}"
        export GRIMMORY_VISUAL_COVERS_JSON="$visual_covers_json"
        export GRIMMORY_VISUAL_EPUB="$visual_epub"
        if [[ "$scenario_name" == "reader_download_open" ]]; then
            export GRIMMORY_VISUAL_SERVER_URL="$fixture_server_url"
        else
            unset GRIMMORY_VISUAL_SERVER_URL
        fi
        export LC_ALL="$KOREADER_LOCALE"
        export LANG="$KOREADER_LOCALE"
        export LANGUAGE="en"
        export TZ="$KOREADER_TIMEZONE"
        export SOURCE_DATE_EPOCH="1773748800"
        export SDL_AUDIODRIVER="dummy"
        export SDL_RENDER_DRIVER="software"
        if [[ "$headful" -eq 0 ]]; then
            export SDL_VIDEODRIVER="dummy"
        fi

        if [[ -n "$fake_time" ]]; then
            timeout --kill-after=5s "${timeout_seconds}s" \
                faketime -f "$fake_time" ./luajit reader.lua
        else
            timeout --kill-after=5s "${timeout_seconds}s" ./luajit reader.lua
        fi
    ) >"$log_path" 2>&1 || status=$?

    local json_path="$result_dir/$scenario_name.json"
    local png_path="$result_dir/$scenario_name.png"
    if [[ $status -eq 0 && -s "$json_path" && -s "$png_path" ]]; then
        passes=$((passes + 1))
        echo "  PASS"
        return 0
    fi

    failures=$((failures + 1))
    if [[ $status -eq 124 ]]; then
        echo "  FAIL: timed out after ${timeout_seconds}s" >&2
    elif [[ $status -ne 0 ]]; then
        echo "  FAIL: KOReader exited with status $status" >&2
    else
        echo "  FAIL: visual driver did not produce both JSON and PNG" >&2
    fi
    echo "  Log: $log_path" >&2
    tail -n 80 "$log_path" >&2 || true
    return 1
}

for orientation_name in "${orientations[@]}"; do
    for scenario_name in "${scenarios[@]}"; do
        if ! run_scenario "$scenario_name" "$orientation_name"; then
            if [[ "$fail_fast" -eq 1 ]]; then
                echo "Results: $OUTPUT_DIR" >&2
                exit 1
            fi
        fi
    done
done

echo "Visual tests: $passes passed, $failures failed"
echo "Captures: $CAPTURE_DIR"
echo "Isolated runtime state: $RUN_ROOT/state"
if [[ $failures -ne 0 ]]; then
    echo "Results: $OUTPUT_DIR" >&2
    exit 1
fi

echo "Verifying capture provenance..."
"$PYTHON_BIN" "$REPO_ROOT/scripts/visual_regression.py" verify-provenance \
    --captures "$CAPTURE_DIR" \
    "${fingerprint_args[@]}" \
    --record "$OUTPUT_DIR/provenance.json" \
    || die "captures do not match the current production and visual-driver sources"

if [[ "$capture_only" -eq 1 ]]; then
    echo "Capture-only run complete. Results: $OUTPUT_DIR"
    exit 0
fi

echo "Comparing captures with approved references..."
compare_status=0
"$PYTHON_BIN" "$REPO_ROOT/scripts/visual_regression.py" compare \
    --current "$CAPTURE_DIR" \
    --references "$REFERENCES_DIR" \
    --artifacts "$REPORT_DIR" || compare_status=$?
echo "Results: $OUTPUT_DIR"
exit "$compare_status"
