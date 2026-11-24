// Copyright (c) 2026 Charlie Rodriguez Garcia.
// TwinPlay's in-process host for the Flycast libretro core (GPL-2.0-or-later).
// The core itself is fetched and built by scripts/build-flycast.sh. It is not
// committed, and neither are BIOS files or games.
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// 1 when flycast_libretro was loaded. 0 when this is the stub or the dylib is missing.
int twinplay_dc_available(void);
// "interpreter" on iOS (TARGET_NO_REC, no dynarec) and "dynarec" on macOS.
const char* twinplay_dc_cpu_mode(void);
// "opengl-es" or "opengl". Frames are copied out for TwinPlay's Metal presenter.
const char* twinplay_dc_renderer(void);

// data_dir is where Flycast looks for dc_boot.bin / dc_nvmem.bin (HLE if absent).
// save_dir is unused by the libretro Apple path (saves follow data_dir); kept for the core API.
void twinplay_dc_set_dirs(const char* data_dir, const char* save_dir);
// hle != 0 forces Flycast's HLE BIOS (the default). 0 uses dc_boot.bin when present.
void twinplay_dc_set_hle(int hle);

int twinplay_dc_load(const char* path, char* err, int err_len);
void twinplay_dc_unload(void);
void twinplay_dc_reset(void);
void twinplay_dc_run_frame(void);
// buttons: dscore::Button bits. ax/ay are -1..1 (Y positive up). lt/rt are 0..1 triggers.
void twinplay_dc_set_input(uint32_t buttons, float ax, float ay, float lt, float rt);
int twinplay_dc_copy_frame(uint32_t* dst, int cap, int* w, int* h);
// Stereo int16 at 48000 Hz (resampled from Flycast's rate).
int twinplay_dc_read_audio(int16_t* dst, int max_frames);
int twinplay_dc_save_state(uint8_t* dst, int cap);
int twinplay_dc_load_state(const uint8_t* src, int size);
void twinplay_dc_title(char* dst, int cap);

#ifdef __cplusplus
}
#endif
