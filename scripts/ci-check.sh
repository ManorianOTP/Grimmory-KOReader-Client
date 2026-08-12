#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

scripts/test.sh
python3 -B scripts/check-test-realism.py
python3 -B -m unittest discover -s tests/visual -p 'test_*.py'
python3 -B -m unittest discover -s tests/emulator -p 'test_*.py'
node --test \
    tests/compatibility/browser_helpers.test.js \
    tests/compatibility/metadata_exactness.test.js \
    tests/compatibility/verify-web-reader-checkpoints.test.js

BYTECODE_DIR="$(mktemp -d)"
trap 'rm -rf "$BYTECODE_DIR"' EXIT
while IFS= read -r -d '' file; do
    luajit -b "$file" "$BYTECODE_DIR/check.luac"
done < <(find grimmory.koplugin grimmory_sync.koplugin tests -type f -name '*.lua' -print0)

if grep -RniE --include='*.lua' 'booklore' grimmory.koplugin grimmory_sync.koplugin; then
    echo "Stale BookLore branding found in packaged plugin source" >&2
    exit 1
fi

echo "Lua compilation and stale-brand checks passed"
