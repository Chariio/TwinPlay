/* Desktop/Linux video extension: an offscreen OpenGL context. GLideN64 renders into it
   and SwapBuffers copies the picture back to the frontend. No window is shown.
   GPL-2.0-or-later (Mupen64Plus video-extension API). */
#include "m64p_types.h"
#include <EGL/egl.h>
#include <GL/gl.h>
#include <cstdint>
#include <cstring>
#include <vector>

extern "C" void twinplay_n64_store_frame(const uint32_t* bgra, int w, int h);

static EGLDisplay g_dpy = EGL_NO_DISPLAY;
static EGLContext g_ctx = EGL_NO_CONTEXT;
static EGLSurface g_surf = EGL_NO_SURFACE;
static int g_w = 640, g_h = 480;
static int g_major = 3, g_minor = 3, g_profile = M64P_GL_CONTEXT_PROFILE_COMPATIBILITY;
static std::vector<uint32_t> g_pix;

static void read_back(void) {
    if (g_w <= 0 || g_h <= 0 || g_w > 1920 || g_h > 1080) return;
    std::vector<uint8_t> raw(size_t(g_w) * size_t(g_h) * 4);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, g_w, g_h, GL_RGBA, GL_UNSIGNED_BYTE, raw.data());
    g_pix.resize(size_t(g_w) * size_t(g_h));
    for (int y = 0; y < g_h; ++y) {
        const uint8_t* src = raw.data() + size_t(g_h - 1 - y) * size_t(g_w) * 4;
        uint32_t* dst = g_pix.data() + size_t(y) * size_t(g_w);
        for (int x = 0; x < g_w; ++x) {
            const uint8_t r = src[x * 4], g = src[x * 4 + 1], b = src[x * 4 + 2], a = src[x * 4 + 3];
            dst[x] = (uint32_t(a) << 24) | (uint32_t(r) << 16) | (uint32_t(g) << 8) | b;
        }
    }
    twinplay_n64_store_frame(g_pix.data(), g_w, g_h);
}

static m64p_error init_common(void) {
    if (g_dpy != EGL_NO_DISPLAY) return M64ERR_SUCCESS;
    g_dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (g_dpy == EGL_NO_DISPLAY) return M64ERR_SYSTEM_FAIL;
    if (!eglInitialize(g_dpy, nullptr, nullptr)) return M64ERR_SYSTEM_FAIL;
    return M64ERR_SUCCESS;
}

static m64p_error make_surface(int w, int h) {
    if (w < 1) w = 640;
    if (h < 1) h = 480;
    g_w = w; g_h = h;
    if (init_common() != M64ERR_SUCCESS) return M64ERR_SYSTEM_FAIL;
    eglBindAPI(EGL_OPENGL_API);
    const EGLint cfg_attr[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 24, EGL_NONE
    };
    EGLConfig cfg = nullptr; EGLint n = 0;
    if (!eglChooseConfig(g_dpy, cfg_attr, &cfg, 1, &n) || n < 1) return M64ERR_SYSTEM_FAIL;
    const EGLint ctx_attr[] = {
        EGL_CONTEXT_MAJOR_VERSION, g_major,
        EGL_CONTEXT_MINOR_VERSION, g_minor,
        EGL_CONTEXT_OPENGL_PROFILE_MASK,
        g_profile == M64P_GL_CONTEXT_PROFILE_CORE ? EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT
                                                  : EGL_CONTEXT_OPENGL_COMPATIBILITY_PROFILE_BIT,
        EGL_NONE
    };
    if (g_ctx == EGL_NO_CONTEXT) {
        g_ctx = eglCreateContext(g_dpy, cfg, EGL_NO_CONTEXT, ctx_attr);
        if (g_ctx == EGL_NO_CONTEXT) g_ctx = eglCreateContext(g_dpy, cfg, EGL_NO_CONTEXT, nullptr);
        if (g_ctx == EGL_NO_CONTEXT) return M64ERR_SYSTEM_FAIL;
    }
    if (g_surf != EGL_NO_SURFACE) eglDestroySurface(g_dpy, g_surf);
    const EGLint pb[] = { EGL_WIDTH, w, EGL_HEIGHT, h, EGL_NONE };
    g_surf = eglCreatePbufferSurface(g_dpy, cfg, pb);
    if (g_surf == EGL_NO_SURFACE) return M64ERR_SYSTEM_FAIL;
    if (!eglMakeCurrent(g_dpy, g_surf, g_surf, g_ctx)) return M64ERR_SYSTEM_FAIL;
    return M64ERR_SUCCESS;
}

