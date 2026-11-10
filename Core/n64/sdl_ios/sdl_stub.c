#include "SDL.h"
#include <sys/time.h>

static Uint32 g_init;
static struct timeval g_start;

static void ensure_clock(void) {
    static int once = 0;
    if (!once) { gettimeofday(&g_start, NULL); once = 1; }
}

Uint32 SDL_GetTicks(void) {
    ensure_clock();
    struct timeval now;
    gettimeofday(&now, NULL);
    return (Uint32)((now.tv_sec - g_start.tv_sec) * 1000 + (now.tv_usec - g_start.tv_usec) / 1000);
}

void SDL_Delay(Uint32 ms) {
    struct timespec ts;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    while (nanosleep(&ts, &ts) == -1 && errno == EINTR) {}
}

SDL_mutex* SDL_CreateMutex(void) {
    SDL_mutex* m = (SDL_mutex*)calloc(1, sizeof(*m));
    if (m) pthread_mutex_init(&m->m, NULL);
    return m;
}
void SDL_DestroyMutex(SDL_mutex* m) { if (m) { pthread_mutex_destroy(&m->m); free(m); } }
int SDL_LockMutex(SDL_mutex* m) { return m ? pthread_mutex_lock(&m->m) : -1; }
int SDL_UnlockMutex(SDL_mutex* m) { return m ? pthread_mutex_unlock(&m->m) : -1; }

SDL_cond* SDL_CreateCond(void) {
    SDL_cond* c = (SDL_cond*)calloc(1, sizeof(*c));
    if (c) pthread_cond_init(&c->c, NULL);
    return c;
}
void SDL_DestroyCond(SDL_cond* c) { if (c) { pthread_cond_destroy(&c->c); free(c); } }
int SDL_CondSignal(SDL_cond* c) { return c ? pthread_cond_signal(&c->c) : -1; }
int SDL_CondWait(SDL_cond* c, SDL_mutex* m) { return (c && m) ? pthread_cond_wait(&c->c, &m->m) : -1; }

SDL_sem* SDL_CreateSemaphore(Uint32 initial) {
    SDL_sem* s = (SDL_sem*)calloc(1, sizeof(*s));
    if (s && sem_init(&s->s, 0, initial) != 0) { free(s); return NULL; }
    return s;
}
void SDL_DestroySemaphore(SDL_sem* s) { if (s) { sem_destroy(&s->s); free(s); } }
int SDL_SemPost(SDL_sem* s) { return s ? sem_post(&s->s) : -1; }
int SDL_SemWait(SDL_sem* s) {
    if (!s) return -1;
    int r;
    while ((r = sem_wait(&s->s)) == -1 && errno == EINTR) {}
    return r;
}

static void* thread_tramp(void* p) {
    SDL_Thread* t = (SDL_Thread*)p;
    t->ret = t->fn(t->data);
    return NULL;
}
SDL_Thread* SDL_CreateThread(int (*fn)(void*), const char* name, void* data) {
    (void)name;
    SDL_Thread* t = (SDL_Thread*)calloc(1, sizeof(*t));
    if (!t) return NULL;
    t->fn = fn; t->data = data;
    if (pthread_create(&t->t, NULL, thread_tramp, t) != 0) { free(t); return NULL; }
    return t;
}
void SDL_WaitThread(SDL_Thread* t, int* status) {
    if (!t) return;
    pthread_join(t->t, NULL);
    if (status) *status = t->ret;
    free(t);
}

int SDL_InitSubSystem(Uint32 flags) { g_init |= flags; return 0; }
void SDL_QuitSubSystem(Uint32 flags) { g_init &= ~flags; }
void SDL_Quit(void) { g_init = 0; }
Uint32 SDL_WasInit(Uint32 flags) { return flags ? (g_init & flags) : g_init; }
int SDL_SetHint(const char* n, const char* v) { (void)n; (void)v; return 1; }
const char* SDL_GetError(void) { return ""; }
int SDL_atoi(const char* s) { return s ? atoi(s) : 0; }
char* SDL_getenv(const char* n) { return n ? getenv(n) : NULL; }
void SDL_PumpEvents(void) {}
int SDL_ShowCursor(int t) { return t; }

