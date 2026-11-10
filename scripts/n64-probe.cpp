// Opens a 4 KB stand-in header through the linked N64 stack. Not a game.
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
extern "C" {
int twinplay_n64_available(void);
void twinplay_n64_set_plugin_dir(const char*);
void twinplay_n64_set_save_dir(const char*);
int twinplay_n64_load(const uint8_t*, int, char*, int);
void twinplay_n64_unload(void);
}
int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: n64probe <plugin dir>\n"); return 2; }
    if (!twinplay_n64_available()) { std::fprintf(stderr, "frontend missing\n"); return 2; }
    twinplay_n64_set_plugin_dir(argv[1]);
    twinplay_n64_set_save_dir(argv[1]);
    std::vector<uint8_t> rom(4096, 0);
    rom[0] = 0x80; rom[1] = 0x37; rom[2] = 0x12; rom[3] = 0x40;
    std::memcpy(rom.data() + 0x20, "PROBE               ", 20);
    char err[512] = {};
    const int rc = twinplay_n64_load(rom.data(), (int)rom.size(), err, (int)sizeof err);
    std::printf("n64 probe load %d %s\n", rc, err);
    twinplay_n64_unload();
    return rc == 0 ? 0 : 1;
}
