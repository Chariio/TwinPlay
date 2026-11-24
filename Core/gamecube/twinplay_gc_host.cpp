/* Copyright (c) 2026 Dolphin Emulator Project and Charlie Rodriguez Garcia.
   SPDX-License-Identifier: GPL-2.0-or-later
   This file is a derivative of Dolphin: it calls Dolphin's core. It is
   GPL-2.0-or-later and is compiled only by scripts/build-dolphin.sh, against
   a checkout of https://github.com/dolphin-emu/dolphin at the pin in
   Core/third_party/dolphin-pin.txt. It is not part of the default Xcode
   sources (those link twinplay_gc_stub.cpp).

   Mac  (no TWINPLAY_GC_IOS): ARM64 JIT, Metal. Dolphin's normal desktop CPU.
   iOS  (TWINPLAY_GC_IOS):    cached interpreter, no JIT, Metal, dual core,
                              backend multithreading, native resolution, the
                              safe speed path (EFB to texture, immediate XFB,
                              skip duplicate XFBs, idle skipping). No StikDebug.
                              Fast-math is not used; it miscompiles this CPU. */
#include "twinplay_gc.h"

#include <cstring>
#include <string>

#include "Common/Config/Config.h"
#include "Common/WindowSystemInfo.h"
#include "Core/Boot/Boot.h"
#include "Core/BootManager.h"
#include "Core/Config/GraphicsSettings.h"
#include "Core/Config/MainSettings.h"
#include "Core/Core.h"
#include "Core/PowerPC/PowerPC.h"
#include "Core/System.h"
#include "DiscIO/Enums.h"
#include "DiscIO/Volume.h"
#include "UICommon/UICommon.h"
#include "VideoBackends/Metal/VideoBackend.h"

namespace {

bool g_ui = false;
bool g_booted = false;
std::string g_user_dir;

void set_err(char* err, int err_len, const char* msg) {
    if (!err || err_len <= 0) return;
    std::strncpy(err, msg, static_cast<size_t>(err_len - 1));
    err[err_len - 1] = 0;
}

template <typename T>
void set_both(const Config::Info<T>& info, const T& value) {
    Config::SetBase(info, value);
    Config::SetCurrent(info, value);
}

void configure() {
#ifdef TWINPLAY_GC_IOS
    /* Best JIT-less path. CachedInterpreter is the only fast CPU once
       ENABLE_GENERIC has left the ARM64 JIT out of the binary. */
    set_both(Config::MAIN_CPU_CORE, PowerPC::CPUCore::CachedInterpreter);
    set_both(Config::MAIN_FASTMEM, false);
    set_both(Config::MAIN_CPU_THREAD, true); /* dual core: CPU thread + GPU thread */
    set_both(Config::GFX_BACKEND_MULTITHREADING, true);
    set_both(Config::GFX_EFB_SCALE, 1); /* native resolution. Higher IR does not help this CPU. */
    set_both(Config::GFX_HACK_SKIP_EFB_COPY_TO_RAM, true);
    set_both(Config::GFX_HACK_IMMEDIATE_XFB, true);
    set_both(Config::GFX_HACK_SKIP_DUPLICATE_XFBS, true);
    set_both(Config::MAIN_SYNC_ON_SKIP_IDLE, true);
#else
    set_both(Config::MAIN_CPU_CORE, PowerPC::CPUCore::JITARM64);
    set_both(Config::MAIN_FASTMEM, true);
    /* Desktop default. Dual core costs RAM; an 8 GB Mac is already tight. */
    set_both(Config::MAIN_CPU_THREAD, false);
#endif
    set_both(Config::MAIN_GFX_BACKEND, std::string(Metal::VideoBackend::CONFIG_NAME));
    set_both(Config::MAIN_DSP_HLE, true); /* no dsp_rom.bin bundled or required */
    set_both(Config::MAIN_SKIP_IPL, true); /* no IPL / BIOS bundled or required */
    set_both(Config::MAIN_OVERCLOCK_ENABLE, false);
    set_both(Config::MAIN_VI_OVERCLOCK_ENABLE, false);
}

bool reject_wii(const std::string& path, char* err, int err_len) {
    std::unique_ptr<DiscIO::Volume> volume = DiscIO::CreateVolume(path);
    if (!volume) return false; /* RVZ/ZIP readers still boot through Dolphin. */
    const DiscIO::Platform kind = volume->GetVolumeType();
    if (kind == DiscIO::Platform::WiiDisc || kind == DiscIO::Platform::WiiWAD) {
        set_err(err, err_len, "This is a Wii game. TwinPlay plays GameCube games only.");
        return true;
    }
    return false;
}

}  // namespace

