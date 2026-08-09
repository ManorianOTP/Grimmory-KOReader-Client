#!/usr/bin/env bash
#
# Cut a release of the Grimmory plugin pair.
#
#   1. Runs the test suite (the release gate).
#   2. Sets the given version in both plugins' _meta.lua.
#   3. Builds a .tar.gz artifact per plugin (each extracts to its own dir).
#   4. Writes release/manifest.json with versions, URLs, sha256, and sizes.
#
# The in-app updater reads release/manifest.json from the main branch via
# raw.githubusercontent.com, so commit the version bump + manifest to main, and
# upload the two explicitly named artifacts to the matching GitHub release.
#
# Usage:
#   scripts/release.sh <version>        # e.g. scripts/release.sh 1.1.0
#
set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "Usage: scripts/release.sh <version>   (e.g. 1.1.0)" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REPO="ManorianOTP/Grimmory-KOReader-Client"
BASE_URL="https://github.com/${REPO}/releases/download/v${VERSION}"

# Swap/uninstall order is sync-first elsewhere; for packaging the order is
# irrelevant, but keep it stable for a reproducible manifest.
PLUGINS=(grimmory_sync.koplugin grimmory.koplugin)

echo "==> Running tests (release gate)"
scripts/test.sh

echo "==> Setting version ${VERSION} in _meta.lua"
for dir in "${PLUGINS[@]}"; do
    sed -i -E "s/(version[[:space:]]*=[[:space:]]*\")[^\"]*(\")/\1${VERSION}\2/" "$dir/_meta.lua"
done

echo "==> Building artifacts into build/"
BUILD_DIR="build/release-${VERSION}"
mkdir -p "$BUILD_DIR" release
ENTRIES=()
ARTIFACTS=()
for dir in "${PLUGINS[@]}"; do
    tgz="${BUILD_DIR}/${dir}-${VERSION}.tar.gz"
    tar czf "$tgz" "$dir"
    sha="$(sha256sum "$tgz" | awk '{print $1}')"
    size="$(wc -c < "$tgz")"
    ENTRIES+=("    { \"dir\": \"${dir}\", \"url\": \"${BASE_URL}/${dir}-${VERSION}.tar.gz\", \"sha256\": \"${sha}\", \"size\": ${size} }")
    ARTIFACTS+=("$tgz")
    echo "    ${tgz}  (${size} bytes, sha256 ${sha:0:12}…)"
done

echo "==> Writing release/manifest.json"
{
    echo "{"
    echo "  \"version\": \"${VERSION}\","
    echo "  \"plugins\": ["
    echo "${ENTRIES[0]},"
    echo "${ENTRIES[1]}"
    echo "  ]"
    echo "}"
} > release/manifest.json
cat release/manifest.json

echo "==> Validating manifest and exact artifact set"
python3 scripts/validate_release.py --manifest release/manifest.json --build-dir "$BUILD_DIR"

cat <<EOF

Next steps:
  1. Review and commit the version bump + release/manifest.json on main:
       git add grimmory.koplugin/_meta.lua grimmory_sync.koplugin/_meta.lua release/manifest.json
       git commit -m "Release v${VERSION}"
       git push origin main
  2. Publish the artifacts so the manifest URLs resolve:
       gh release create v${VERSION} "${ARTIFACTS[0]}" "${ARTIFACTS[1]}" --title "v${VERSION}" --notes-file CHANGELOG.md
EOF
