#!/bin/bash
# Apply TWINPLAY_NO_JIT guards so dynarmic, xbyak and oaknut are not compiled.
# Safe to re-run. Does not add keys, BIOS or ROMs.
set -euo pipefail
ROOT="${1:?azahar source dir}"

python3 - "$ROOT" << 'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])

def once(path: pathlib.Path, needle: str, insert: str, hint: str):
    text = path.read_text(encoding="utf-8")
    if "TWINPLAY_NO_JIT" in text and hint in text:
        print(f"already patched {path}")
        return
    if needle not in text:
        raise SystemExit(f"pattern not found in {path}: {hint}")
    path.write_text(text.replace(needle, insert, 1), encoding="utf-8")
    print(f"patched {path}")

# Option at the top of the root CMakeLists so -DTWINPLAY_NO_JIT=ON is honored.
cmake = root / "CMakeLists.txt"
text = cmake.read_text(encoding="utf-8")
if "option(TWINPLAY_NO_JIT" not in text:
    cmake.write_text(
        "option(TWINPLAY_NO_JIT \"Build without dynarmic / xbyak / oaknut (required for iOS)\" OFF)\n"
        "if(TWINPLAY_NO_JIT)\n"
        "    add_compile_definitions(TWINPLAY_NO_JIT=1)\n"
        "endif()\n\n" + text,
        encoding="utf-8",
    )
    print("patched root CMakeLists.txt option")

ext = root / "externals" / "CMakeLists.txt"
text = ext.read_text(encoding="utf-8")
if "TWINPLAY_NO_JIT" not in text:
    # One guard around Xbyak, Oaknut and Dynarmic (they sit back-to-back before getopt).
    start = text.find("# Xbyak\n")
    end = text.find("# getopt\n")
    if start < 0 or end < 0 or end <= start:
        raise SystemExit("cannot wrap Xbyak/Oaknut/Dynarmic in externals/CMakeLists.txt")
    chunk = text[start:end]
    text = text[:start] + "if(NOT TWINPLAY_NO_JIT)\n" + chunk + "endif()\n\n" + text[end:]
    ext.write_text(text, encoding="utf-8")
    print("patched externals/CMakeLists.txt")

core = root / "src" / "core" / "CMakeLists.txt"
text = core.read_text(encoding="utf-8")
needle = '''if ("x86_64" IN_LIST ARCHITECTURE OR "arm64" IN_LIST ARCHITECTURE)
    target_sources(citra_core PRIVATE
        arm/dynarmic/arm_dynarmic.cpp
'''
insert = '''if (NOT TWINPLAY_NO_JIT AND ("x86_64" IN_LIST ARCHITECTURE OR "arm64" IN_LIST ARCHITECTURE))
    target_sources(citra_core PRIVATE
        arm/dynarmic/arm_dynarmic.cpp
'''
if "NOT TWINPLAY_NO_JIT AND" in text and "arm/dynarmic/arm_dynarmic.cpp" in text:
    print("already patched src/core/CMakeLists.txt")
elif needle not in text:
    raise SystemExit("dynarmic block not found in src/core/CMakeLists.txt")
else:
    core.write_text(text.replace(needle, insert, 1), encoding="utf-8")
    print("patched src/core/CMakeLists.txt")

mon = root / "src" / "core" / "arm" / "exclusive_monitor.cpp"
text = mon.read_text(encoding="utf-8")
text2 = text.replace(
    "#if CITRA_ARCH(x86_64) || CITRA_ARCH(arm64)\n#include \"core/arm/dynarmic/arm_exclusive_monitor.h\"\n#endif",
    "#if !defined(TWINPLAY_NO_JIT) && (CITRA_ARCH(x86_64) || CITRA_ARCH(arm64))\n#include \"core/arm/dynarmic/arm_exclusive_monitor.h\"\n#endif",
)
text2 = text2.replace(
    "#if CITRA_ARCH(x86_64) || CITRA_ARCH(arm64)\n    if (Settings::values.use_cpu_jit) {\n        return std::make_unique<Core::DynarmicExclusiveMonitor>(memory, num_cores);\n    }\n#endif",
    "#if !defined(TWINPLAY_NO_JIT) && (CITRA_ARCH(x86_64) || CITRA_ARCH(arm64))\n    if (Settings::values.use_cpu_jit) {\n        return std::make_unique<Core::DynarmicExclusiveMonitor>(memory, num_cores);\n    }\n#endif",
)
if text2 == text:
    if "TWINPLAY_NO_JIT" in text:
        print("already patched exclusive_monitor.cpp")
    else:
        raise SystemExit("exclusive_monitor.cpp patterns not found")
