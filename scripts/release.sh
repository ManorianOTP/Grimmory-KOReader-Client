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
# upload the build/*.tar.gz files to the matching GitHub release.
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
mkdir -p build release
ENTRIES=()
for dir in "${PLUGINS[@]}"; do
    tgz="build/${dir}-${VERSION}.tar.gz"
    tar czf "$tgz" "$dir"
    sha="$(sha256sum "$tgz" | awk '{print $1}')"
    size="$(wc -c < "$tgz")"
    ENTRIES+=("    { \"dir\": \"${dir}\", \"url\": \"${BASE_URL}/${dir}-${VERSION}.tar.gz\", \"sha256\": \"${sha}\", \"size\": ${size} }")
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

cat <<EOF

Next steps:
  1. Review and commit the version bump + release/manifest.json on main:
       git add grimmory.koplugin/_meta.lua grimmory_sync.koplugin/_meta.lua release/manifest.json
       git commit -m "Release v${VERSION}"
       git push origin main
  2. Publish the artifacts so the manifest URLs resolve:
       gh release create v${VERSION} build/*.tar.gz --title "v${VERSION}" --notes-file CHANGELOG.md
EOF
