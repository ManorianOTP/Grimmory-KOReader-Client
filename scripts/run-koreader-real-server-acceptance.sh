#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PIN_FILE="$REPO_ROOT/tests/emulator/koreader-emulator.env"
SETUP="$REPO_ROOT/scripts/setup-koreader-emulator.sh"

die() { echo "run-koreader-real-server-acceptance: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: scripts/run-koreader-real-server-acceptance.sh --runtime FILE [options]

Runs production Grimmory plugins in the pinned KOReader desktop emulator
against one disposable full Grimmory server.

Options:
  --runtime FILE       enriched private runtime.with-metadata.json (required)
  --checkpoint FILE    web-reader-checkpoints.json; required for reader runs
  --output DIR         new/empty private artifact directory (default: runtime runRoot)
  --metadata-only      run live metadata surfaces only
  --reader-only        run browser-to-KOReader journeys only
  --alias NAME         reader alias to run; repeatable (default: every checkpoint)
  --headful            show the SDL window instead of using the dummy driver
  --keep-state         retain isolated KO_HOME directories for diagnosis
EOF
}

runtime_path=""
checkpoint_path=""
output_arg=""
run_metadata=1
run_reader=1
headful=0
keep_state=0
aliases=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --runtime) runtime_path="${2:-}"; shift 2 ;;
        --checkpoint) checkpoint_path="${2:-}"; shift 2 ;;
        --output) output_arg="${2:-}"; shift 2 ;;
        --metadata-only) run_reader=0; shift ;;
        --reader-only) run_metadata=0; shift ;;
        --alias) aliases+=("${2:-}"); shift 2 ;;
        --headful) headful=1; shift ;;
        --keep-state) keep_state=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
done

[[ -n "$runtime_path" && -r "$runtime_path" ]] || die "--runtime must be readable"
[[ -r "$PIN_FILE" ]] || die "missing pin file"
# shellcheck source=../tests/emulator/koreader-emulator.env
source "$PIN_FILE"
for command_name in bash chmod cp find mkdir mktemp python3 timeout; do
    command -v "$command_name" >/dev/null 2>&1 || die "missing command: $command_name"
done

runtime_path="$(cd "$(dirname "$runtime_path")" && pwd -P)/$(basename "$runtime_path")"
if [[ "$run_reader" -eq 1 ]]; then
    [[ -n "$checkpoint_path" && -r "$checkpoint_path" ]] \
        || die "reader runs require --checkpoint from the browser producer"
    checkpoint_path="$(cd "$(dirname "$checkpoint_path")" && pwd -P)/$(basename "$checkpoint_path")"
fi

if [[ -z "$output_arg" ]]; then
    run_root="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["runRoot"])' "$runtime_path")"
    output_arg="$run_root/koreader-acceptance"
fi
mkdir -p "$output_arg"
OUTPUT_ROOT="$(cd "$output_arg" && pwd -P)"
if find "$OUTPUT_ROOT" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    die "output directory must be new or empty: $OUTPUT_ROOT"
fi

