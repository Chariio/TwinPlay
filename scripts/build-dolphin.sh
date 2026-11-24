#!/bin/bash
# Build Dolphin (GPL-2.0-or-later) for TwinPlay's GameCube core.
#   scripts/build-dolphin.sh macos    ARM64 JIT + Metal + Vulkan/MoltenVK
#   scripts/build-dolphin.sh ios      ARM64 cached interpreter, no JIT, Metal
# Does not download ROMs, BIOS, IPL or games. Does not sign and does not upload.
# Code signing is off (CODE_SIGNING_ALLOWED=NO, MACOS_CODE_SIGNING=OFF).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-macos}"
PIN_FILE="$ROOT/Core/third_party/dolphin-pin.txt"
PIN="$(awk 'NF && $1 !~ /^#/ {print $1; exit}' "$PIN_FILE")"
URL="$(awk 'NF && $1 !~ /^#/ {print $2; exit}' "$PIN_FILE")"
SRC="$ROOT/Core/third_party/dolphin"
BUILD="$ROOT/Core/third_party/dolphin-build/$TARGET"

if [[ -z "$PIN" || -z "$URL" ]]; then
  echo "dolphin-pin.txt needs a commit and a URL" >&2
  exit 1
fi
if [[ "$TARGET" != "macos" && "$TARGET" != "ios" ]]; then
  echo "usage: $0 macos|ios" >&2
  exit 1
fi

export CODE_SIGNING_ALLOWED=NO
export CODE_SIGNING_REQUIRED=NO

mkdir -p "$SRC" "$(dirname "$BUILD")"
if [[ ! -d "$SRC/.git" ]]; then
  rm -rf "$SRC"
  git clone --filter=blob:none --depth 1 "$URL" "$SRC"
fi
git -C "$SRC" remote set-url origin "$URL"
git -C "$SRC" fetch --depth 1 origin "$PIN"
git -C "$SRC" checkout --force "$PIN"
git -C "$SRC" submodule update --init --recursive --depth 1

COMMON=(
  -G Ninja
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_OSX_ARCHITECTURES=arm64
  -DMACOS_CODE_SIGNING=OFF
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
  -DENABLE_QT=OFF
  -DENABLE_TESTS=OFF
  -DENABLE_CLI_TOOL=OFF
  -DENABLE_AUTOUPDATE=OFF
  -DUSE_DISCORD_PRESENCE=OFF
  -DENABLE_ANALYTICS=OFF
  -DUSE_MGBA=OFF
  -DENABLE_LLVM=OFF
  -DUSE_RETRO_ACHIEVEMENTS=OFF
  -DENCODE_FRAMEDUMPS=OFF
  -DUSE_UPNP=OFF
  -DENABLE_SDL=OFF
  -DDISTRIBUTOR=TwinPlay
)

if [[ "$TARGET" == "macos" ]]; then
  cmake -S "$SRC" -B "$BUILD" "${COMMON[@]}" \
    -DENABLE_GENERIC=OFF \
    -DENABLE_NOGUI=ON \
    -DENABLE_VULKAN=ON \
    -DUSE_BUNDLED_MOLTENVK=ON \
    -DENABLE_CUBEB=ON
  ninja -C "$BUILD" dolphin-nogui
  python3 "$ROOT/scripts/check-dolphin-build.py" macos "$BUILD"
  python3 "$ROOT/scripts/compile-gc-host.py" "$BUILD/compile_commands.json" \
    "$ROOT/Core/gamecube/twinplay_gc_host.cpp"
else
  # JIT-less. ENABLE_GENERIC defines _M_GENERIC and does not compile JitArm64.
  # -fno-fast-math: Dolphin's cached interpreter miscompiles under fast-math.
  cmake -S "$SRC" -B "$BUILD" "${COMMON[@]}" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DENABLE_GENERIC=ON \
    -DENABLE_NOGUI=OFF \
    -DENABLE_VULKAN=OFF \
    -DUSE_BUNDLED_MOLTENVK=OFF \
    -DENABLE_CUBEB=ON \
    -DCMAKE_C_FLAGS="-fno-fast-math" \
    -DCMAKE_CXX_FLAGS="-fno-fast-math"
  ninja -C "$BUILD" core videometal
  python3 "$ROOT/scripts/check-dolphin-build.py" ios "$BUILD"
  python3 "$ROOT/scripts/compile-gc-host.py" "$BUILD/compile_commands.json" \
    "$ROOT/Core/gamecube/twinplay_gc_host.cpp" --ios
fi

echo "Dolphin $TARGET build finished: $BUILD"
