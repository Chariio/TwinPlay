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

# This pin asks for Xcode 26 / AppleClang 21 so it can use stable std::jthread.
# The GitHub macos-15 image is AppleClang 17, and macos-26 runners are cancelled
# after 15 minutes in the queue. Dolphin already adds -fexperimental-library when
# libc++ is older than 20, which is what makes jthread available here.
python3 - "$SRC/CMakeLists.txt" << 'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
t = p.read_text()
repls = {
    "set(AppleClang_min_version 21.0.0)": "set(AppleClang_min_version 17.0.0)",
    "set(libc++_min_version 180000)": "set(libc++_min_version 150000)",
    "set(Xcode_min_version 26.0)": "set(Xcode_min_version 16.0)",
}
for old, new in repls.items():
    if old not in t:
        raise SystemExit(f"version gate not found: {old}")
    t = t.replace(old, new, 1)
p.write_text(t)
print("relaxed Dolphin compiler gate for the CI image")
PY

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
  -DENABLE_CUBEB=OFF
  -DDISTRIBUTOR=TwinPlay
)

if [[ "$TARGET" == "macos" ]]; then
  cmake -S "$SRC" -B "$BUILD" "${COMMON[@]}" \
    -DENABLE_GENERIC=OFF \
    -DENABLE_NOGUI=ON \
    -DENABLE_VULKAN=ON \
    -DUSE_BUNDLED_MOLTENVK=ON
  ninja -C "$BUILD" dolphin-nogui
  python3 "$ROOT/scripts/check-dolphin-build.py" macos "$BUILD"
  python3 "$ROOT/scripts/compile-gc-host.py" "$BUILD/compile_commands.json" \
    "$ROOT/Core/gamecube/twinplay_gc_host.cpp"
else
  # The iOS SDK has no IOCFBundle.h (libusb), no AppKit/NSOpenGL (AGL), and no
  # Cocoa Quartz keyboard backend. Those stay in the macOS build.
  python3 - "$SRC" << 'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
edits = [
    (
        root / "CMakeLists.txt",
        """if(NOT ANDROID)
  dolphin_find_optional_system_library(LibUSB Externals/libusb)
  add_definitions(-D__LIBUSB__)
endif()""",
        """if(NOT ANDROID AND NOT IOS)
  dolphin_find_optional_system_library(LibUSB Externals/libusb)
  add_definitions(-D__LIBUSB__)
endif()""",
    ),
    (
        root / "CMakeLists.txt",
        """if(NOT ANDROID)
  dolphin_find_optional_system_library(HIDAPI Externals/hidapi)
endif()""",
        """if(NOT ANDROID AND NOT IOS)
  dolphin_find_optional_system_library(HIDAPI Externals/hidapi)
endif()""",
    ),
    (
        root / "Source/Core/Common/CMakeLists.txt",
        """    ${APPKIT_LIBRARY}
    ${COREFOUNDATION_LIBRARY}""",
        """    ${COREFOUNDATION_LIBRARY}""",
    ),
    (
        root / "Source/Core/InputCommon/CMakeLists.txt",
        """elseif(APPLE)
  target_sources(inputcommon PRIVATE
    ControllerInterface/Quartz/Quartz.h""",
        """elseif(APPLE AND NOT IOS)
  target_sources(inputcommon PRIVATE
    ControllerInterface/Quartz/Quartz.h""",
    ),
    (
        root / "Source/Core/InputCommon/CMakeLists.txt",
        """if(NOT ANDROID)
  target_link_libraries(inputcommon PUBLIC LibUSB::LibUSB)
endif()""",
        """if(NOT ANDROID AND NOT IOS)
  target_link_libraries(inputcommon PUBLIC LibUSB::LibUSB)
endif()""",
    ),
    (
        root / "Source/Core/Common/CMakeLists.txt",
        """elseif(APPLE)
  target_sources(common PRIVATE
    GL/GLInterface/AGL.h
    GL/GLInterface/AGL.mm
  )""",
        """elseif(APPLE AND NOT IOS)
  target_sources(common PRIVATE
    GL/GLInterface/AGL.h
    GL/GLInterface/AGL.mm
  )""",
    ),
]
for path, old, new in edits:
    text = path.read_text()
    if old not in text:
        raise SystemExit(f"iOS patch did not match {path}")
    path.write_text(text.replace(old, new, 1))
    print(f"iOS patch applied: {path.name}")
watcher = root / "Externals/watcher/watcher/include/wtr/watcher.hpp"
wt = watcher.read_text()
old_fs = "#if defined(__APPLE__)\n\n#include <CoreFoundation/CoreFoundation.h>"
new_fs = "#if defined(__APPLE__) && !defined(WATCHER_NO_FSEVENTS)\n\n#include <CoreFoundation/CoreFoundation.h>"
old_fb = "#if ! defined(__linux__) && ! defined(__ANDROID_API__) && ! defined(__APPLE__) \\\n  && ! defined(_WIN32)"
new_fb = "#if (! defined(__linux__) && ! defined(__ANDROID_API__) && ! defined(__APPLE__) \\\n  && ! defined(_WIN32)) || defined(WATCHER_NO_FSEVENTS)"
if old_fs not in wt or old_fb not in wt:
    raise SystemExit("watcher.hpp FSEvents guards not found")
watcher.write_text(wt.replace(old_fs, new_fs, 1).replace(old_fb, new_fb, 1))
print("iOS patch applied: watcher.hpp")
adapter = root / "Source/Core/InputCommon/GCAdapter.cpp"
at = adapter.read_text()
old_gc = """#ifndef ANDROID
#define GCADAPTER_USE_LIBUSB_IMPLEMENTATION true
#define GCADAPTER_USE_ANDROID_IMPLEMENTATION false
#else
#define GCADAPTER_USE_LIBUSB_IMPLEMENTATION false
#define GCADAPTER_USE_ANDROID_IMPLEMENTATION true
#endif"""
new_gc = """#if !defined(ANDROID) && !defined(TWINPLAY_NO_LIBUSB)
#define GCADAPTER_USE_LIBUSB_IMPLEMENTATION true
#define GCADAPTER_USE_ANDROID_IMPLEMENTATION false
#elif defined(ANDROID)
#define GCADAPTER_USE_LIBUSB_IMPLEMENTATION false
#define GCADAPTER_USE_ANDROID_IMPLEMENTATION true
#else
#define GCADAPTER_USE_LIBUSB_IMPLEMENTATION false
#define GCADAPTER_USE_ANDROID_IMPLEMENTATION false
#endif"""
if old_gc not in at:
    raise SystemExit("GCAdapter.cpp libusb guard not found")
adapter.write_text(at.replace(old_gc, new_gc, 1))
print("iOS patch applied: GCAdapter.cpp")
PY
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
    -DCMAKE_C_FLAGS="-fno-fast-math -DTWINPLAY_NO_LIBUSB=1" \
    -DCMAKE_CXX_FLAGS="-fno-fast-math -DWATCHER_NO_FSEVENTS=1 -DTWINPLAY_NO_LIBUSB=1" \
    -DCMAKE_OBJCXX_FLAGS="-fno-fast-math -DWATCHER_NO_FSEVENTS=1 -DTWINPLAY_NO_LIBUSB=1"
  ninja -C "$BUILD" core videometal
  python3 "$ROOT/scripts/check-dolphin-build.py" ios "$BUILD"
  python3 "$ROOT/scripts/compile-gc-host.py" "$BUILD/compile_commands.json" \
    "$ROOT/Core/gamecube/twinplay_gc_host.cpp" --ios
fi

echo "Dolphin $TARGET build finished: $BUILD"
