/* iOS video extension: an offscreen EAGL / OpenGL ES 3 context. GLideN64
   renders into an FBO; SwapBuffers copies the picture back to the frontend.
   GPL-2.0-or-later (Mupen64Plus video-extension API). */
#include "m64p_types.h"
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#import <OpenGLES/EAGL.h>
#import <Foundation/Foundation.h>
#include <cstdio>
#include <dlfcn.h>
#include <cstdint>
#include <cstring>
#include <vector>

extern "C" void twinplay_n64_store_frame(const uint32_t* bgra, int w, int h);
extern "C" int twinplay_n64_gl_allowed(void);

static EAGLContext* g_ctx = nil;
static GLuint g_fbo = 0, g_color = 0, g_depth = 0;
static int g_w = 640, g_h = 480;
static int g_major = 3, g_minor = 0, g_profile = M64P_GL_CONTEXT_PROFILE_ES;
static std::vector<uint32_t> g_pix;
static void* g_gles = nullptr;

static void destroy_buffers(void) {
    if (g_color) glDeleteTextures(1, &g_color);
    if (g_depth) glDeleteRenderbuffers(1, &g_depth);
    if (g_fbo) glDeleteFramebuffers(1, &g_fbo);
    g_color = g_depth = g_fbo = 0;
}

static m64p_error ensure_context(void) {
    if (g_ctx) {
        if ([EAGLContext currentContext] != g_ctx) [EAGLContext setCurrentContext:g_ctx];
        return M64ERR_SUCCESS;
    }
    g_ctx = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
    if (!g_ctx) g_ctx = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    if (!g_ctx) return M64ERR_SYSTEM_FAIL;
    if (![EAGLContext setCurrentContext:g_ctx]) return M64ERR_SYSTEM_FAIL;
    return M64ERR_SUCCESS;
}

/* Texture-backed color buffer: glReadPixels is more reliable than a color
   renderbuffer on some iOS drivers, and matches how GLideN64 presents. */
static m64p_error make_surface(int w, int h) {
    if (w < 1) w = 640;
    if (h < 1) h = 480;
    if (w > 1920) w = 1920;
    if (h > 1080) h = 1080;
    if (ensure_context() != M64ERR_SUCCESS) return M64ERR_SYSTEM_FAIL;
    destroy_buffers();
    g_w = w;
    g_h = h;
    glGenFramebuffers(1, &g_fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, g_fbo);
    glGenTextures(1, &g_color);
    glBindTexture(GL_TEXTURE_2D, g_color);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, g_color, 0);
    glGenRenderbuffers(1, &g_depth);
    glBindRenderbuffer(GL_RENDERBUFFER, g_depth);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, w, h);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, g_depth);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, 0);
        glBindRenderbuffer(GL_RENDERBUFFER, g_depth);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT16, w, h);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, g_depth);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
            std::fprintf(stderr, "TwinPlay N64: offscreen FBO incomplete\n");
            return M64ERR_SYSTEM_FAIL;
        }
    }
    glViewport(0, 0, w, h);
    return M64ERR_SUCCESS;
}

/* Present only the default window FBO, and only from SwapBuffers (VI). Reading
   whatever FBO is bound mid-frame produced torn logos, static bands and noise. */
static void read_back(void) {
    if (!twinplay_n64_gl_allowed()) return;
    if (!g_ctx || !g_fbo || g_w <= 0 || g_h <= 0) return;
    if (ensure_context() != M64ERR_SUCCESS) return;
    glBindFramebuffer(GL_FRAMEBUFFER, g_fbo);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) return;
    glReadBuffer(GL_COLOR_ATTACHMENT0);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    const int w = g_w, h = g_h;
    std::vector<uint8_t> raw(size_t(w) * size_t(h) * 4);
    glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, raw.data());
    bool lit = false;
    g_pix.resize(size_t(w) * size_t(h));
    for (int y = 0; y < h; ++y) {
        const uint8_t* src = raw.data() + size_t(h - 1 - y) * size_t(w) * 4;
        uint32_t* dst = g_pix.data() + size_t(y) * size_t(w);
        for (int x = 0; x < w; ++x) {
            const uint8_t r = src[x * 4], g = src[x * 4 + 1], b = src[x * 4 + 2], a = src[x * 4 + 3];
            if (r | g | b) lit = true;
            dst[x] = (uint32_t(a) << 24) | (uint32_t(r) << 16) | (uint32_t(g) << 8) | b;
        }
    }
    /* Keep the last good frame if this swap is empty (the init-time swap). */
    if (lit) twinplay_n64_store_frame(g_pix.data(), w, h);
    glBindFramebuffer(GL_FRAMEBUFFER, g_fbo);
}

