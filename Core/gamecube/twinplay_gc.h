/* Copyright (c) 2026 Charlie Rodriguez Garcia.
   SPDX-License-Identifier: GPL-3.0-or-later
   TwinPlay's C ABI over Dolphin. The default build links the stub in
   twinplay_gc_stub.cpp. scripts/build-dolphin.sh compiles twinplay_gc_host.cpp
   against Dolphin (GPL-2.0-or-later) to prove the real call path. */
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 1 when this binary is the Dolphin host, 0 for the stub. */
int twinplay_gc_available(void);
/* "JITARM64" on the Mac host, "Cached Interpreter" on the iOS host, "not linked" for the stub. */
const char* twinplay_gc_cpu_name(void);
/* Video backend the host asks Dolphin to use. Always "Metal" for the real host. */
const char* twinplay_gc_backend_name(void);
/* 1 only for the Mac JIT host. The iOS host and the stub return 0. */
int twinplay_gc_uses_jit(void);

/* Dolphin user directory (memory cards, shader cache). Never a ROM or IPL. */
void twinplay_gc_set_user_dir(const char* dir);

/* 0 on success. err receives a short English message. */
int twinplay_gc_load_path(const char* path, char* err, int err_len);
void twinplay_gc_unload(void);
void twinplay_gc_reset(void);
/* Host thread pump. The CPU thread is Dolphin's; this drains host jobs. */
void twinplay_gc_run_frame(void);
void twinplay_gc_set_paused(int paused);

/* buttons: dscore::Button bits. Sticks are -1..1 (main, then C-stick). */
void twinplay_gc_set_input(uint32_t buttons, float stick_x, float stick_y, float c_x, float c_y);

/* BGRA8. Returns pixels copied, or 0 when no frame is available yet.
   w and h may be null. */
int twinplay_gc_copy_frame(uint32_t* dst, int cap, int* w, int* h);
/* Interleaved stereo s16 at 48 kHz. Returns frames copied. */
int twinplay_gc_read_audio(int16_t* dst, int max_frames);

#ifdef __cplusplus
}
#endif
