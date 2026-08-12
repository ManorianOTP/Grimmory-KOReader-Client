#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
FIXTURE="$ROOT/tests/emulator/grimmory_library_fixture.json"
RUNTIME="$ROOT/build/grimmory-fixture"
READY="$RUNTIME/server-ready.json"
PID_FILE="$RUNTIME/server.pid"
LOG_FILE="$RUNTIME/server.log"
COMPOSE="$ROOT/tests/emulator/grimmory-real-server.compose.yml"
PYTHON_BIN="${GRIMMORY_VISUAL_PYTHON:-python3}"

die() { echo "grimmory-visual-fixture: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: scripts/grimmory-visual-fixture.sh COMMAND [arguments]

Deterministic protocol fixture (fast; used by visual tests and CI):
  prepare [SOURCE_DIR]  validate the eight real EPUBs and extract local covers
  serve                 run in foreground, using real data when prepared
  start                 start in background and wait for readiness
  check                 verify health, authentication, and all eight identities
  status                print server URL/state
  stop                  stop only this fixture-server process

Pinned real Grimmory v3.3.1 compatibility lane (local/manual, not baselines):
  real-up [SOURCE_DIR]  stage exactly eight private books, start and seed Docker
  real-status           show the Docker services
  real-down             stop the Docker services without deleting their data

SOURCE_DIR is always explicit, either as an argument or through
GRIMMORY_EPUB_SOURCE. Files are matched to neutral fixture IDs through the
ignored metadata cache, or through GRIMMORY_PRIVATE_EPUB_MAP before a cache
exists. Private EPUBs, covers, metadata, and server data stay under build/ or
at their original path and are ignored by Git.
EOF
}