else:
    mon.write_text(text2, encoding="utf-8")
    print("patched exclusive_monitor.cpp")

# Bundled tsl::robin_map (normally comes from dynarmic).
cmake_txt = cmake.read_text(encoding="utf-8")
old = """# Use system tsl::robin_map if available (otherwise we fallback to version bundled with dynarmic)
find_package(tsl-robin-map QUIET)
"""
new = """# Use system tsl::robin_map if available (otherwise we fallback to version bundled with dynarmic)
find_package(tsl-robin-map QUIET)
if (NOT TARGET tsl::robin_map)
    add_library(tsl-robin-map INTERFACE)
    add_library(tsl::robin_map ALIAS tsl-robin-map)
    target_include_directories(tsl-robin-map INTERFACE "${PROJECT_SOURCE_DIR}/externals/robin-map/include")
    message(STATUS "Using bundled tsl::robin_map from externals/robin-map")
endif()
"""
if "Using bundled tsl::robin_map" not in cmake_txt:
    if old not in cmake_txt:
        raise SystemExit("robin_map find_package block not found")
    cmake.write_text(cmake_txt.replace(old, new, 1), encoding="utf-8")
    print("patched bundled robin_map")
else:
    print("already patched bundled robin_map")

# Skip the rigid submodule check when we are not building dynarmic/xbyak/oaknut.
cmake_txt = cmake.read_text(encoding="utf-8")
if "if (NOT TWINPLAY_NO_JIT)\n    check_submodules_present()" not in cmake_txt:
    cmake_txt2 = cmake_txt.replace("check_submodules_present()", "if (NOT TWINPLAY_NO_JIT)\n    check_submodules_present()\nendif()")
    if cmake_txt2 == cmake_txt:
        print("note: check_submodules_present() not rewritten (already guarded or missing)")
    else:
        cmake.write_text(cmake_txt2, encoding="utf-8")
        print("patched check_submodules_present")

