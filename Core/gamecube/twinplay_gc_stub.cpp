/* Copyright (c) 2026 Charlie Rodriguez Garcia.
   SPDX-License-Identifier: GPL-3.0-or-later
   Stub used until scripts/build-dolphin.sh has produced the Dolphin host.
   No Dolphin code is included in this file. No JIT. */
#include "twinplay_gc.h"

#include <cstring>

static void set_err(char* err, int err_len, const char* msg) {
    if (!err || err_len <= 0) return;
    std::strncpy(err, msg, static_cast<size_t>(err_len - 1));
    err[err_len - 1] = 0;
}

extern "C" int twinplay_gc_available(void) { return 0; }

extern "C" const char* twinplay_gc_cpu_name(void) { return "not linked"; }

extern "C" const char* twinplay_gc_backend_name(void) { return "Metal"; }

extern "C" int twinplay_gc_uses_jit(void) { return 0; }

extern "C" void twinplay_gc_set_user_dir(const char*) {}

extern "C" int twinplay_gc_load_path(const char*, char* err, int err_len) {
    set_err(err, err_len,
            "The GameCube core is not linked into this build. On a Mac, run scripts/build-dolphin.sh and rebuild.");
    return -1;
}

extern "C" void twinplay_gc_unload(void) {}
extern "C" void twinplay_gc_reset(void) {}
extern "C" void twinplay_gc_run_frame(void) {}
extern "C" void twinplay_gc_set_paused(int) {}
extern "C" void twinplay_gc_set_input(uint32_t, float, float, float, float) {}
extern "C" int twinplay_gc_copy_frame(uint32_t*, int, int* w, int* h) {
    if (w) *w = 0;
    if (h) *h = 0;
    return 0;
}
extern "C" int twinplay_gc_read_audio(int16_t*, int) { return 0; }
