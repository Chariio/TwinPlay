#!/bin/bash
# Build TwinPlay's N64 frontend (and, when the toolchain can, Azahar without dynarmic).
#
# Linux (verified in this repo's development VM):
#   Mupen64Plus core with NO_ASM=1 (cached interpreter; dynarec sources are not compiled),
#   RSP-HLE, GLideN64 as a Mupen video plugin, and TwinPlay's audio/input plugins.
#   A probe then opens a 4 KB header through that stack. It does not run a game.
#
# macOS / Xcode / Xcode Cloud:
#   Invoked as a pre-build script. SDKROOT selects the iOS SDK when Xcode sets it.
#   This script cross-compiles real arm64 (device, and simulator if requested)
#   archives and plugins: Mupen64Plus NO_ASM=1 cached interpreter, RSP-HLE,
#   GLideN64 on OpenGL ES / EAGL, and Azahar FastInterp (no dynarmic, no JIT).
#   A stamp file skips a rebuild when the real libraries are already in place.
#
# No ROMs, BIOS, firmware or keys are downloaded.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PINS="$ROOT/Core/third_party/n64-3ds-pins.txt"
BUILD="$ROOT/Core/third_party/build"
PLUG="$BUILD/plugins"
mkdir -p "$PLUG"

# Prefer the tools already on this Mac (cmake / ninja), then Homebrew if present.
TOOLS_CANDIDATES=(
    "$ROOT/../tools/bin"
    "$HOME/Developer/TwinPlay-n64-3ds/tools/bin"
    /opt/homebrew/bin
    /usr/local/bin
)
for d in "${TOOLS_CANDIDATES[@]}"; do
    if [[ -x "$d/cmake" || -x "$d/ninja" ]]; then
        export PATH="$d:$PATH"
    fi
done

if [[ ! -d "$ROOT/Core/third_party/mupen64plus-core/src" ]]; then
    "$ROOT/scripts/fetch-n64-3ds.sh"
fi

jobs() { sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4; }

stub_lib() {
    local name="$1" src="$2"
    local cc="${CC:-cc}"
    local flags=()
    local arch="${ARCHS:-arm64}"
    arch="${arch%% *}"
    if [[ -n "${SDKROOT:-}" ]]; then
        flags+=(-isysroot "$SDKROOT")
        if [[ "${PLATFORM_NAME:-}" == "iphonesimulator" ]]; then
            flags+=(-target "${arch}-apple-ios16.0-simulator" -mios-simulator-version-min=16.0)
        elif [[ "${PLATFORM_NAME:-}" == "iphoneos" ]]; then
            flags+=(-target "${arch}-apple-ios16.0" -mios-version-min=16.0)
        fi
    fi
    "$cc" "${flags[@]}" -std=c11 -c "$src" -o "$BUILD/${name}.o"
    rm -f "$BUILD/lib${name}.a"
    ar rcs "$BUILD/lib${name}.a" "$BUILD/${name}.o"
}

is_real_n64() {
    local a="$BUILD/libtwinplay_n64.a"
    [[ -f "$a" ]] || return 1
    # The stub object is tiny and contains this string.
    if strings "$a" 2>/dev/null | grep -q "N64 core not linked"; then
        return 1
    fi
    # A real archive also ships the Mupen dylib.
    [[ -f "$PLUG/libmupen64plus.dylib" ]] || return 1
    return 0
}

is_real_3ds() {
    local a="$BUILD/libtwinplay_3ds.a"
    [[ -f "$a" ]] || return 1
    # grep -q on a pipe is unsafe under pipefail: nm/strings get SIGPIPE (exit 141)
    # after the first match, and the pipeline is treated as a failure.
    if grep -a -F -q "3DS core not linked" "$a" 2>/dev/null; then
        return 1
    fi
    if ! grep -a -F -q "twinplay_3ds_available" "$a" 2>/dev/null; then
        return 1
    fi
    local sz
    sz=$(wc -c < "$a" | tr -d ' ')
    [[ "$sz" -gt 5000000 ]]
}