struct SDL_Window { int w, h; Uint32 flags; };
SDL_Window* SDL_CreateWindow(const char* title, int x, int y, int w, int h, Uint32 flags) {
    (void)title; (void)x; (void)y;
    SDL_Window* win = (SDL_Window*)calloc(1, sizeof(*win));
    if (win) { win->w = w; win->h = h; win->flags = flags | SDL_WINDOW_SHOWN; }
    return win;
}
void SDL_DestroyWindow(SDL_Window* w) { free(w); }
void SDL_SetWindowTitle(SDL_Window* w, const char* t) { (void)w; (void)t; }
void SDL_SetWindowSize(SDL_Window* w, int ww, int hh) { if (w) { w->w = ww; w->h = hh; } }
int SDL_SetWindowFullscreen(SDL_Window* w, Uint32 flags) { if (w) w->flags = flags; return 0; }
void SDL_GetWindowSize(SDL_Window* w, int* ww, int* hh) { if (ww) *ww = w ? w->w : 0; if (hh) *hh = w ? w->h : 0; }
Uint32 SDL_GetWindowFlags(SDL_Window* w) { return w ? w->flags : 0; }

SDL_GLContext SDL_GL_CreateContext(SDL_Window* w) { (void)w; return (SDL_GLContext)(intptr_t)1; }
void SDL_GL_DeleteContext(SDL_GLContext c) { (void)c; }
int SDL_GL_MakeCurrent(SDL_Window* w, SDL_GLContext c) { (void)w; (void)c; return 0; }
void* SDL_GL_GetProcAddress(const char* n) { (void)n; return NULL; }
int SDL_GL_SetAttribute(SDL_GLattr a, int v) { (void)a; (void)v; return 0; }
int SDL_GL_GetAttribute(SDL_GLattr a, int* v) { if (v) *v = 0; (void)a; return 0; }
int SDL_GL_SetSwapInterval(int i) { (void)i; return 0; }
int SDL_GL_GetSwapInterval(void) { return 0; }
void SDL_GL_SwapWindow(SDL_Window* w) { (void)w; }

int SDL_GetDesktopDisplayMode(int d, SDL_DisplayMode* m) {
    (void)d;
    if (m) { m->format = 0; m->w = 640; m->h = 480; m->refresh_rate = 60; m->driverdata = NULL; }
    return 0;
}
int SDL_GetNumDisplayModes(int d) { (void)d; return 1; }
int SDL_GetDisplayMode(int d, int i, SDL_DisplayMode* m) { (void)i; return SDL_GetDesktopDisplayMode(d, m); }

int SDL_NumJoysticks(void) { return 0; }
SDL_Joystick* SDL_JoystickOpen(int i) { (void)i; return NULL; }
SDL_JoystickID SDL_JoystickInstanceID(SDL_Joystick* j) { (void)j; return 0; }
void SDL_SetEventFilter(SDL_EventFilter f, void* u) { (void)f; (void)u; }
int SDL_Vulkan_LoadLibrary(const char* p) { (void)p; return -1; }
void SDL_Vulkan_UnloadLibrary(void) {}
int SDL_Vulkan_GetInstanceExtensions(SDL_Window* w, unsigned* c, const char** n) { (void)w; (void)n; if (c) *c = 0; return 0; }
int SDL_Vulkan_CreateSurface(SDL_Window* w, void* inst, void* surf) { (void)w; (void)inst; (void)surf; return -1; }

const Uint8* SDL_GetKeyboardState(int* n) {
    static Uint8 keys[SDL_NUM_SCANCODES];
    if (n) *n = SDL_NUM_SCANCODES;
    return keys;
}
Uint16 SDL_GetModState(void) { return 0; }