if [[ "$run_reader" -eq 1 && ${#aliases[@]} -eq 0 ]]; then
    mapfile -t aliases < <(python3 -c '
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
seen = set()
for item in p.get("checkpoints", []):
    if item.get("journey") == "web-to-koreader-producer" and item.get("alias") not in seen:
        seen.add(item["alias"]); print(item["alias"])
' "$checkpoint_path")
fi
if [[ "$run_reader" -eq 1 && ${#aliases[@]} -eq 0 ]]; then
    die "checkpoint contains no web-to-koreader producer entries"
fi

KOREADER_ROOT="$(bash "$SETUP" --print-runtime)"
KOREADER_DIR="$KOREADER_ROOT/lib/koreader"
[[ -x "$KOREADER_DIR/luajit" && -r "$KOREADER_DIR/reader.lua" ]] \
    || die "invalid pinned KOReader runtime"

RUN_STATE="$(mktemp -d "${TMPDIR:-/tmp}/grimmory-koreader-acceptance.XXXXXX")"
cleanup() {
    if [[ "$keep_state" -eq 0 && -d "$RUN_STATE" ]]; then
        case "$RUN_STATE" in
            "${TMPDIR:-/tmp}/grimmory-koreader-acceptance."*) rm -rf -- "$RUN_STATE" ;;
            *) echo "refusing unexpected state cleanup: $RUN_STATE" >&2 ;;
        esac
    fi
}
trap cleanup EXIT

run_one() {
    local mode="$1"
    local alias="$2"
    local session="$3"
    local phase="${4:-}"
    local prior_result="${5:-}"
    local key="$mode${phase:+-$phase}${alias:+-$alias}"
    local state="$RUN_STATE/$key"
    local ko_home="$state/ko-home"
    local artifacts="$OUTPUT_ROOT/$key"
    mkdir -p "$ko_home/plugins" "$artifacts" \
        "$state/xdg-cache" "$state/xdg-config" "$state/xdg-data" "$state/xdg-runtime"
    chmod 700 "$state/xdg-runtime"
    cp -a -- "$REPO_ROOT/grimmory.koplugin" "$ko_home/plugins/"
    cp -a -- "$REPO_ROOT/grimmory_sync.koplugin" "$ko_home/plugins/"
    cp -a -- "$REPO_ROOT/tests/emulator/acceptance_driver.koplugin" "$ko_home/plugins/"
    cp -- "$REPO_ROOT/tests/emulator/settings.reader.lua" "$ko_home/settings.reader.lua"

    echo "[KOReader/full-server] $key"
    local status=0
    (
        cd "$KOREADER_DIR"
        unset APPIMAGE FLATPAK KO_MULTIUSER UBUNTU_APPLICATION_ISOLATION
        export KO_HOME="$ko_home"
        export XDG_CACHE_HOME="$state/xdg-cache"
        export XDG_CONFIG_HOME="$state/xdg-config"
        export XDG_DATA_HOME="$state/xdg-data"
        export XDG_RUNTIME_DIR="$state/xdg-runtime"
        export EMULATE_READER_W="$KOREADER_SCREEN_WIDTH"
        export EMULATE_READER_H="$KOREADER_SCREEN_HEIGHT"
        export EMULATE_READER_DPI="$KOREADER_SCREEN_DPI"
        export GRIMMORY_ACCEPTANCE_MODE="$mode"
        export GRIMMORY_ACCEPTANCE_ALIAS="$alias"
        export GRIMMORY_ACCEPTANCE_PHASE="$phase"
        export GRIMMORY_ACCEPTANCE_PRIOR_RESULT="$prior_result"
        export GRIMMORY_ACCEPTANCE_RUNTIME="$runtime_path"
        export GRIMMORY_ACCEPTANCE_CHECKPOINT="$checkpoint_path"
        export GRIMMORY_ACCEPTANCE_OUTPUT="$artifacts"
        export GRIMMORY_ACCEPTANCE_SESSION="$session"
        export GRIMMORY_ACCEPTANCE_TIMEOUT="240"
        export GRIMMORY_ACCEPTANCE_KOREADER_VERSION="$KOREADER_VERSION"
        export GRIMMORY_ACCEPTANCE_KOREADER_COMMIT="$KOREADER_COMMIT"
        export LC_ALL="$KOREADER_LOCALE"
        export LANG="$KOREADER_LOCALE"
        export LANGUAGE="en"
        export TZ="$KOREADER_TIMEZONE"
        export SDL_AUDIODRIVER="dummy"
        export SDL_RENDER_DRIVER="software"
        if [[ "$headful" -eq 0 ]]; then export SDL_VIDEODRIVER="dummy"; fi
        timeout --kill-after=10s 250s ./luajit reader.lua
    ) >"$artifacts/koreader.log" 2>&1 || status=$?
    if [[ "$status" -ne 0 ]]; then
        echo "  FAIL ($status): $artifacts/koreader.log" >&2
        tail -n 100 "$artifacts/koreader.log" >&2 || true
        return "$status"
    fi
    echo "  PASS"
}

failures=0
if [[ "$run_metadata" -eq 1 ]]; then
    if run_one metadata "" 0 "" ""; then
        python3 "$REPO_ROOT/scripts/verify-koreader-metadata-artifacts.py" \
            --runtime "$runtime_path" \
            --result "$OUTPUT_ROOT/metadata/metadata.json" \
            --output "$OUTPUT_ROOT/metadata/cover-verification.json" \
            || failures=$((failures + 1))
    else
        failures=$((failures + 1))
    fi
fi
if [[ "$run_reader" -eq 1 ]]; then
    session_baseline="$OUTPUT_ROOT/reading-session-baseline.json"
    baseline_alias_args=()
    for alias in "${aliases[@]}"; do
        baseline_alias_args+=(--alias "$alias")
    done
    python3 "$REPO_ROOT/scripts/snapshot-koreader-session-baseline.py" \
        --runtime "$runtime_path" \
        --output "$session_baseline" \
        "${baseline_alias_args[@]}"

    first_real=""
    for alias in "${aliases[@]}"; do
        if [[ "$alias" == real-* ]]; then first_real="$alias"; break; fi
    done
    for alias in "${aliases[@]}"; do
        session=0
        if [[ "$alias" == "synthetic" || "$alias" == "$first_real" ]]; then session=1; fi
        jump_result="$OUTPUT_ROOT/reader-jump-$alias/$alias.json"
        if run_one reader "$alias" "$session" jump ""; then
            run_one reader "$alias" 0 sync-here "$jump_result" \
                || failures=$((failures + 1))
        else
            failures=$((failures + 1))
        fi
    done
    if [[ "$failures" -eq 0 ]]; then
        verify_alias_args=()
        for alias in "${aliases[@]}"; do
            verify_alias_args+=(--alias "$alias")
        done
        python3 "$REPO_ROOT/scripts/verify-koreader-reader-artifacts.py" \
            --runtime "$runtime_path" \
            --checkpoint "$checkpoint_path" \
            --session-baseline "$session_baseline" \
            --input "$OUTPUT_ROOT" \
            --output "$OUTPUT_ROOT/reader-server-verification.json" \
            "${verify_alias_args[@]}" \
            || failures=$((failures + 1))
    fi
fi

python3 "$REPO_ROOT/scripts/koreader_acceptance_report.py" \
    --input "$OUTPUT_ROOT" --output "$OUTPUT_ROOT/report"
echo "KOReader acceptance artifacts: $OUTPUT_ROOT"
[[ "$failures" -eq 0 ]] || die "$failures KOReader acceptance process(es) failed"
