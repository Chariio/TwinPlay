/* Stub used until Azahar is linked by scripts/build-n64-3ds.sh. */
#include <string.h>
int twinplay_3ds_available(void) { return 0; }
void twinplay_3ds_set_data_dir(const char* d) { (void)d; }
void twinplay_3ds_set_save_dir(const char* d) { (void)d; }
int twinplay_3ds_load(const char* p, char* err, int err_len) {
    (void)p;
    const char* m = "3DS core not linked";
    if (err && err_len > 0) { strncpy(err, m, (size_t)err_len - 1); err[err_len - 1] = 0; }
    return -1;
}
void twinplay_3ds_unload(void) {}
void twinplay_3ds_reset(void) {}
void twinplay_3ds_run_frame(void) {}
void twinplay_3ds_set_input(unsigned b, float cx, float cy, float sx, float sy, int t, int x, int y) {
    (void)b; (void)cx; (void)cy; (void)sx; (void)sy; (void)t; (void)x; (void)y;
}
int twinplay_3ds_copy_frame(int s, unsigned* d, int c, int* w, int* h) {
    (void)s; (void)d; (void)c; if (w) *w = 0; if (h) *h = 0; return 0;
}
int twinplay_3ds_read_audio(short* d, int n) { (void)d; (void)n; return 0; }
int twinplay_3ds_save_state(unsigned char* d, int c) { (void)d; (void)c; return -1; }
int twinplay_3ds_load_state(const unsigned char* s, int n) { (void)s; (void)n; return -1; }
