/* Stub used when scripts/build-n64-3ds.sh has not linked Mupen64Plus yet.
   The real implementation is Core/n64/twinplay_n64.cpp. */
#include <string.h>
int twinplay_n64_available(void) { return 0; }
void twinplay_n64_set_plugin_dir(const char* d) { (void)d; }
void twinplay_n64_set_save_dir(const char* d) { (void)d; }
int twinplay_n64_load(const unsigned char* r, int n, char* err, int err_len) {
    (void)r; (void)n;
    const char* m = "N64 core not linked";
    if (err && err_len > 0) { strncpy(err, m, (size_t)err_len - 1); err[err_len - 1] = 0; }
    return -1;
}
void twinplay_n64_unload(void) {}
void twinplay_n64_reset(void) {}
void twinplay_n64_run_frame(void) {}
void twinplay_n64_set_input(unsigned buttons, float x, float y) { (void)buttons; (void)x; (void)y; }
int twinplay_n64_copy_frame(unsigned* dst, int cap, int* w, int* h) { (void)dst; (void)cap; if (w) *w = 0; if (h) *h = 0; return 0; }
int twinplay_n64_read_audio(short* dst, int n) { (void)dst; (void)n; return 0; }
int twinplay_n64_save_state(unsigned char* d, int c) { (void)d; (void)c; return -1; }
int twinplay_n64_load_state(const unsigned char* s, int n) { (void)s; (void)n; return -1; }
void twinplay_n64_title(char* d, int c) { if (d && c > 0) d[0] = 0; }
