#!/bin/bash
# Clones the pinned Flycast commit into Core/third_party/flycast.
# The tree is gitignored. No ROMs, BIOS or games are downloaded.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN="$ROOT/Core/third_party/flycast-pin.txt"
DEST="$ROOT/Core/third_party/flycast"
# shellcheck disable=SC1090
source "$PIN"
if [[ -d "$DEST/.git" ]]; then
    cur="$(git -C "$DEST" rev-parse HEAD)"
    if [[ "$cur" == "$FLYCAST_COMMIT" ]]; then
        echo "Flycast already at $FLYCAST_COMMIT"
        exit 0
    fi
fi
rm -rf "$DEST"
git clone --filter=blob:none "$FLYCAST_URL" "$DEST"
git -C "$DEST" checkout --detach "$FLYCAST_COMMIT"
git -C "$DEST" submodule update --init --recursive --depth 1
echo "Flycast $FLYCAST_COMMIT"
