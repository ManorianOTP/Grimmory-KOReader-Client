#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PIN_FILE="$REPO_ROOT/tests/emulator/koreader-emulator.env"

die() {
    echo "setup-koreader-emulator: $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: scripts/setup-koreader-emulator.sh [--check | --print-runtime]

Downloads and verifies the exact KOReader desktop runtime pinned in
tests/emulator/koreader-emulator.env. The cache is always outside the Git
worktree. Set GRIMMORY_KOREADER_CACHE to choose its location.

  --check          verify dependencies and any installed runtime
  --print-runtime  set up quietly and print the runtime directory
EOF
}

(( BASH_VERSINFO[0] >= 4 )) || die "Bash 4 or newer is required"

mode="setup"
case "${1:-}" in
    "") ;;
    --check) mode="check" ;;
    --print-runtime) mode="print" ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
esac
[[ $# -le 1 ]] || die "only one argument is accepted"

[[ -r "$PIN_FILE" ]] || die "missing pin file: $PIN_FILE"
# shellcheck source=../tests/emulator/koreader-emulator.env
source "$PIN_FILE"

for command_name in uname mkdir mktemp mv rm tar sha256sum tr; do
    command -v "$command_name" >/dev/null 2>&1 \
        || die "missing dependency: $command_name"
done

case "$(uname -s)" in
    Linux) ;;
    *) die "the pinned KOReader runtime requires Linux (WSL is supported)" ;;
esac
case "$(uname -m)" in
    x86_64|amd64) ;;
    *) die "the pinned KOReader runtime requires an x86_64 host" ;;
esac

if [[ -n "${GRIMMORY_KOREADER_CACHE:-}" ]]; then
    CACHE_ROOT="$GRIMMORY_KOREADER_CACHE"
elif [[ -n "${XDG_CACHE_HOME:-}" ]]; then
    CACHE_ROOT="$XDG_CACHE_HOME/grimmory-koreader"
elif [[ -n "${HOME:-}" ]]; then
    CACHE_ROOT="$HOME/.cache/grimmory-koreader"
else
    die "set GRIMMORY_KOREADER_CACHE; no user cache directory could be found"
fi

[[ -n "$CACHE_ROOT" && "$CACHE_ROOT" != "/" ]] || die "unsafe cache directory: $CACHE_ROOT"
mkdir -p "$CACHE_ROOT"
CACHE_ROOT="$(cd "$CACHE_ROOT" && pwd -P)"
case "$CACHE_ROOT/" in
    "$REPO_ROOT/"*) die "cache must be outside the tracked source: $CACHE_ROOT" ;;
esac

DOWNLOAD_DIR="$CACHE_ROOT/downloads"
RUNTIME_KEY="${KOREADER_VERSION}-${KOREADER_ARCHIVE_SHA256:0:12}"
RUNTIME_PARENT="$CACHE_ROOT/runtimes/$RUNTIME_KEY"
RUNTIME_DIR="$RUNTIME_PARENT/root"
MARKER_FILE="$RUNTIME_DIR/.grimmory-emulator-pin"
ARCHIVE_PATH="$DOWNLOAD_DIR/$KOREADER_ARCHIVE"
EXPECTED_MARKER="$KOREADER_VERSION $KOREADER_COMMIT $KOREADER_ARCHIVE_SHA256"

verify_runtime() {
    [[ -x "$RUNTIME_DIR/lib/koreader/luajit" ]] || return 1
    [[ -r "$RUNTIME_DIR/lib/koreader/reader.lua" ]] || return 1
    [[ -r "$MARKER_FILE" ]] || return 1
    [[ "$(tr -d '\r\n' < "$MARKER_FILE")" == "$EXPECTED_MARKER" ]]
}

if verify_runtime; then
    if [[ "$mode" == "print" ]]; then
        printf '%s\n' "$RUNTIME_DIR"
    elif [[ "$mode" == "check" ]]; then
        echo "KOReader emulator ready: $RUNTIME_DIR"
    else
        echo "KOReader $KOREADER_VERSION is already installed and verified."
        echo "Runtime: $RUNTIME_DIR"
    fi
    exit 0
fi

if [[ "$mode" == "check" ]]; then
    die "the verified runtime is not installed; run scripts/setup-koreader-emulator.sh"
fi

mkdir -p "$DOWNLOAD_DIR" "$CACHE_ROOT/runtimes"

verify_archive() {
    [[ -f "$1" ]] || return 1
    printf '%s  %s\n' "$KOREADER_ARCHIVE_SHA256" "$1" | sha256sum --check --status
}

download_tmp=""
extract_tmp=""
cleanup() {
    if [[ -n "$download_tmp" && -f "$download_tmp" ]]; then
        rm -f -- "$download_tmp"
    fi
    if [[ -n "$extract_tmp" && -d "$extract_tmp" ]]; then
        case "$extract_tmp/" in
            "$CACHE_ROOT/"*) rm -rf -- "$extract_tmp" ;;
            *) echo "Refusing to clean unexpected path: $extract_tmp" >&2 ;;
        esac
    fi
}
trap cleanup EXIT

if [[ -f "$ARCHIVE_PATH" ]] && ! verify_archive "$ARCHIVE_PATH"; then
    die "cached archive has the wrong checksum; remove it and run setup again: $ARCHIVE_PATH"
fi

if [[ ! -f "$ARCHIVE_PATH" ]]; then
    download_tmp="$(mktemp "$DOWNLOAD_DIR/.${KOREADER_ARCHIVE}.part.XXXXXX")"
    echo "Downloading KOReader $KOREADER_VERSION..." >&2
    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --retry 3 --output "$download_tmp" "$KOREADER_ARCHIVE_URL"
    elif command -v wget >/dev/null 2>&1; then
        wget --tries=3 --output-document="$download_tmp" "$KOREADER_ARCHIVE_URL"
    else
        die "missing dependency: curl or wget"
    fi
    verify_archive "$download_tmp" \
        || die "downloaded KOReader archive failed its pinned SHA-256 check"
    mv -- "$download_tmp" "$ARCHIVE_PATH"
    download_tmp=""
fi

if [[ -e "$RUNTIME_PARENT" ]]; then
    die "incomplete runtime directory exists; remove it and run setup again: $RUNTIME_PARENT"
fi

extract_tmp="$(mktemp -d "$CACHE_ROOT/runtimes/.extract-${RUNTIME_KEY}.XXXXXX")"
echo "Extracting verified KOReader runtime..." >&2
tar -xJf "$ARCHIVE_PATH" -C "$extract_tmp"
[[ -x "$extract_tmp/lib/koreader/luajit" && -r "$extract_tmp/lib/koreader/reader.lua" ]] \
    || die "official archive did not contain the expected koreader runtime"
printf '%s\n' "$EXPECTED_MARKER" > "$extract_tmp/.grimmory-emulator-pin"
mkdir -p "$RUNTIME_PARENT"
mv -- "$extract_tmp" "$RUNTIME_DIR"
extract_tmp=""

verify_runtime || die "runtime validation failed after extraction"

if [[ "$mode" == "print" ]]; then
    printf '%s\n' "$RUNTIME_DIR"
else
    echo "KOReader $KOREADER_VERSION installed and verified."
    echo "Runtime: $RUNTIME_DIR"
fi
