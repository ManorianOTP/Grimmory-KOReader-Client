#!/usr/bin/env bash
#
# Deploy both BookLore plugins to a jailbroken Kindle over scp.
# This is the "advanced" install path; most users should use the USB-copy
# method in INSTALL.md instead.
#
# Usage:
#   scripts/deploy.sh <kindle-ip> [dest-plugins-dir]
#
# Examples:
#   scripts/deploy.sh 192.168.1.42
#   scripts/deploy.sh 100.64.0.7 /mnt/us/koreader/plugins
#
set -euo pipefail

IP="${1:-}"
DEST="${2:-/mnt/us/koreader/plugins}"

if [ -z "$IP" ]; then
    echo "Usage: scripts/deploy.sh <kindle-ip> [dest-plugins-dir]" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "Deploying both plugins to root@${IP}:${DEST} ..."
scp -r "$ROOT/booklore.koplugin"      "root@${IP}:${DEST}/"
scp -r "$ROOT/booklore_sync.koplugin" "root@${IP}:${DEST}/"
echo "Done. Restart KOReader on the device to load the plugins."