# ---------- Linux / host desktop build (unchanged) ----------
build_n64_host() {
    local core="$ROOT/Core/third_party/mupen64plus-core/projects/unix"
    local rsp="$ROOT/Core/third_party/mupen64plus-rsp-hle/projects/unix"
    local api="$ROOT/Core/third_party/mupen64plus-core/src/api"
    local cxx="${CXX:-g++}"
    local cc="${CC:-gcc}"
    export CC="$cc" CXX="$cxx"
    make -C "$core" -j"$(jobs)" NO_ASM=1 OSD=0 VULKAN=0 all || return 1
    make -C "$rsp" -j"$(jobs)" all || return 1
    local gbuild="$BUILD/gliden64"
    cmake -S "$ROOT/Core/third_party/GLideN64/src" -B "$gbuild" \

        -DCMAKE_C_COMPILER="$cc" -DCMAKE_CXX_COMPILER="$cxx" \
        -DCMAKE_BUILD_TYPE=Release -DMUPENPLUSAPI=ON -DMUPENPLUSAPI_GLIDENUI=OFF -DNO_OSD=ON || return 1
    cmake --build "$gbuild" -j"$(jobs)" || return 1
    "$cxx" -std=c++20 -fPIC -I"$api" -shared -o "$PLUG/mupen64plus-audio-twinplay.so" "$ROOT/Core/n64/audio_plugin.cpp" || return 1
    "$cxx" -std=c++20 -fPIC -I"$api" -shared -o "$PLUG/mupen64plus-input-twinplay.so" "$ROOT/Core/n64/input_plugin.cpp" || return 1
    "$cxx" -std=c++20 -fPIC -I"$api" -c "$ROOT/Core/n64/vidext_egl.cpp" -o "$BUILD/vidext_egl.o" || return 1
    "$cxx" -std=c++20 -fPIC -I"$api" -c "$ROOT/Core/n64/twinplay_n64.cpp" -o "$BUILD/twinplay_n64.o" || return 1
    rm -f "$BUILD/libtwinplay_n64.a"
    ar rcs "$BUILD/libtwinplay_n64.a" "$BUILD/twinplay_n64.o" "$BUILD/vidext_egl.o"
    cp -a "$core/libmupen64plus.so.2" "$core/libmupen64plus.so.2.0.0" "$PLUG/"
    cp -a "$rsp/mupen64plus-rsp-hle.so" "$PLUG/"
    cp -a "$gbuild/plugin/Release/mupen64plus-video-GLideN64.so" "$PLUG/"
    echo "N64 host build: cached interpreter (NO_ASM=1), GLideN64, RSP-HLE."
    if [[ "${TWINPLAY_N64_PROBE:-1}" == 1 ]]; then
        "$cxx" -std=c++20 -I"$api" -o "$BUILD/n64probe" "$ROOT/scripts/n64-probe.cpp" \
            "$BUILD/twinplay_n64.o" "$BUILD/vidext_egl.o" -ldl -lEGL -lGL -lpthread || return 1
        LD_LIBRARY_PATH="$PLUG" "$BUILD/n64probe" "$PLUG" || return 1
    fi
}

# ---------- iOS cross build ----------
ios_setup() {
    IOS_PLATFORM="${PLATFORM_NAME:-iphoneos}"
    if [[ -n "${SDKROOT:-}" ]]; then
        IOS_SDK="$SDKROOT"
        if [[ "$SDKROOT" == *iPhoneSimulator* || "$IOS_PLATFORM" == iphonesimulator ]]; then
            IOS_PLATFORM=iphonesimulator
        else
            IOS_PLATFORM=iphoneos
        fi
    else
        if [[ "$IOS_PLATFORM" == iphonesimulator ]]; then
            IOS_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
        else
            IOS_PLATFORM=iphoneos
            IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
        fi
    fi
    IOS_ARCH="${ARCHS:-arm64}"
    IOS_ARCH="${IOS_ARCH%% *}"
    IOS_CC="$(xcrun --sdk ${IOS_PLATFORM} --find clang)"
    IOS_CXX="$(xcrun --sdk ${IOS_PLATFORM} --find clang++)"
    if [[ "$IOS_PLATFORM" == iphonesimulator ]]; then
        IOS_TRIPLE="${IOS_ARCH}-apple-ios16.0-simulator"
        IOS_MIN="-mios-simulator-version-min=16.0"
    else
        IOS_TRIPLE="${IOS_ARCH}-apple-ios16.0"
        IOS_MIN="-miphoneos-version-min=16.0"
    fi
    IOS_FLAGS="-isysroot $IOS_SDK -target $IOS_TRIPLE $IOS_MIN -arch $IOS_ARCH -fPIC -O3 -DNDEBUG -fvisibility=hidden -fvisibility-inlines-hidden -DGLES_SILENCE_DEPRECATION"
    IOS_WORKDIR="$BUILD/ios-$IOS_PLATFORM-$IOS_ARCH"
    mkdir -p "$IOS_WORKDIR"
    STAMP="$BUILD/ios-cores-$IOS_PLATFORM-$IOS_ARCH.stamp"
}