source_dir() {
    if [[ $# -gt 0 && -n "$1" ]]; then printf '%s\n' "$1"
    elif [[ -n "${GRIMMORY_EPUB_SOURCE:-}" ]]; then printf '%s\n' "$GRIMMORY_EPUB_SOURCE"
    else die "pass SOURCE_DIR or set GRIMMORY_EPUB_SOURCE"
    fi
}

active_fixture() {
    if [[ -s "$RUNTIME/library.json" ]]; then printf '%s\n' "$RUNTIME/library.json"
    else printf '%s\n' "$FIXTURE"
    fi
}

ready_url() {
    "$PYTHON_BIN" -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["url"])' "$READY"
}

prepare() {
    local source
    source="$(source_dir "${1:-}")"
    local args=(--source-dir "$source" --output "$RUNTIME")
    if [[ -n "${GRIMMORY_METADATA_CACHE:-}" ]]; then
        args+=(--metadata-cache "$GRIMMORY_METADATA_CACHE")
    fi
    if [[ -n "${GRIMMORY_PRIVATE_EPUB_MAP:-}" ]]; then
        args+=(--private-source-map "$GRIMMORY_PRIVATE_EPUB_MAP")
    fi
    "$PYTHON_BIN" "$ROOT/scripts/prepare-grimmory-visual-library.py" "${args[@]}"
}

serve() {
    mkdir -p "$RUNTIME"
    exec "$PYTHON_BIN" "$ROOT/tests/emulator/grimmory_fixture_server.py" \
        --fixture "$(active_fixture)" --host 127.0.0.1 --port "${GRIMMORY_FIXTURE_PORT:-0}" \
        --ready-file "$READY"
}

start() {
    mkdir -p "$RUNTIME"
    if [[ -s "$PID_FILE" ]]; then
        local old_pid
        old_pid="$(<"$PID_FILE")"
        if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
            die "already running as PID $old_pid ($(ready_url 2>/dev/null || echo URL-pending))"
        fi
    fi
    rm -f -- "$READY" "$PID_FILE"
    nohup "$PYTHON_BIN" "$ROOT/tests/emulator/grimmory_fixture_server.py" \
        --fixture "$(active_fixture)" --host 127.0.0.1 --port "${GRIMMORY_FIXTURE_PORT:-0}" \
        --ready-file "$READY" --quiet >"$LOG_FILE" 2>&1 &
    local server_pid=$!
    printf '%s\n' "$server_pid" >"$PID_FILE"
    for _ in {1..100}; do
        if [[ -s "$READY" ]] && curl -fsS "$(ready_url)/api/v1/healthcheck" >/dev/null; then
            echo "fixture ready: $(ready_url) (PID $server_pid)"
            return 0
        fi
        if ! kill -0 "$server_pid" 2>/dev/null; then
            tail -n 60 "$LOG_FILE" >&2 || true
            die "fixture exited before readiness"
        fi
        sleep 0.1
    done
    die "fixture did not become ready; log: $LOG_FILE"
}

check() {
    [[ -s "$READY" ]] || die "not running (missing $READY)"
    local url token state
    url="$(ready_url)"
    curl -fsS "$url/api/v1/healthcheck" >/dev/null
    token="$(curl -fsS -H 'Content-Type: application/json' \
        -d '{"username":"visual","password":"grimmory-visual"}' \
        "$url/api/v1/auth/login" | "$PYTHON_BIN" -c 'import json,sys; print(json.load(sys.stdin)["accessToken"])')"
    state="$(curl -fsS -H "Authorization: Bearer $token" "$url/api/v1/books/page?page=0&size=100")"
    printf '%s' "$state" | "$PYTHON_BIN" -c '
import json, sys
payload = json.load(sys.stdin)
ids = [book["id"] for book in payload["content"]]
expected = list(range(1001, 1009))
if ids != expected:
    raise SystemExit(f"identity mismatch: expected {expected}, got {ids}")
print("fixture contract OK: 8 books, stable IDs 1001..1008")
'
    echo "fixture URL: $url"
}

status() {
    if [[ ! -s "$PID_FILE" ]]; then echo "fixture stopped"; return 1; fi
    local server_pid
    server_pid="$(<"$PID_FILE")"
    if ! [[ "$server_pid" =~ ^[0-9]+$ ]] || ! kill -0 "$server_pid" 2>/dev/null; then
        echo "fixture stopped (stale PID file)"
        return 1
    fi
    echo "fixture running: $(ready_url) (PID $server_pid)"
    curl -fsS "$(ready_url)/__fixture/state"
    echo
}

stop() {
    [[ -s "$PID_FILE" ]] || { echo "fixture already stopped"; return 0; }
    local server_pid command_line
    server_pid="$(<"$PID_FILE")"
    if [[ ! "$server_pid" =~ ^[0-9]+$ ]] || ! kill -0 "$server_pid" 2>/dev/null; then
        rm -f -- "$PID_FILE" "$READY"
        echo "fixture already stopped"
        return 0
    fi
    command_line="$(ps -p "$server_pid" -o args= 2>/dev/null || true)"
    [[ "$command_line" == *"grimmory_fixture_server.py"* ]] \
        || die "refusing to stop PID $server_pid: it is not the fixture server"
    kill "$server_pid"
    for _ in {1..50}; do
        kill -0 "$server_pid" 2>/dev/null || break
        sleep 0.1
    done
    rm -f -- "$PID_FILE" "$READY"
    echo "fixture stopped"
}

real_up() {
    command -v docker >/dev/null || die "Docker is required for real-up"
    local source real_root port
    source="$(source_dir "${1:-}")"
    real_root="$ROOT/build/grimmory-real"
    port="${GRIMMORY_REAL_PORT:-16060}"
    mkdir -p "$real_root/books" "$real_root/bookdrop" "$real_root/app-data" "$real_root/mariadb"
    local args=(--source-dir "$source" --output "$RUNTIME" --stage-books "$real_root/books")
    if [[ -n "${GRIMMORY_METADATA_CACHE:-}" ]]; then
        args+=(--metadata-cache "$GRIMMORY_METADATA_CACHE")
    fi
    if [[ -n "${GRIMMORY_PRIVATE_EPUB_MAP:-}" ]]; then
        args+=(--private-source-map "$GRIMMORY_PRIVATE_EPUB_MAP")
    fi
    "$PYTHON_BIN" "$ROOT/scripts/prepare-grimmory-visual-library.py" "${args[@]}"
    docker compose -f "$COMPOSE" up -d
    for _ in {1..180}; do
        if curl -fsS "http://127.0.0.1:$port/api/v1/healthcheck" >/dev/null 2>&1; then
            "$PYTHON_BIN" "$ROOT/scripts/seed-grimmory-real-server.py" \
                --url "http://127.0.0.1:$port" --expected-books 8
            return 0
        fi
        sleep 1
    done
    docker compose -f "$COMPOSE" logs --tail 80 grimmory >&2 || true
    die "real Grimmory did not become healthy within 180 seconds"
}

command_name="${1:-}"
shift || true
case "$command_name" in
    prepare) prepare "${1:-}" ;;
    serve) serve ;;
    start) start ;;
    check) check ;;
    status) status ;;
    stop) stop ;;
    real-up) real_up "${1:-}" ;;
    real-status) docker compose -f "$COMPOSE" ps ;;
    real-down) docker compose -f "$COMPOSE" down ;;
    -h|--help|help|"") usage ;;
    *) usage >&2; die "unknown command: $command_name" ;;
esac