static m64p_error v_init(void) {
    if (ensure_context() != M64ERR_SUCCESS) return M64ERR_SYSTEM_FAIL;
    /* Create a default surface before GLideN64 queries GetDefaultFramebuffer. */
    if (!g_fbo) return make_surface(640, 480);
    return M64ERR_SUCCESS;
}
static m64p_error v_init_mode(m64p_render_mode mode) {
    if (mode == M64P_RENDER_VULKAN) return M64ERR_UNSUPPORTED;
    return v_init();
}
static m64p_error v_quit(void) {
    if (g_ctx) [EAGLContext setCurrentContext:g_ctx];
    destroy_buffers();
    [EAGLContext setCurrentContext:nil];
    g_ctx = nil;
    return M64ERR_SUCCESS;
}
static m64p_error v_list_modes(m64p_2d_size* sizes, int* n) {
    if (sizes && n && *n > 0) { sizes[0].uiWidth = 640; sizes[0].uiHeight = 480; *n = 1; }
    else if (n) *n = 1;
    return M64ERR_SUCCESS;
}
static m64p_error v_list_rates(m64p_2d_size size, int* rates, int* n) {
    (void)size; if (rates && n && *n > 0) { rates[0] = 60; *n = 1; } else if (n) *n = 1; return M64ERR_SUCCESS;
}
static m64p_error v_set_mode(int w, int h, int bits, int mode, int flags) {
    (void)bits; (void)mode; (void)flags;
    return make_surface(w, h);
}
static m64p_error v_set_mode_rate(int w, int h, int rate, int bits, int mode, int flags) {
    (void)rate; return v_set_mode(w, h, bits, mode, flags);
}
static m64p_function v_get_proc(const char* name) {
    if (!name) return nullptr;
    m64p_function p = (m64p_function)dlsym(RTLD_DEFAULT, name);
    if (p) return p;
    if (!g_gles) {
        g_gles = dlopen("/System/Library/Frameworks/OpenGLES.framework/OpenGLES", RTLD_LAZY);
    }
    if (g_gles) p = (m64p_function)dlsym(g_gles, name);
    return p;
}
static m64p_error v_set_attr(m64p_GLattr attr, int value) {
    /* GLideN64 asks for a desktop 3.3 core profile; we only have OpenGL ES. */
    if (attr == M64P_GL_CONTEXT_MAJOR_VERSION) g_major = value;
    else if (attr == M64P_GL_CONTEXT_MINOR_VERSION) g_minor = value;
    else if (attr == M64P_GL_CONTEXT_PROFILE_MASK) g_profile = M64P_GL_CONTEXT_PROFILE_ES;
    return M64ERR_SUCCESS;
}
static m64p_error v_get_attr(m64p_GLattr attr, int* value) {
    if (!value) return M64ERR_INPUT_ASSERT;
    if (attr == M64P_GL_CONTEXT_MAJOR_VERSION) *value = 3;
    else if (attr == M64P_GL_CONTEXT_MINOR_VERSION) *value = 0;
    else if (attr == M64P_GL_CONTEXT_PROFILE_MASK) *value = M64P_GL_CONTEXT_PROFILE_ES;
    else *value = 0;
    return M64ERR_SUCCESS;
}
static m64p_error v_swap(void) {
    if (!twinplay_n64_gl_allowed()) return M64ERR_SUCCESS;
    if (ensure_context() != M64ERR_SUCCESS) return M64ERR_SYSTEM_FAIL;
    read_back();
    return M64ERR_SUCCESS;
}
static m64p_error v_caption(const char*) { return M64ERR_SUCCESS; }
static m64p_error v_toggle_fs(void) { return M64ERR_UNSUPPORTED; }
static m64p_error v_resize(int w, int h) { return make_surface(w, h); }
static uint32_t v_fbo(void) { return g_fbo; }
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