install_name() {
    local lib="$1" name
    name="$(basename "$lib")"
    install_name_tool -id "@rpath/$name" "$lib" 2>/dev/null || true
}

build_ios_support_libs() {
    local cc="$IOS_CC"
    "$cc" $IOS_FLAGS -std=c11 -I"$ROOT/Core/n64/sdl_ios" -c "$ROOT/Core/n64/sdl_ios/sdl_stub.c" -o "$IOS_WORKDIR/sdl_stub.o"
    "$cc" $IOS_FLAGS -std=c11 -I"$ROOT/Core/n64/png_ios" -c "$ROOT/Core/n64/png_ios/png_stub.c" -o "$IOS_WORKDIR/png_stub.o"
    rm -f "$IOS_WORKDIR/libsdl_ios.a" "$IOS_WORKDIR/libpng_ios.a"
    ar rcs "$IOS_WORKDIR/libsdl_ios.a" "$IOS_WORKDIR/sdl_stub.o"
    ar rcs "$IOS_WORKDIR/libpng_ios.a" "$IOS_WORKDIR/png_stub.o"
}

patch_mupen_ios_flags() {
    # The unix makefile always appends -mmacosx-version-min when OS=OSX. Rewrite for iOS.
    local mf="$1"
    python3 - "$mf" "$IOS_MIN" "$IOS_SDK" << 'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
mn, sdk = sys.argv[2], sys.argv[3]
t = p.read_text()
t = t.replace("-mmacosx-version-min=11.0", mn)
t = t.replace("-mmacosx-version-min=10.9", mn)
# Keep a marker so a second run is harmless.
p.write_text(t)
PY
}

build_mupen_ios() {
    local core="$ROOT/Core/third_party/mupen64plus-core/projects/unix"
    patch_mupen_ios_flags "$core/Makefile"
    make -C "$core" clean >/dev/null 2>&1 || true
    local api="$ROOT/Core/third_party/mupen64plus-core/src/api"
    # A stub pkg-config so the makefile's "essential dependencies" check passes.
    # zlib/libpng flags are provided below, so pkg-config is never queried for them.
    printf '%s\n' '#!/bin/sh' 'exit 1' > "$IOS_WORKDIR/pkg-config"
    chmod +x "$IOS_WORKDIR/pkg-config"
    # Export flags so the makefile can still append include paths (command-line CFLAGS would replace them).
    export CC="$IOS_CC" CXX="$IOS_CXX"
    export CFLAGS="$IOS_FLAGS -DNO_ASM -I$ROOT/Core/third_party/mupen64plus-core/src -I$api -I$ROOT/Core/n64/sdl_ios -I$ROOT/Core/n64/png_ios"
    export CXXFLAGS="$IOS_FLAGS -stdlib=libc++"
    export LDFLAGS="$IOS_FLAGS -dynamiclib -install_name @rpath/libmupen64plus.dylib -framework CoreFoundation"
    make -C "$core" -j"$(jobs)" \
        HOST_CPU="$IOS_ARCH" \
        OS=OSX \
        OSX_SDK_PATH="$IOS_SDK" \
        NO_ASM=1 OSD=0 VULKAN=0 NETPLAY=0 \
        CC="$IOS_CC" CXX="$IOS_CXX" \
        OPTFLAGS="-O2" \
        PIC=1 \
        PKG_CONFIG="$IOS_WORKDIR/pkg-config" \
        APIDIR="$api" \
        SDL_CFLAGS="-I$ROOT/Core/n64/sdl_ios" \
        SDL_LDLIBS="-L$IOS_WORKDIR -lsdl_ios" \
        ZLIB_CFLAGS="" \
        ZLIB_LDLIBS="-lz" \
        LIBPNG_CFLAGS="-I$ROOT/Core/n64/png_ios" \
        LIBPNG_LDLIBS="-L$IOS_WORKDIR -lpng_ios" \
        all
    cp -a "$core/libmupen64plus.dylib" "$PLUG/libmupen64plus.dylib"
    install_name "$PLUG/libmupen64plus.dylib"
    # Data files the core searches for (ini). Not ROMs or keys.
    mkdir -p "$PLUG"
    cp -a "$ROOT/Core/third_party/mupen64plus-core/data/"* "$PLUG/" 2>/dev/null || true
}