static m64p_error v_init(void) { return init_common(); }
static m64p_error v_init_mode(m64p_render_mode mode) {
    if (mode == M64P_RENDER_VULKAN) return M64ERR_UNSUPPORTED;
    return init_common();
}
static m64p_error v_quit(void) {
    if (g_dpy != EGL_NO_DISPLAY) {
        eglMakeCurrent(g_dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (g_surf != EGL_NO_SURFACE) eglDestroySurface(g_dpy, g_surf);
        if (g_ctx != EGL_NO_CONTEXT) eglDestroyContext(g_dpy, g_ctx);
        eglTerminate(g_dpy);
    }
    g_dpy = EGL_NO_DISPLAY; g_ctx = EGL_NO_CONTEXT; g_surf = EGL_NO_SURFACE;
    return M64ERR_SUCCESS;
}
static m64p_error v_list_modes(m64p_2d_size* sizes, int* n) {
    if (n) *n = 0;
    (void)sizes;
    return M64ERR_SUCCESS;
}
static m64p_error v_list_rates(m64p_2d_size size, int* rates, int* n) {
    (void)size; if (n) *n = 0; (void)rates; return M64ERR_SUCCESS;
}
static m64p_error v_set_mode(int w, int h, int bits, int mode, int flags) {
    (void)bits; (void)mode; (void)flags;
    return make_surface(w, h);
}
static m64p_error v_set_mode_rate(int w, int h, int rate, int bits, int mode, int flags) {
    (void)rate; return v_set_mode(w, h, bits, mode, flags);
}
static m64p_function v_get_proc(const char* name) {
    return (m64p_function)eglGetProcAddress(name);
}
static m64p_error v_set_attr(m64p_GLattr attr, int value) {
    if (attr == M64P_GL_CONTEXT_MAJOR_VERSION) g_major = value;
    else if (attr == M64P_GL_CONTEXT_MINOR_VERSION) g_minor = value;
    else if (attr == M64P_GL_CONTEXT_PROFILE_MASK) g_profile = value;
    return M64ERR_SUCCESS;
}
static m64p_error v_get_attr(m64p_GLattr attr, int* value) {
    if (!value) return M64ERR_INPUT_ASSERT;
    if (attr == M64P_GL_CONTEXT_MAJOR_VERSION) *value = g_major;
    else if (attr == M64P_GL_CONTEXT_MINOR_VERSION) *value = g_minor;
    else *value = 0;
    return M64ERR_SUCCESS;
}
static m64p_error v_swap(void) { read_back(); eglSwapBuffers(g_dpy, g_surf); return M64ERR_SUCCESS; }
static m64p_error v_caption(const char*) { return M64ERR_SUCCESS; }
static m64p_error v_toggle_fs(void) { return M64ERR_UNSUPPORTED; }
static m64p_error v_resize(int w, int h) { return make_surface(w, h); }
static uint32_t v_fbo(void) { return 0; }
static m64p_error v_vk_surface(void**, void*) { return M64ERR_UNSUPPORTED; }
static m64p_error v_vk_ext(const char***, uint32_t*) { return M64ERR_UNSUPPORTED; }

extern "C" void twinplay_n64_fill_vidext(m64p_video_extension_functions* v) {
    std::memset(v, 0, sizeof(*v));
    v->Functions = 19;
    v->VidExtFuncInit = v_init;
    v->VidExtFuncInitWithRenderMode = v_init_mode;
    v->VidExtFuncQuit = v_quit;
    v->VidExtFuncListModes = v_list_modes;
    v->VidExtFuncListRates = v_list_rates;
    v->VidExtFuncSetMode = v_set_mode;
    v->VidExtFuncSetModeWithRate = v_set_mode_rate;
    v->VidExtFuncGLGetProc = v_get_proc;
    v->VidExtFuncGLSetAttr = v_set_attr;
    v->VidExtFuncGLGetAttr = v_get_attr;
    v->VidExtFuncGLSwapBuf = v_swap;
    v->VidExtFuncSetCaption = v_caption;
    v->VidExtFuncToggleFS = v_toggle_fs;
    v->VidExtFuncResizeWindow = v_resize;
    v->VidExtFuncGLGetDefaultFramebuffer = v_fbo;
    v->VidExtFuncVKGetSurface = v_vk_surface;
    v->VidExtFuncVKGetInstanceExtensions = v_vk_ext;
}
