#!/bin/bash
# Builds Flycast's libretro core for the Apple SDK Xcode is using.
#
#   macOS arm64  — SH4 dynarec stays on (JIT is allowed).
#   iOS arm64    — -DTARGET_NO_REC so the SH4, ARM7 and AICA DSP recompilers
#                  are not compiled. The interpreter is the only CPU. No JIT.
#
# Output:
#   Core/third_party/build/flycast/macos/flycast_libretro.dylib
#   Core/third_party/build/flycast/iphoneos/flycast_libretro.dylib
#
# TWINPLAY_FLYCAST_STUB=1 skips the compile (the app still links; the core
# reports that it is not linked until this script has produced a dylib).
# TWINPLAY_FLYCAST_REQUIRED=1 makes a failed or skipped build a hard error.
# No ROMs, BIOS or games are downloaded.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN="$ROOT/Core/third_party/flycast-pin.txt"
# shellcheck disable=SC1090
source "$PIN"
SRC="$ROOT/Core/third_party/flycast"
OUT="$ROOT/Core/third_party/build/flycast"

if [[ "${TWINPLAY_FLYCAST_STUB:-}" == 1 ]]; then
    echo "Skipping Flycast build (TWINPLAY_FLYCAST_STUB=1)."
    if [[ "${TWINPLAY_FLYCAST_REQUIRED:-}" == 1 ]]; then
        echo "TWINPLAY_FLYCAST_REQUIRED=1 but the build was stubbed." >&2
        exit 1
    fi
    exit 0
fi

if [[ "$(uname -s)" != Darwin ]]; then
    echo "Flycast for TwinPlay is built on macOS (arm64 and iOS arm64)."
    if [[ "${TWINPLAY_FLYCAST_REQUIRED:-}" == 1 ]]; then exit 1; fi
    exit 0
fi

for d in /opt/homebrew/bin /usr/local/bin; do
    if [[ -x "$d/cmake" ]]; then export PATH="$d:$PATH"; fi
done
if ! command -v cmake >/dev/null || ! command -v ninja >/dev/null; then
    echo "cmake and ninja are required (brew install cmake ninja)." >&2
    exit 1
fi

if [[ ! -f "$SRC/CMakeLists.txt" ]]; then
    "$ROOT/scripts/fetch-flycast.sh"
fi
got="$(git -C "$SRC" rev-parse HEAD)"
if [[ "$got" != "$FLYCAST_COMMIT" ]]; then
    echo "Flycast pin moved ($got != $FLYCAST_COMMIT). Re-fetching."
    rm -rf "$SRC"
    "$ROOT/scripts/fetch-flycast.sh"
fi

platform="macos"
min_flag="-mmacosx-version-min=14.0"
sysroot="$(xcrun --sdk macosx --show-sdk-path)"
defs=""
if [[ "${TWINPLAY_FLYCAST_PLATFORM:-}" == iphoneos || "${PLATFORM_NAME:-}" == iphoneos || "${SDKROOT:-}" == *iPhoneOS* ]]; then
    platform="iphoneos"
    min_flag="-miphoneos-version-min=16.0"
    sysroot="$(xcrun --sdk iphoneos --show-sdk-path)"
    # TARGET_NO_REC is Flycast's own switch: FEAT_SHREC / FEAT_AREC / FEAT_DSPREC
    # become DYNAREC_NONE, so no executable pages are generated.
    # IOS selects OpenGLES headers in libretro's rglgen (it does not look at TARGET_IPHONE).
    defs="-DTARGET_NO_REC -DTARGET_IPHONE -DIOS"
fi

dest="$OUT/$platform"
dylib="$dest/flycast_libretro.dylib"
stamp="$dest/built.stamp"
if [[ -f "$dylib" && -f "$stamp" && "$(cat "$stamp")" == "$FLYCAST_COMMIT $platform" ]]; then
    echo "Flycast $platform is already built ($FLYCAST_COMMIT)."
    exit 0
fi

build="$dest/cmake"
rm -rf "$build"
mkdir -p "$build" "$dest"
jobs="$(sysctl -n hw.ncpu)"