build_rsp_ios() {
    local rsp="$ROOT/Core/third_party/mupen64plus-rsp-hle/projects/unix"
    patch_mupen_ios_flags "$rsp/Makefile"
    make -C "$rsp" clean >/dev/null 2>&1 || true
    local api="$ROOT/Core/third_party/mupen64plus-core/src/api"
    export CC="$IOS_CC" CXX="$IOS_CXX"
    export CFLAGS="$IOS_FLAGS -I$api"
    export CXXFLAGS="$IOS_FLAGS -stdlib=libc++"
    export LDFLAGS="$IOS_FLAGS -dynamiclib -install_name @rpath/mupen64plus-rsp-hle.dylib"
    make -C "$rsp" -j"$(jobs)" \
        HOST_CPU="$IOS_ARCH" \
        OS=OSX \
        OSX_SDK_PATH="$IOS_SDK" \
        CC="$IOS_CC" CXX="$IOS_CXX" \
        OPTFLAGS="-O2" \
        PIC=1 \
        PKG_CONFIG="$IOS_WORKDIR/pkg-config" \
        APIDIR="$api" \
        SHARED="-dynamiclib" \
        all
    cp -a "$rsp/mupen64plus-rsp-hle.dylib" "$PLUG/mupen64plus-rsp-hle.dylib"
    install_name "$PLUG/mupen64plus-rsp-hle.dylib"
}

build_gliden_ios() {
    command -v cmake >/dev/null || { echo "cmake is required for GLideN64"; return 1; }
    local gbuild="$IOS_WORKDIR/gliden64"
    local OPENGL_LIB="$IOS_SDK/System/Library/Frameworks/OpenGLES.framework/OpenGLES.tbd"
    if [[ ! -e "$OPENGL_LIB" ]]; then
        OPENGL_LIB="$IOS_SDK/System/Library/Frameworks/OpenGLES.framework/OpenGLES"
    fi
    rm -rf "$gbuild"
    cmake -S "$ROOT/Core/third_party/GLideN64/src" -B "$gbuild" \
        -C "$ROOT/scripts/ios-gliden64.cmake" \
        -DOPENGL_FOUND=TRUE \
        -DOPENGL_INCLUDE_DIR="$ROOT/Core/third_party/GLideN64/src/inc" \
        -DOPENGL_gl_LIBRARY="${OPENGL_LIB}" \
        -DOPENGL_opengl_LIBRARY="${OPENGL_LIB}" \
        -DOpenGL_GL_PREFERENCE=LEGACY \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="$IOS_SDK" \
        -DCMAKE_OSX_ARCHITECTURES="$IOS_ARCH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
        -DCMAKE_C_COMPILER="$IOS_CC" \
        -DCMAKE_CXX_COMPILER="$IOS_CXX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS="$IOS_FLAGS -DOS_IOS" \
        -DCMAKE_CXX_FLAGS="$IOS_FLAGS -DOS_IOS -stdlib=libc++" \
        -DMUPENPLUSAPI=ON \
        -DMUPENPLUSAPI_GLIDENUI=OFF \
        -DNO_OSD=ON \
        -DNOHQ=ON \
        -DUSE_IPO=OFF \
        -DCMAKE_MACOSX_RPATH=ON \
        -G "${CMAKE_GENERATOR:-Ninja}"
    cmake --build "$gbuild" -j"$(jobs)"
    local built
    built="$(find "$gbuild" -name 'mupen64plus-video-GLideN64.dylib' -o -name 'libmupen64plus-video-GLideN64.dylib' | head -n 1)"
    if [[ -z "$built" ]]; then
        echo "GLideN64 dylib was not produced"; return 1
    fi
    cp -a "$built" "$PLUG/mupen64plus-video-GLideN64.dylib"
    install_name "$PLUG/mupen64plus-video-GLideN64.dylib"
}