# Do not link oaknut/xbyak when TWINPLAY_NO_JIT.
for rel, old, new in [
    ("src/common/CMakeLists.txt",
     'if ("x86_64" IN_LIST ARCHITECTURE)\n    target_link_libraries(citra_common PRIVATE xbyak)\nendif()\n\nif ("arm64" IN_LIST ARCHITECTURE)\n    target_link_libraries(citra_common PRIVATE oaknut)\nendif()\n',
     'if (NOT TWINPLAY_NO_JIT AND "x86_64" IN_LIST ARCHITECTURE)\n    target_link_libraries(citra_common PRIVATE xbyak)\nendif()\n\nif (NOT TWINPLAY_NO_JIT AND "arm64" IN_LIST ARCHITECTURE)\n    target_link_libraries(citra_common PRIVATE oaknut)\nendif()\n'),
    ("src/video_core/CMakeLists.txt",
     'if ("x86_64" IN_LIST ARCHITECTURE)\n    target_link_libraries(video_core PUBLIC xbyak)\nendif()\n\nif ("arm64" IN_LIST ARCHITECTURE)\n    target_link_libraries(video_core PUBLIC oaknut)\nendif()\n',
     'if (NOT TWINPLAY_NO_JIT AND "x86_64" IN_LIST ARCHITECTURE)\n    target_link_libraries(video_core PUBLIC xbyak)\nendif()\n\nif (NOT TWINPLAY_NO_JIT AND "arm64" IN_LIST ARCHITECTURE)\n    target_link_libraries(video_core PUBLIC oaknut)\nendif()\n'),
]:
    path = root / rel
    text = path.read_text(encoding="utf-8")
    if 'NOT TWINPLAY_NO_JIT AND "arm64"' in text:
        print(f"already guarded {rel}")
        continue
    if old not in text:
        raise SystemExit(f"link block not found in {rel}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print(f"patched {rel} oaknut/xbyak links")

# Optional frontend target so include paths come from CMake.
cmake_txt = cmake.read_text(encoding="utf-8")
marker = "add_library(twinplay_3ds STATIC ${TWINPLAY_3DS_FRONTEND})"
if marker not in cmake_txt:
    cmake.write_text(cmake_txt + """
if (TWINPLAY_NO_JIT AND TWINPLAY_3DS_FRONTEND)
    add_library(twinplay_3ds STATIC ${TWINPLAY_3DS_FRONTEND})
    target_link_libraries(twinplay_3ds PRIVATE citra_core video_core audio_core citra_common)
    target_include_directories(twinplay_3ds PRIVATE "${PROJECT_SOURCE_DIR}/src")
    target_compile_definitions(twinplay_3ds PRIVATE ENABLE_SOFTWARE_RENDERER)
    target_compile_features(twinplay_3ds PRIVATE cxx_std_20)
endif()
""", encoding="utf-8")
    print("patched twinplay_3ds frontend cmake target")
else:
    print("already patched twinplay_3ds frontend cmake target")

# iOS cannot import Cocoa. Teach apple_utils.mm to use UIKit.
mm = root / "src" / "common" / "apple_utils.mm"
if mm.exists():
    text = mm.read_text(encoding="utf-8")
    if "TARGET_OS_IPHONE" not in text:
        text = text.replace(
            "#import <Cocoa/Cocoa.h>\n#import <CoreGraphics/CoreGraphics.h>\n#import <Foundation/Foundation.h>\n",
            "#import <TargetConditionals.h>\n#if TARGET_OS_IPHONE\n#import <UIKit/UIKit.h>\n#import <Foundation/Foundation.h>\n#else\n#import <Cocoa/Cocoa.h>\n#import <CoreGraphics/CoreGraphics.h>\n#import <Foundation/Foundation.h>\n#endif\n",
            1,
        )
        text = text.replace(
            "float GetRefreshRate() { // TODO: How does this handle multi-monitor? -OS\n    NSScreen* screen = [NSScreen mainScreen];\n",
            "float GetRefreshRate() { // TODO: How does this handle multi-monitor? -OS\n#if TARGET_OS_IPHONE\n    return (float)[UIScreen mainScreen].maximumFramesPerSecond;\n#else\n    NSScreen* screen = [NSScreen mainScreen];\n",
            1,
        )
        text = text.replace(
            "    return 60; // Something went wrong, so just return a generic value\n}\n",
            "    return 60; // Something went wrong, so just return a generic value\n#endif\n}\n",
            1,
        )
        if "TARGET_OS_IPHONE" not in text:
            raise SystemExit("failed to patch apple_utils.mm")
        mm.write_text(text, encoding="utf-8")
        print("patched apple_utils.mm")
    else:
        print("already patched apple_utils.mm")

# Drop the shader JIT compilers (oaknut/xbyak) when TWINPLAY_NO_JIT.
vc = root / "src" / "video_core" / "CMakeLists.txt"
text = vc.read_text(encoding="utf-8")
old = """    shader/shader_interpreter.cpp
    shader/shader_interpreter.h
    shader/shader_jit.cpp
    shader/shader_jit.h
    shader/shader_jit_a64_compiler.cpp
    shader/shader_jit_a64_compiler.h
    shader/shader_jit_x64_compiler.cpp
    shader/shader_jit_x64_compiler.h
    texture/etc1.cpp
"""
new = """    shader/shader_interpreter.cpp
    shader/shader_interpreter.h
    texture/etc1.cpp
"""
if old in text:
    text = text.replace(old, new, 1)
    text = text.replace(
        "if (ENABLE_SOFTWARE_RENDERER)\n",
        "if (NOT TWINPLAY_NO_JIT)\n    target_sources(video_core PRIVATE\n        shader/shader_jit.cpp\n        shader/shader_jit.h\n        shader/shader_jit_a64_compiler.cpp\n        shader/shader_jit_a64_compiler.h\n        shader/shader_jit_x64_compiler.cpp\n        shader/shader_jit_x64_compiler.h\n    )\nendif()\n\nif (ENABLE_SOFTWARE_RENDERER)\n",
        1,
    )
    vc.write_text(text, encoding="utf-8")
    print("patched video_core shader JIT sources")
elif "shader/shader_jit.cpp" in text and "NOT TWINPLAY_NO_JIT" in text:
    print("already patched video_core shader JIT sources")
else:
    # already removed from default list?
    if "shader/shader_jit.cpp" not in text:
        print("already patched video_core shader JIT sources")
    else:
        raise SystemExit("video_core shader JIT source block not found")

sp = root / "src" / "video_core" / "shader" / "shader.cpp"
text = sp.read_text(encoding="utf-8")
text2 = text.replace(
    "#if CITRA_ARCH(x86_64) || CITRA_ARCH(arm64)\n#include \"video_core/shader/shader_jit.h\"\n#endif",
    "#if !defined(TWINPLAY_NO_JIT) && (CITRA_ARCH(x86_64) || CITRA_ARCH(arm64))\n#include \"video_core/shader/shader_jit.h\"\n#endif",
)
text2 = text2.replace(
    "#if CITRA_ARCH(x86_64) || CITRA_ARCH(arm64)\n    if (use_jit) {\n        return std::make_unique<Shader::JitEngine>();\n    }\n#endif",
    "#if !defined(TWINPLAY_NO_JIT) && (CITRA_ARCH(x86_64) || CITRA_ARCH(arm64))\n    if (use_jit) {\n        return std::make_unique<Shader::JitEngine>();\n    }\n#endif",
)
if text2 == text:
    if "TWINPLAY_NO_JIT" in text:
        print("already patched shader.cpp")
    else:
        raise SystemExit("shader.cpp patterns not found")
else:
    sp.write_text(text2, encoding="utf-8")
    print("patched shader.cpp")

# FastInterp needs arm_tick_counts even when Dynarmic is off.
cm = root / "src" / "core" / "CMakeLists.txt"
text = cm.read_text(encoding="utf-8")
old = """if (NOT TWINPLAY_NO_JIT AND ("x86_64" IN_LIST ARCHITECTURE OR "arm64" IN_LIST ARCHITECTURE))
    target_sources(citra_core PRIVATE
        arm/dynarmic/arm_dynarmic.cpp
        arm/dynarmic/arm_dynarmic.h
        arm/dynarmic/arm_dynarmic_cp15.cpp
        arm/dynarmic/arm_dynarmic_cp15.h
        arm/dynarmic/arm_exclusive_monitor.cpp
        arm/dynarmic/arm_exclusive_monitor.h
        arm/dynarmic/arm_tick_counts.cpp
        arm/dynarmic/arm_tick_counts.h
    )
    target_link_libraries(citra_core PRIVATE dynarmic)
endif()
"""
new = """# Tick counts are used by FastInterp as well as Dynarmic.
target_sources(citra_core PRIVATE
    arm/dynarmic/arm_tick_counts.cpp
    arm/dynarmic/arm_tick_counts.h
)

if (NOT TWINPLAY_NO_JIT AND ("x86_64" IN_LIST ARCHITECTURE OR "arm64" IN_LIST ARCHITECTURE))
    target_sources(citra_core PRIVATE
        arm/dynarmic/arm_dynarmic.cpp
        arm/dynarmic/arm_dynarmic.h
        arm/dynarmic/arm_dynarmic_cp15.cpp
        arm/dynarmic/arm_dynarmic_cp15.h
        arm/dynarmic/arm_exclusive_monitor.cpp
        arm/dynarmic/arm_exclusive_monitor.h
    )
    target_link_libraries(citra_core PRIVATE dynarmic)
endif()
"""
if old in text:
    cm.write_text(text.replace(old, new, 1), encoding="utf-8")
    print("patched citra_core tick_counts split")
elif "Tick counts are used by FastInterp" in text:
    print("already patched citra_core tick_counts split")
else:
    print("note: citra_core tick_counts split pattern not applied")

cp = root / "src" / "core" / "core.cpp"
text = cp.read_text(encoding="utf-8")
text2 = text.replace(
    "#if CITRA_ARCH(x86_64) || CITRA_ARCH(arm64)\n#include \"core/arm/dynarmic/arm_dynarmic.h\"\n#endif",
    "#if !defined(TWINPLAY_NO_JIT) && (CITRA_ARCH(x86_64) || CITRA_ARCH(arm64))\n#include \"core/arm/dynarmic/arm_dynarmic.h\"\n#endif",
)
text2 = text2.replace(
    "    if (Settings::values.use_cpu_jit) {\n#if CITRA_ARCH(x86_64) || CITRA_ARCH(arm64)\n",
    "    if (Settings::values.use_cpu_jit) {\n#if !defined(TWINPLAY_NO_JIT) && (CITRA_ARCH(x86_64) || CITRA_ARCH(arm64))\n",
)
if text2 == text:
    if "TWINPLAY_NO_JIT" in text and "arm_dynarmic.h" in text:
        print("already patched core.cpp")
    else:
        raise SystemExit("core.cpp patterns not found")
else:
    cp.write_text(text2, encoding="utf-8")
    print("patched core.cpp")
PY

# TwinPlay audio sink + software-renderer thread cap (idempotent).
python3 - "$ROOT" << 'PY2'
import pathlib, sys
root = pathlib.Path(sys.argv[1])

sink = root / "src" / "audio_core" / "sink_details.cpp"
st = sink.read_text(encoding="utf-8")
if "TwinPlayCreateAudioSink" in st:
    print("already patched sink_details.cpp")
else:
    old = '#include "common/logging/log.h"\n\nnamespace AudioCore {\n'
    new = (
        '#include "common/logging/log.h"\n\n'
        '#ifdef TWINPLAY_NO_JIT\n'
        'namespace AudioCore { class Sink; }\n'
        'std::unique_ptr<AudioCore::Sink> TwinPlayCreateAudioSink(std::string_view device_id);\n'
        '#endif\n\n'
        'namespace AudioCore {\n'
    )
    if old not in st:
        raise SystemExit("sink_details.cpp includes not found")
    st = st.replace(old, new, 1)
    oldf = (
        '    SinkDetails{SinkType::Null, "None",\n'
        '                [](std::string_view device_id) -> std::unique_ptr<Sink> {\n'
        '                    return std::make_unique<NullSink>(device_id);\n'
        '                },\n'
    )
    newf = (
        '    SinkDetails{SinkType::Null, "None",\n'
        '                [](std::string_view device_id) -> std::unique_ptr<Sink> {\n'
        '#ifdef TWINPLAY_NO_JIT\n'
        '                    if (auto custom = TwinPlayCreateAudioSink(device_id))\n'
        '                        return custom;\n'
        '#endif\n'
        '                    return std::make_unique<NullSink>(device_id);\n'
        '                },\n'
    )
    if oldf not in st:
        raise SystemExit("Null sink factory not found")
    sink.write_text(st.replace(oldf, newf, 1), encoding="utf-8")
    print("patched sink_details.cpp TwinPlay sink")

sw = root / "src" / "video_core" / "renderer_software" / "sw_rasterizer.cpp"
swt = sw.read_text(encoding="utf-8")
if "TWINPLAY_NO_JIT" in swt and "num_sw_threads" in swt:
    print("already patched sw_rasterizer.cpp threads")
else:
    old = "      num_sw_threads{std::max(std::thread::hardware_concurrency(), 2U)},"
    new = (
        "#ifdef TWINPLAY_NO_JIT\n"
        "      num_sw_threads{2U},\n"
        "#else\n"
        "      num_sw_threads{std::max(std::thread::hardware_concurrency(), 2U)},\n"
        "#endif"
    )
    if old not in swt:
        raise SystemExit("sw_rasterizer thread init not found")
    sw.write_text(swt.replace(old, new, 1), encoding="utf-8")
    print("patched sw_rasterizer.cpp thread cap")
PY2


# iOS statically links MoltenVK; teach OpenLibrary to look up symbols in the process.
python3 - "$ROOT" << 'PYMVK'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
p = root / "src/video_core/renderer_vulkan/vk_platform.cpp"
if not p.exists():
    print("note: vk_platform.cpp missing")
    raise SystemExit(0)
text = p.read_text(encoding="utf-8")
if "Vulkan symbols are in the process image" in text:
    print("already patched vk_platform.cpp OpenLibrary")
else:
    old = """#ifdef __APPLE__
    const std::string filename = Common::DynamicLibrary::GetLibraryName(\"vulkan\");
    if (!library->Load(filename)) {
        // Fall back to directly loading bundled MoltenVK library.
        const std::string mvk_filename = Common::DynamicLibrary::GetLibraryName(\"MoltenVK\");
        void(library->Load(mvk_filename));
    }
#else
"""
    new = """#ifdef __APPLE__
    const std::string filename = Common::DynamicLibrary::GetLibraryName(\"vulkan\");
    if (!library->Load(filename)) {
        // Fall back to directly loading bundled MoltenVK library.
        const std::string mvk_filename = Common::DynamicLibrary::GetLibraryName(\"MoltenVK\");
        if (!library->Load(mvk_filename)) {
            // iOS links MoltenVK statically; Vulkan symbols are in the process image.
            library = std::make_shared<Common::DynamicLibrary>(dlopen(nullptr, RTLD_LAZY));
        }
    }
#else
"""
    if old not in text:
        print("note: OpenLibrary Apple block not found")
    else:
        text = text.replace(old, new, 1)
        if "#include <dlfcn.h>" not in text:
            text = text.replace("#include <memory>\\n", "#include <memory>\\n#if defined(__APPLE__)\\n#include <dlfcn.h>\\n#endif\\n", 1)
        p.write_text(text, encoding="utf-8")
        print("patched vk_platform.cpp OpenLibrary")
PYMVK
