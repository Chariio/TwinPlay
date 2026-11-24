// Stub used by the host unit tests and by app builds that have not run
// scripts/build-flycast.sh. The real host is twinplay_flycast_host.mm.
#include "twinplay_flycast.h"
#include <string.h>

int twinplay_dc_available(void) { return 0; }
const char* twinplay_dc_cpu_mode(void) { return "interpreter"; }
const char* twinplay_dc_renderer(void) { return "none"; }
void twinplay_dc_set_dirs(const char* d, const char* s) { (void)d; (void)s; }
void twinplay_dc_set_hle(int h) { (void)h; }
int twinplay_dc_load(const char* path, char* err, int err_len) {
    (void)path;
    const char* m = "Dreamcast core not linked. On a Mac, run scripts/build-flycast.sh and rebuild.";
    if (err && err_len > 0) {
        strncpy(err, m, (size_t)err_len - 1);
        err[err_len - 1] = 0;
    }
    return -1;
}
void twinplay_dc_unload(void) {}
void twinplay_dc_reset(void) {}
void twinplay_dc_run_frame(void) {}
void twinplay_dc_set_input(uint32_t b, float x, float y, float l, float r) {
    (void)b; (void)x; (void)y; (void)l; (void)r;
}
int twinplay_dc_copy_frame(uint32_t* d, int c, int* w, int* h) {
    (void)d; (void)c; if (w) *w = 0; if (h) *h = 0; return 0;
}
int twinplay_dc_read_audio(int16_t* d, int n) { (void)d; (void)n; return 0; }
int twinplay_dc_save_state(uint8_t* d, int c) { (void)d; (void)c; return 0; }
int twinplay_dc_load_state(const uint8_t* s, int n) { (void)s; (void)n; return -1; }
void twinplay_dc_title(char* d, int c) { if (d && c > 0) d[0] = 0; }