build_n64_frontend_ios() {
    local api="$ROOT/Core/third_party/mupen64plus-core/src/api"
    local cxx="$IOS_CXX"
    "$cxx" $IOS_FLAGS -std=c++20 -fPIC -I"$api" -c "$ROOT/Core/n64/audio_plugin.cpp" -o "$IOS_WORKDIR/audio_plugin.o"
    "$cxx" $IOS_FLAGS -std=c++20 -fPIC -I"$api" -c "$ROOT/Core/n64/input_plugin.cpp" -o "$IOS_WORKDIR/input_plugin.o"
    "$cxx" $IOS_FLAGS -std=c++20 -fPIC -fobjc-arc -I"$api" -c "$ROOT/Core/n64/vidext_eagl.mm" -o "$IOS_WORKDIR/vidext_eagl.o"
    "$cxx" $IOS_FLAGS -std=c++20 -fPIC -I"$api" -c "$ROOT/Core/n64/twinplay_n64.cpp" -o "$IOS_WORKDIR/twinplay_n64.o"
    "$cxx" $IOS_FLAGS -dynamiclib -install_name @rpath/mupen64plus-audio-twinplay.dylib \
        -o "$PLUG/mupen64plus-audio-twinplay.dylib" "$IOS_WORKDIR/audio_plugin.o"
    "$cxx" $IOS_FLAGS -dynamiclib -install_name @rpath/mupen64plus-input-twinplay.dylib \
        -o "$PLUG/mupen64plus-input-twinplay.dylib" "$IOS_WORKDIR/input_plugin.o"
    install_name "$PLUG/mupen64plus-audio-twinplay.dylib"
    install_name "$PLUG/mupen64plus-input-twinplay.dylib"
    rm -f "$BUILD/libtwinplay_n64.a"
    ar rcs "$BUILD/libtwinplay_n64.a" "$IOS_WORKDIR/twinplay_n64.o" "$IOS_WORKDIR/vidext_eagl.o"
    # Confirm we did not ship the stub.
    if strings "$BUILD/libtwinplay_n64.a" | grep -q "N64 core not linked"; then
        echo "libtwinplay_n64.a still looks like the stub"; return 1
    fi
    echo "N64 iOS build: cached interpreter (NO_ASM=1), GLideN64 GLES/EAGL, RSP-HLE."
    if ! is_real_n64; then
        echo "N64 iOS libraries are incomplete (missing Mupen dylib or frontend is the stub)."
        return 1
    fi
}

azahar_src() {
    if [[ -n "${AZAHAR_SRC:-}" && -d "$AZAHAR_SRC/src/core" ]]; then
        echo "$AZAHAR_SRC"
        return
    fi
    # Prefer the in-tree copy (TwinPlay iOS patches live here). The sibling
    # clone is only a fallback for missing externals.
    if [[ -d "$ROOT/Core/third_party/azahar/src/core" ]]; then
        echo "$ROOT/Core/third_party/azahar"
        return
    fi
    local dev="$HOME/Developer/TwinPlay-n64-3ds/src/azahar"
    if [[ -d "$dev/src/core" ]]; then
        echo "$dev"
        return
    fi
    return 1
}

sync_azahar_externals() {
    # The in-tree copy may be missing git submodules. Copy them from the cloned tree.
    local src="$1"
    local dest="$ROOT/Core/third_party/azahar"
    if [[ "$src" == "$dest" ]]; then
        return 0
    fi
    # Reuse the in-tree CMake / sources; bring in populated externals.
    mkdir -p "$dest/externals"
    local name
    for name in boost fmt cryptopp teakra zstd libyuv lodepng inih xxHash nihstro \
                soundtouch faad2 microtar libressl enet cpp-jwt dds-ktx; do
        if [[ -d "$src/externals/$name" ]]; then
            rm -rf "$dest/externals/$name"
            cp -a "$src/externals/$name" "$dest/externals/$name"
        fi
    done
}

