#!/bin/bash
# Clone the pinned N64 and 3DS cores. Safe to re-run. Does not download ROMs,
# BIOS, firmware or keys.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Core/third_party"
PINS="$DEST/n64-3ds-pins.txt"
mkdir -p "$DEST"
while read -r name sha url _; do
    case "$name" in ''|\#*) continue ;; esac
    dir="$DEST/$name"
    if [[ -d "$dir/.git" ]] && [[ "$(git -C "$dir" rev-parse HEAD)" == "$sha" ]]; then
        echo "have $name $sha"
        continue
    fi
    rm -rf "$dir"
    git clone --depth 1 "$url" "$dir"
    git -C "$dir" fetch --depth 1 origin "$sha"
    git -C "$dir" checkout --detach "$sha"
    echo "pinned $name $(git -C "$dir" rev-parse HEAD)"
done < "$PINS"
echo "Sources are in Core/third_party. They are gitignored; this script is the pin."
