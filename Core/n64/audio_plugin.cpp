/* TwinPlay N64 audio plugin. GPL-2.0-or-later, because it implements the Mupen64Plus plugin API.
   Samples are handed to the frontend (twinplay_n64_push_samples) which resamples to 48 kHz.

   Mupen stores RDRAM in host (little-endian) byte order. Each AI DMA word is two 16-bit PCM
   samples with the left and right channels swapped (right, then left). Treating those bytes as
   big-endian, or leaving L/R unswapped, turns the stream into loud static. */
#define M64P_PLUGIN_PROTOTYPES
#include "m64p_common.h"
#include "m64p_plugin.h"
#include "m64p_types.h"
#include <dlfcn.h>
#include <stdint.h>
#include <string.h>

static AUDIO_INFO g_ai;
static void (*g_push)(const int16_t*, int, int) = 0;
static int g_rate = 32000;

enum { kRdramBytes = 0x800000 };
enum { kMaxFrames = 16384 };

static void resolve(void) {
    if (g_push) return;
    g_push = (void (*)(const int16_t*, int, int))dlsym(RTLD_DEFAULT, "twinplay_n64_push_samples");
    if (!g_push) {
        void* h = dlopen(NULL, RTLD_LAZY);
        if (h) g_push = (void (*)(const int16_t*, int, int))dlsym(h, "twinplay_n64_push_samples");
    }
}

EXPORT m64p_error CALL PluginGetVersion(m64p_plugin_type* type, int* version, int* api, const char** name, int* caps) {
    if (type) *type = M64PLUGIN_AUDIO;
    if (version) *version = 0x00010000;
    if (api) *api = 0x020000;
    if (name) *name = "TwinPlay N64 audio";
    if (caps) *caps = 0;
    return M64ERR_SUCCESS;
}
EXPORT m64p_error CALL PluginStartup(m64p_dynlib_handle c, void* ctx, void (*dbg)(void*, int, const char*)) {
    (void)c; (void)ctx; (void)dbg; resolve(); return M64ERR_SUCCESS;
}
EXPORT m64p_error CALL PluginShutdown(void) { return M64ERR_SUCCESS; }
EXPORT int CALL RomOpen(void) { resolve(); return 1; }
EXPORT void CALL RomClosed(void) {}
static int g_system = 0; /* SYSTEM_NTSC=0, SYSTEM_PAL=1, SYSTEM_MPAL=2 */

static int current_rate(void) {
    const int clock = g_system == 1 ? 49656530 : g_system == 2 ? 48628316 : 48681812;
    const unsigned dac = g_ai.AI_DACRATE_REG ? *g_ai.AI_DACRATE_REG : 0;
    if (dac == 0) return g_rate > 0 ? g_rate : 32000;
    const int rate = clock / (int)(dac + 1u);
    return (rate < 8000 || rate > 96000) ? 32000 : rate;
}

EXPORT void CALL AiDacrateChanged(int system_type) {
    /* Clocks match Mupen's VI_*_CLOCK. */
    g_system = system_type;
    g_rate = current_rate();
}
EXPORT void CALL AiLenChanged(void) {
    resolve();
    if (!g_push || !g_ai.RDRAM || !g_ai.AI_LEN_REG || !g_ai.AI_DRAM_ADDR_REG) return;
    g_rate = current_rate();
    /* AI_LEN is 18 bits, 8-byte aligned. AI_DRAM_ADDR is a 24-bit RDRAM pointer. */
    unsigned len = *g_ai.AI_LEN_REG & 0x3FFF8u;
    const unsigned addr = *g_ai.AI_DRAM_ADDR_REG & 0xFFFFFFu;
    if (len == 0) return;
    if (addr >= kRdramBytes) return;
    if (len > kRdramBytes - addr) len = kRdramBytes - addr;
    len &= ~3u;
    if (len == 0) return;
    int16_t tmp[kMaxFrames * 2];
    int frames = (int)(len / 4);
    if (frames > kMaxFrames) frames = kMaxFrames;
    for (int i = 0; i < frames; ++i) {
        const unsigned o = addr + (unsigned)i * 4;
        /* Host-endian 16-bit samples, L/R swapped in each 32-bit word. */
        const int16_t right = (int16_t)((uint16_t)g_ai.RDRAM[o] | ((uint16_t)g_ai.RDRAM[o + 1] << 8));
        const int16_t left  = (int16_t)((uint16_t)g_ai.RDRAM[o + 2] | ((uint16_t)g_ai.RDRAM[o + 3] << 8));
        tmp[i * 2] = left;
        tmp[i * 2 + 1] = right;
    }
    g_push(tmp, frames, g_rate);
}
EXPORT int CALL InitiateAudio(AUDIO_INFO info) { g_ai = info; resolve(); return 1; }
EXPORT void CALL ProcessAList(void) {}
EXPORT void CALL SetSpeedFactor(int p) { (void)p; }
EXPORT void CALL VolumeUp(void) {}
EXPORT void CALL VolumeDown(void) {}
EXPORT int CALL VolumeGetLevel(void) { return 100; }
EXPORT void CALL VolumeSetLevel(int level) { (void)level; }
EXPORT void CALL VolumeMute(void) {}
EXPORT const char* CALL VolumeGetString(void) { return "100%"; }
