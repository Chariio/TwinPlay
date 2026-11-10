/* TwinPlay N64 input plugin. GPL-2.0-or-later, because it implements the Mupen64Plus plugin API.
   Pad state is read from the frontend (twinplay_n64_read_pad). */
#define M64P_PLUGIN_PROTOTYPES
#include "m64p_common.h"
#include "m64p_plugin.h"
#include "m64p_types.h"
#include <dlfcn.h>
#include <stdint.h>

static void (*g_read)(int, uint32_t*) = 0;

static void resolve(void) {
    if (!g_read) g_read = (void (*)(int, uint32_t*))dlsym(RTLD_DEFAULT, "twinplay_n64_read_pad");
}

EXPORT m64p_error CALL PluginGetVersion(m64p_plugin_type* type, int* version, int* api, const char** name, int* caps) {
    if (type) *type = M64PLUGIN_INPUT;
    if (version) *version = 0x00010000;
    if (api) *api = 0x020101;
    if (name) *name = "TwinPlay N64 input";
    if (caps) *caps = 0;
    return M64ERR_SUCCESS;
}
EXPORT m64p_error CALL PluginStartup(m64p_dynlib_handle c, void* ctx, void (*dbg)(void*, int, const char*)) {
    (void)c; (void)ctx; (void)dbg; return M64ERR_SUCCESS;
}
EXPORT m64p_error CALL PluginShutdown(void) { return M64ERR_SUCCESS; }
EXPORT int CALL RomOpen(void) { return 1; }
EXPORT void CALL RomClosed(void) {}
EXPORT void CALL ControllerCommand(int control, unsigned char* cmd) { (void)control; (void)cmd; }
EXPORT void CALL GetKeys(int control, BUTTONS* keys) {
    resolve();
    keys->Value = 0;
    if (control != 0 || !g_read) return;
    uint32_t word = 0;
    g_read(control, &word);
    keys->Value = word;
}
EXPORT void CALL InitiateControllers(CONTROL_INFO info) {
    if (!info.Controls) return;
    info.Controls[0].Present = 1;
    info.Controls[0].RawData = 0;
    info.Controls[0].Plugin = PLUGIN_NONE;
    info.Controls[0].Type = CONT_TYPE_STANDARD;
    for (int i = 1; i < 4; ++i) info.Controls[i].Present = 0;
}
EXPORT void CALL ReadController(int control, unsigned char* cmd) { (void)control; (void)cmd; }
EXPORT void CALL SDL_KeyDown(int mod, int sym) { (void)mod; (void)sym; }
EXPORT void CALL SDL_KeyUp(int mod, int sym) { (void)mod; (void)sym; }