extern "C" int twinplay_gc_available(void) { return 1; }

extern "C" const char* twinplay_gc_cpu_name(void) {
#ifdef TWINPLAY_GC_IOS
    return "Cached Interpreter";
#else
    return "JITARM64";
#endif
}

extern "C" const char* twinplay_gc_backend_name(void) { return "Metal"; }

extern "C" int twinplay_gc_uses_jit(void) {
#ifdef TWINPLAY_GC_IOS
    return 0;
#else
    return 1;
#endif
}

extern "C" void twinplay_gc_set_user_dir(const char* dir) { g_user_dir = dir ? dir : ""; }

extern "C" int twinplay_gc_load_path(const char* path, char* err, int err_len) {
    if (!path || !path[0]) {
        set_err(err, err_len, "No GameCube game was selected.");
        return -1;
    }
    if (reject_wii(path, err, err_len)) return -1;

    if (!g_ui) {
        UICommon::SetUserDirectory(g_user_dir);
        UICommon::Init();
        g_ui = true;
    } else if (!g_user_dir.empty()) {
        UICommon::SetUserDirectory(g_user_dir);
    }
    configure();

    WindowSystemInfo wsi;
    wsi.type = WindowSystemType::Headless;
    UICommon::InitControllers(wsi);

    std::unique_ptr<BootParameters> boot = BootParameters::GenerateFromFile(std::string(path));
    if (!boot) {
        set_err(err, err_len, "Dolphin could not read this game. Use .iso, .gcm, .rvz, .ciso, .gcz or .zip.");
        return -1;
    }
    if (!BootManager::BootCore(Core::System::GetInstance(), std::move(boot), wsi)) {
        set_err(err, err_len, "Dolphin could not boot this game.");
        return -1;
    }
    g_booted = true;
    return 0;
}

extern "C" void twinplay_gc_unload(void) {
    if (!g_booted && !g_ui) return;
    Core::System& system = Core::System::GetInstance();
    if (g_booted) {
        Core::Stop(system);
        Core::Shutdown(system);
        BootManager::RestoreConfig();
        g_booted = false;
    }
    if (g_ui) {
        UICommon::ShutdownControllers();
        UICommon::Shutdown();
        g_ui = false;
    }
}

extern "C" void twinplay_gc_reset(void) {
    /* Dolphin restart is a fresh BootCore. Not wired; Stop() would leave the
       session with no core. The in-game Restart item is a no-op until then. */
}

extern "C" void twinplay_gc_run_frame(void) {
    if (!g_booted) return;
    Core::HostDispatchJobs(Core::System::GetInstance());
}

extern "C" void twinplay_gc_set_paused(int paused) {
    if (!g_booted) return;
    Core::SetState(Core::System::GetInstance(),
                   paused ? Core::State::Paused : Core::State::Running);
}

extern "C" void twinplay_gc_set_input(uint32_t, float, float, float, float) {
    /* Pad injection into Dolphin's GC controller is not wired yet.
       The library, boot path and CPU/GPU settings are. See docs/GAMECUBE.md. */
}

extern "C" int twinplay_gc_copy_frame(uint32_t*, int, int* w, int* h) {
    /* Dolphin draws on its own Metal thread. Copying that drawable back into
       TwinPlay's 256x192 presenter is not wired; headless has no CAMetalLayer. */
    if (w) *w = 0;
    if (h) *h = 0;
    return 0;
}

extern "C" int twinplay_gc_read_audio(int16_t*, int) { return 0; }