build_3ds_ios() {
    local src
    src="$(azahar_src)" || { echo "Azahar sources not found"; return 1; }
    command -v cmake >/dev/null || { echo "cmake is required for Azahar"; return 1; }
    if [[ ! -d "$src/externals/robin-map/include/tsl" ]]; then
        git clone --depth 1 https://github.com/Tessil/robin-map.git "$src/externals/robin-map"
    fi
    if [[ ! -f "$src/dist/compatibility_list/compatibility_list.qrc" ]]; then
        mkdir -p "$src/dist/compatibility_list"
        printf '<RCC>\n  <qresource prefix="compatibility_list">\n  </qresource>\n</RCC>\n' > "$src/dist/compatibility_list/compatibility_list.qrc"
    fi
    "$ROOT/scripts/patch-azahar-no-jit.sh" "$src"
    # Prefer the cloned tree (with submodules). Do not retarget CMake at the
    # gitignored in-tree copy, which may be missing submodule files.
    local abuild="$IOS_WORKDIR/azahar"
    mkdir -p "$abuild/externals"
    # Official KhronosGroup MoltenVK static xcframework (Apache-2.0), vendored under third_party.
    ln -sfn "$ROOT/Core/third_party/MoltenVK" "$abuild/externals/MoltenVK"
    cmake -S "$src" -B "$abuild" \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="$IOS_SDK" \
        -DCMAKE_OSX_ARCHITECTURES="$IOS_ARCH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
        -DCMAKE_C_COMPILER="$IOS_CC" \
        -DCMAKE_CXX_COMPILER="$IOS_CXX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS="$IOS_FLAGS" \
        -DCMAKE_CXX_FLAGS="$IOS_FLAGS -stdlib=libc++" \
        -DTWINPLAY_NO_JIT=ON \
        -DENABLE_SDL2=OFF \
        -DENABLE_QT=OFF \
        -DENABLE_QT_TRANSLATION=OFF \
        -DENABLE_WEB_SERVICE=OFF \
        -DENABLE_SCRIPTING=OFF \
        -DENABLE_GDBSTUB=OFF \
        -DENABLE_CUBEB=OFF \
        -DENABLE_OPENAL=OFF \
        -DENABLE_LIBUSB=OFF \
        -DENABLE_FFMPEG=OFF \
        -DENABLE_TESTS=OFF \
        -DENABLE_ROOM=OFF \
        -DENABLE_ROOM_STANDALONE=OFF \
        -DENABLE_SOFTWARE_RENDERER=ON \
        -DENABLE_OPENGL=OFF \
        -DENABLE_VULKAN=ON \
        -DENABLE_DISCORD_RPC=OFF \
        -DENABLE_LTO=OFF \
        -DENABLE_BUILTIN_KEYBLOB=OFF \
        -DCITRA_WARNINGS_AS_ERRORS=OFF \
        -DCITRA_USE_PRECOMPILED_HEADERS=OFF \
        -DENABLE_LIBRETRO=OFF \
        -DUSE_SYSTEM_BOOST=OFF \
        -DTWINPLAY_3DS_FRONTEND="$ROOT/Core/n3ds/twinplay_3ds.cpp;$ROOT/Core/n3ds/twinplay_3ds_metal.mm" \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
        -G "${CMAKE_GENERATOR:-Ninja}" || return 1
    # citra_common / citra_core / video_core / audio_core are EXCLUDE_FROM_ALL,
    # so a default cmake --build would only compile a few externals.
    # twinplay_3ds is the frontend target added by patch-azahar-no-jit.sh.
    if ! cmake --build "$abuild" -j"$(jobs)" --target citra_core video_core audio_core citra_common twinplay_3ds; then
        echo "Azahar ninja build failed"; return 1
    fi
    local corelib
    corelib="$(find "$abuild" -name 'libcitra_core.a' | head -n 1)"
    if [[ -z "$corelib" ]]; then
        echo "Azahar produced no libcitra_core.a"; return 1
    fi
    # Merge every static library Azahar produced (frontend + cores + deps).
    local libs=()
    while IFS= read -r f; do
        libs+=("$f")
    done < <(find "$abuild" -name '*.a' ! -name '*test*' ! -name '*Catch*' ! -name '*gmock*' | sort)
    if [[ ${#libs[@]} -eq 0 ]]; then
        echo "Azahar produced no static libraries"; return 1
    fi
    rm -f "$BUILD/libtwinplay_3ds.a"
    libtool -static -o "$BUILD/libtwinplay_3ds.a" "${libs[@]}"
    if ! is_real_3ds; then
        echo "libtwinplay_3ds.a is not a real Azahar merge"; return 1
    fi
    echo "3DS iOS build: Azahar FastInterp, Vulkan/MoltenVK, no dynarmic ($(wc -c < "$BUILD/libtwinplay_3ds.a" | tr -d ' ') bytes)."
}

cleanup_intermediates() {
    # Keep the finished archives, plugins, and stamp. Drop compiler working trees.
    rm -rf "$IOS_WORKDIR"
    # Drop leftover object files at the build root from earlier stub runs.
    rm -f "$BUILD"/twinplay_n64.o "$BUILD"/twinplay_3ds.o "$BUILD"/vidext_egl.o
}

write_stamp() {
    {
        echo "platform=$IOS_PLATFORM"
        echo "arch=$IOS_ARCH"
        echo "sdk=$(basename "$IOS_SDK")"
        if is_real_n64; then echo "n64=real"; else echo "n64=stub"; fi
        if is_real_3ds; then echo "n3ds=real"; else echo "n3ds=missing"; fi
        echo "version=1"
    } > "$STAMP"
}

build_ios_all() {
    ios_setup
    if is_real_n64 && is_real_3ds && [[ -f "${STAMP:-}" ]]; then
        echo "iOS cores already built for $IOS_PLATFORM $IOS_ARCH. Skipping (stamp $STAMP)."
        return 0
    fi
    if ! command -v cmake >/dev/null; then
        echo "cmake not found; cannot cross-compile the cores."
        return 1
    fi
    if ! command -v ninja >/dev/null; then
        CMAKE_GENERATOR=Ninja
        # If ninja is missing, fall back to Unix Makefiles.
        if ! command -v ninja >/dev/null; then
            CMAKE_GENERATOR="Unix Makefiles"
        fi
    else
        CMAKE_GENERATOR=Ninja
    fi
    export CMAKE_GENERATOR
    if is_real_n64; then
        echo "N64 iOS libraries already present; skipping the N64 rebuild."
    else
        build_ios_support_libs
        build_mupen_ios
        build_rsp_ios
        # Make flags must not leak into CMake.
        unset CFLAGS CXXFLAGS LDFLAGS CC CXX || true
        build_gliden_ios
        build_n64_frontend_ios
    fi
    unset CFLAGS CXXFLAGS LDFLAGS CC CXX || true
    if is_real_3ds; then
        echo "3DS iOS library already present; skipping the 3DS rebuild."
    elif [[ "${TWINPLAY_SKIP_3DS:-}" == 1 ]]; then
        echo "Skipping 3DS core (TWINPLAY_SKIP_3DS=1)."
        if ! is_real_3ds; then stub_lib twinplay_3ds "$ROOT/Core/n3ds/twinplay_3ds_stub.c"; fi
    elif ! ( set -euo pipefail; build_3ds_ios ); then
        echo "WARNING: Azahar iOS build failed. Leaving the 3DS stub so the app still links."
        # Drop any partial merge that is_real_3ds would reject, then write the stub.
        if ! is_real_3ds; then
            stub_lib twinplay_3ds "$ROOT/Core/n3ds/twinplay_3ds_stub.c"
        fi
    fi
    write_stamp
    # Only drop the compiler working tree after both cores are really in place.
    if is_real_n64 && is_real_3ds; then
        cleanup_intermediates
    else
        echo "Keeping $IOS_WORKDIR so a later run can resume the 3DS compile."
    fi
}

# ---------- entry ----------
if [[ -n "${SDKROOT:-}" && "${SDKROOT}" == *iPhone* ]]; then
    set +e
    ( set -euo pipefail; build_ios_all )
    status=$?
    set -e
    if [[ $status -eq 0 ]]; then
        echo "iOS core build finished."
        exit 0
    fi
    echo "iOS core build failed; writing stubs so the Xcode link still succeeds."
    stub_lib twinplay_n64 "$ROOT/Core/n64/twinplay_n64_stub.c"
    stub_lib twinplay_3ds "$ROOT/Core/n3ds/twinplay_3ds_stub.c"
    exit 1
fi

# Direct invocation on a Mac (no SDKROOT): build for the device SDK.
if [[ "$(uname -s)" == Darwin ]]; then
    export PLATFORM_NAME="${PLATFORM_NAME:-iphoneos}"
    export ARCHS="${ARCHS:-arm64}"
    export SDKROOT="${SDKROOT:-$(xcrun --sdk iphoneos --show-sdk-path)}"
    build_ios_all
    exit $?
fi

if pkg-config --exists sdl2 libpng zlib && build_n64_host; then
    echo "N64 static library is the real frontend."
else
    echo "Full N64 build is not available on this machine. Writing the N64 stub."
    stub_lib twinplay_n64 "$ROOT/Core/n64/twinplay_n64_stub.c"
fi
stub_lib twinplay_3ds "$ROOT/Core/n3ds/twinplay_3ds_stub.c"
echo "3DS archive is the stub until Azahar is configured with -DTWINPLAY_NO_JIT=ON (docs/N64_3DS.md)."
