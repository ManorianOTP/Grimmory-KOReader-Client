#!/usr/bin/env bash
#
# Cut a release of the Grimmory plugin pair.
#
#   1. Runs the test suite (the release gate).
#   2. Sets the given version in both plugins' _meta.lua.
#   3. Builds a .tar.gz artifact per plugin (each extracts to its own dir).
#   4. Writes manifest.json beside the archives with URLs, sha256, and sizes.
#
# The in-app updater reads manifest.json from GitHub's latest-release download
# URL. Upload the generated manifest and both explicitly named archives to the
# matching release. No active manifest is committed before those files exist.
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
mkdir -p "$BUILD_DIR"
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

MANIFEST="${BUILD_DIR}/manifest.json"
echo "==> Writing ${MANIFEST}"
{
    echo "{"
    echo "  \"version\": \"${VERSION}\","
    echo "  \"plugins\": ["
    echo "${ENTRIES[0]},"
    echo "${ENTRIES[1]}"
    echo "  ]"
    echo "}"
} > "$MANIFEST"
cat "$MANIFEST"

echo "==> Validating manifest and exact artifact set"
python3 scripts/validate_release.py --manifest "$MANIFEST" --build-dir "$BUILD_DIR"

cat <<EOF

Next steps:
  1. Review and commit the version bump through the normal pull-request flow:
       git add grimmory.koplugin/_meta.lua grimmory_sync.koplugin/_meta.lua
       git commit -m "Release v${VERSION}"
  2. After that commit is on the release branch, publish all three generated files:
       gh release create v${VERSION} "${ARTIFACTS[0]}" "${ARTIFACTS[1]}" "${MANIFEST}" --title "v${VERSION}" --notes-file CHANGELOG.md
EOF