cmake_args=(
    -G Ninja
    -S "$SRC"
    -B "$build"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_OSX_ARCHITECTURES=arm64
    -DCMAKE_OSX_SYSROOT="$sysroot"
    -DCMAKE_C_FLAGS="$min_flag $defs"
    -DCMAKE_CXX_FLAGS="$min_flag $defs"
    -DLIBRETRO=ON
    -DUSE_VULKAN=OFF
    -DUSE_OPENMP=OFF
    -DUSE_ALSA=OFF
    -DUSE_PULSEAUDIO=OFF
    -DUSE_LIBAO=OFF
    -DUSE_OSS=OFF
    -DUSE_BREAKPAD=OFF
    -DUSE_LUA=OFF
    -DUSE_DISCORD=OFF
    -DUSE_HOST_SDL=OFF
    -DUSE_HOST_LIBZIP=OFF
    -DENABLE_CTEST=OFF
)
if [[ "$platform" == iphoneos ]]; then
    # USE_OPENGL is what pulls in glsm and the GL context. USE_GLES makes that
    # path OpenGL ES and skips the desktop GL headers, which iOS does not have.
    cmake_args+=(
        -DCMAKE_SYSTEM_NAME=iOS
        -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0
        -DUSE_GLES=ON
        -DUSE_OPENGL=ON
        -DCMAKE_SHARED_LINKER_FLAGS=-Wl,-framework,OpenGLES
    )
else
    cmake_args+=(
        -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
        -DUSE_GLES=OFF
        -DUSE_OPENGL=ON
    )
fi

cmake "${cmake_args[@]}"
cmake --build "$build" --parallel "$jobs"

found="$(find "$build" -name 'flycast_libretro.dylib' -print -quit)"
if [[ -z "$found" ]]; then
    echo "flycast_libretro.dylib was not produced." >&2
    exit 1
fi
cp -f "$found" "$dylib"
install_name_tool -id "@rpath/flycast_libretro.dylib" "$dylib" || true

# Get_Sh4Recompiler lives in driver.cpp and is compiled only when the dynarec is on.
# The finished dylib exports retro_* and is stripped, so look at the object file.
has_rec=0
driver_obj="$(find "$build" -name 'driver.cpp.o' -print -quit || true)"
if [[ -n "$driver_obj" ]] && nm "$driver_obj" | grep -q 'Get_Sh4Recompiler'; then
    has_rec=1
fi
if [[ "$platform" == iphoneos && "$has_rec" == 1 ]]; then
    echo "iOS Flycast still contains Get_Sh4Recompiler. TARGET_NO_REC did not stick." >&2
    exit 1
fi
if [[ "$platform" == macos && "$has_rec" == 0 ]]; then
    echo "macOS Flycast is missing Get_Sh4Recompiler. The dynarec should stay on." >&2
    exit 1
fi

probe="$dest/flycast-probe"
cat > "$dest/probe.c" <<'EOF'
#include <dlfcn.h>
#include <stdio.h>
typedef unsigned (*api_fn)(void);
typedef void (*init_fn)(void);
int main(int argc, char** argv) {
    void* h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    api_fn ver = (api_fn)dlsym(h, "retro_api_version");
    init_fn init = (init_fn)dlsym(h, "retro_init");
    init_fn deinit = (init_fn)dlsym(h, "retro_deinit");
    if (!ver || ver() != 1) { fprintf(stderr, "retro_api_version is not 1\n"); return 1; }
    /* retro_init needs an environment callback. Just the version proves the dylib loads. */
    (void)init; (void)deinit;
    printf("flycast_libretro retro_api_version=1\n");
    return 0;
}
EOF
sdkflag=(-isysroot "$sysroot")
if [[ "$platform" == iphoneos ]]; then
    # The probe runs on the Mac, so check the iOS dylib with vtool / nm only.
    echo "iOS dylib is device-only; checked symbols instead of launching it."
else
    clang "${sdkflag[@]}" -O2 "$dest/probe.c" -o "$probe"
    "$probe" "$dylib"
fi

echo "$FLYCAST_COMMIT $platform" > "$stamp"
if [[ "$platform" == iphoneos ]]; then
    echo "Flycast iOS arm64 interpreter (no dynarec) -> $dylib"
else
    echo "Flycast macOS arm64 dynarec -> $dylib"
fi
