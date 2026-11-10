#!/usr/bin/env python3
"""Make the Mupen frontend find iOS dylibs and not use Linux-only RTLD_DEEPBIND."""
from pathlib import Path
import sys
p = Path(sys.argv[1] if len(sys.argv) > 1 else "Core/n64/twinplay_n64.cpp")
t = p.read_text()
if "TWINPLAY_DEEPBIND" in t:
    print(f"already patched {p}")
    raise SystemExit(0)

old_open = '''    void* h = dlopen(path.c_str(), RTLD_NOW | RTLD_DEEPBIND);
    if (!h) std::fprintf(stderr, "TwinPlay N64: %s (%s)\\n", path.c_str(), dlerror());
    return h;
'''
new_open = '''    int flags = RTLD_NOW;
#ifdef RTLD_DEEPBIND
    flags |= RTLD_DEEPBIND;
#endif
    void* h = dlopen(path.c_str(), flags);
    if (!h && !g_plugins.empty()) {
        const auto slash = g_plugins.find_last_of('/');
        if (slash != std::string::npos) {
#ifdef __APPLE__
            const std::string alt = g_plugins.substr(0, slash) + "/Frameworks/" + name + ".dylib";
#else
            const std::string alt = g_plugins.substr(0, slash) + "/Frameworks/" + name + ".so";
#endif
            h = dlopen(alt.c_str(), flags);
        }
    }
    if (!h) std::fprintf(stderr, "TwinPlay N64: %s (%s)\\n", path.c_str(), dlerror());
    return h;
'''
if old_open not in t:
    raise SystemExit("open_one dlopen block not found")
t = t.replace(old_open, new_open, 1)

old_core = '''    const std::string core_path = g_plugins + "/libmupen64plus.so.2";
    g_core = dlopen(core_path.c_str(), RTLD_NOW | RTLD_GLOBAL);
    if (!g_core) {
        std::string msg = std::string("Could not load Mupen64Plus (") + dlerror() + ").";
        return fail(msg.c_str());
    }
'''
new_core = '''    auto try_core = [&](const std::string& dir, const char* file) {
        if (dir.empty()) return false;
        g_core = dlopen((dir + "/" + file).c_str(), RTLD_NOW | RTLD_GLOBAL);
        return g_core != nullptr;
    };
    const char* core_names[] = {
#ifdef __APPLE__
        "libmupen64plus.dylib", "libmupen64plus.so.2",
#else
        "libmupen64plus.so.2", "libmupen64plus.dylib",
#endif
        nullptr
    };
    for (int i = 0; core_names[i] && !g_core; ++i) try_core(g_plugins, core_names[i]);
    if (!g_core && !g_plugins.empty()) {
        const auto slash = g_plugins.find_last_of('/');
        if (slash != std::string::npos) {
            const std::string fw = g_plugins.substr(0, slash) + "/Frameworks";
            for (int i = 0; core_names[i] && !g_core; ++i) try_core(fw, core_names[i]);
        }
    }
    if (!g_core) {
        std::string msg = std::string("Could not load Mupen64Plus (") + (dlerror() ? dlerror() : "not found") + ").";
        return fail(msg.c_str());
    }
'''
if old_core not in t:
    raise SystemExit("core dlopen block not found")
t = t.replace(old_core, new_core, 1)
p.write_text(t)
print(f"patched {p}")
