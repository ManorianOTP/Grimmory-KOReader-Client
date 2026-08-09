#!/usr/bin/env bash
# Bootstrap-and-run script for Grimmory KOReader Client off-device tests.
# Run this before SCP'ing changes to the Kindle.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

fail=0

check() {
    local name="$1"
    local cmd="$2"
    if ! command -v "$cmd" &>/dev/null; then
        echo "MISSING: $name ($cmd not found)" >&2
        fail=1
    fi
}

check_lua_mod() {
    local mod="$1"
    if ! luajit -e "require('$mod')" &>/dev/null 2>&1; then
        echo "MISSING lua module: $mod" >&2
        fail=1
    fi
}

check "luajit"       luajit
check "luarocks"     luarocks
check "python3"      python3

if command -v luajit &>/dev/null; then
    check_lua_mod "busted"
    check_lua_mod "dkjson"
    check_lua_mod "socket"
    check_lua_mod "lfs"
fi

if [ "$fail" -ne 0 ]; then
    echo ""
    echo "Install missing dependencies:"
    echo "  sudo apt-get install -y luajit luarocks python3"
    echo "  luarocks install busted"
    echo "  luarocks install dkjson"
    echo "  luarocks install luasocket"
    echo "  luarocks install luafilesystem"
    exit 1
fi

cd "$REPO_ROOT"
exec luajit tests/run.lua "$@"
