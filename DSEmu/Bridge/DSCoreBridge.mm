// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
#import "DSCoreBridge.h"

extern "C" {
void twinplay_n64_set_paused(int paused);
void twinplay_3ds_set_paused(int paused);
void twinplay_n64_unload(void);
void twinplay_3ds_unload(void);
int twinplay_n64_available(void);
int twinplay_3ds_available(void);
void *twinplay_3ds_metal_layer(void);
void twinplay_3ds_set_surface_size(int w, int h, float scale);
// Weak fallbacks: the 60 fps pre-layout archive does not export these. A later
// composite archive can provide strong definitions that override them.
__attribute__((weak))
void twinplay_3ds_set_present_ready(int ready) { (void)ready; }
__attribute__((weak))
void twinplay_3ds_composite_to_layer(void *dest_layer, float scale,
                                    float top_dx, float top_dy, float top_dw, float top_dh,
                                    float bot_dx, float bot_dy, float bot_dw, float bot_dh) {
    (void)dest_layer; (void)scale;
    (void)top_dx; (void)top_dy; (void)top_dw; (void)top_dh;
    (void)bot_dx; (void)bot_dy; (void)bot_dw; (void)bot_dh;
}
__attribute__((weak))
void twinplay_3ds_frame_timing(double *last_ms, double *max_ms, double *p95_ms) {
    if (last_ms) *last_ms = 0;
    if (max_ms) *max_ms = 0;
    if (p95_ms) *p95_ms = 0;
}
void twinplay_3ds_set_cpu_clock(int percent);
int twinplay_3ds_using_vulkan(void);
unsigned long long twinplay_3ds_frame_count(void);
}

#import <UIKit/UIKit.h>
#include "dscore/EmulatorCore.hpp"
#include "Cheats.hpp"
#include <algorithm>
#include <atomic>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <vector>
#include <csignal>
#include <ctime>
#include <execinfo.h>
#include <fcntl.h>
#include <unistd.h>
#include <mach-o/dyld.h>
#include <sys/ucontext.h>


// ---------------------------------------------------------------- crash logger
// Only async-signal-safe calls (open/write/backtrace_symbols_fd) run inside the handler; the
// paths and context are prepared ahead of time.
namespace {
char gCrashDir[1024];
char gCrashContext[256];
struct sigaction gOldActions[32];
const int kCrashSignals[] = {SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP};

void crashWrite(int fd, const char* s) { if (s) (void)!write(fd, s, strlen(s)); }
void crashHex(int fd, unsigned long long v) {
    char b[19] = "0x"; for (int i = 0; i < 16; ++i) { int d = int((v >> (60 - 4 * i)) & 15); b[2 + i] = char(d < 10 ? '0' + d : 'a' + d - 10); }
    b[18] = 0; crashWrite(fd, b);
}
void crashDec(int fd, unsigned long long v) {
    char b[24]; int n = 0; do { b[n++] = char('0' + v % 10); v /= 10; } while (v && n < 23);
    char o[24]; for (int i = 0; i < n; ++i) o[i] = b[n - 1 - i]; o[n] = 0; crashWrite(fd, o);
}
int crashOpen() {
    char path[1200]; size_t n = strlen(gCrashDir);
    if (n == 0 || n > 1100) return -1;
    memcpy(path, gCrashDir, n);
    const char* pre = "/crash-"; memcpy(path + n, pre, 7); n += 7;
    unsigned long long t = (unsigned long long)time(nullptr); char d[24]; int k = 0;
    do { d[k++] = char('0' + t % 10); t /= 10; } while (t && k < 23);
    while (k) path[n++] = d[--k];
    memcpy(path + n, ".log", 5);
    return open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
}
void crashHandler(int sig, siginfo_t* info, void* ctx) {
    int fd = crashOpen();
    if (fd >= 0) {
        crashWrite(fd, "TwinPlay crash: signal "); crashDec(fd, (unsigned long long)sig);
        crashWrite(fd, " addr "); crashHex(fd, (unsigned long long)(uintptr_t)(info ? info->si_addr : nullptr));
#if defined(__arm64__)
        if (ctx) { auto* uc = (ucontext_t*)ctx; if (uc->uc_mcontext) { crashWrite(fd, " pc "); crashHex(fd, uc->uc_mcontext->__ss.__pc); crashWrite(fd, " lr "); crashHex(fd, uc->uc_mcontext->__ss.__lr); } }
#endif
        crashWrite(fd, "\ncontext: "); crashWrite(fd, gCrashContext);
        crashWrite(fd, "\nimage load address "); crashHex(fd, (unsigned long long)(uintptr_t)_dyld_get_image_header(0));
        crashWrite(fd, " slide "); crashHex(fd, (unsigned long long)_dyld_get_image_vmaddr_slide(0));
        crashWrite(fd, "\nbacktrace (symbolicate with: atos -o TwinPlay.app.dSYM/Contents/Resources/DWARF/TwinPlay -l <load address> <addr>):\n");
        void* frames[64]; int n = backtrace(frames, 64);
        backtrace_symbols_fd(frames, n, fd);
        close(fd);
    }
    // Hand over to the previous handler / default action so the system crash report is still made.
    if (sig > 0 && sig < 32) sigaction(sig, &gOldActions[sig], nullptr);
    raise(sig);
}
void exceptionHandler(NSException* e) {
    int fd = crashOpen();
    if (fd < 0) return;
    crashWrite(fd, "TwinPlay uncaught exception: "); crashWrite(fd, e.name.UTF8String);
    crashWrite(fd, ": "); crashWrite(fd, e.reason.UTF8String);
    crashWrite(fd, "\ncontext: "); crashWrite(fd, gCrashContext);
    crashWrite(fd, "\n"); crashWrite(fd, [e.callStackSymbols componentsJoinedByString:@"\n"].UTF8String);
    crashWrite(fd, "\n"); close(fd);
}
} // namespace

@implementation DSROMBanner
@end

@implementation DSROMHeaderInfo
@end

@implementation DSCoreBridge {
    std::unique_ptr<dscore::EmulatorCore> _core;
    dscore::CheatEngine _cheats;
    std::mutex _frameLock;                       // guards _frontIndex, _sequence and _status
    std::vector<uint32_t> _frames[2];            // double buffer: top then bottom screen, at _scales[i]
    int _scales[2];
    int _frontIndex;
    NSInteger _renderScale;
    std::atomic<uint64_t> _framesRun;
    std::atomic<bool> _captureInUse;
    std::atomic<int> _stuckFrames;
    std::atomic<uint64_t> _irqLivelocks;
    uint64_t _sequence;
    NSInteger _frameSkip, _renderThreads;
    std::string _status;
    std::atomic<uint32_t> _buttons;
    std::atomic<bool> _touchDown;
    std::atomic<int> _touchX, _touchY;
    std::atomic<float> _analogX, _analogY, _cStickX, _cStickY;
    NSString *_romTitle;
    NSString *_gameCode;
    NSURL *_saveURL;
    NSInteger _saveTypeOverride;
    BOOL _backedUp;
    int _saveCountdown;
}

- (instancetype)initWithKind:(DSCoreKind)kind {
    if ((self = [super init])) {
        _core = dscore::createCore(kind == DSCoreKindTestPattern ? dscore::CoreKind::TestPattern
                                   : kind == DSCoreKindGBA ? dscore::CoreKind::GBA
                                   : kind == DSCoreKindGB ? dscore::CoreKind::GB
                                   : kind == DSCoreKindNES ? dscore::CoreKind::NES
                                   : kind == DSCoreKindSNES ? dscore::CoreKind::SNES
                                   : kind == DSCoreKindN64 ? dscore::CoreKind::N64
                                   : kind == DSCoreKindN3DS ? dscore::CoreKind::N3DS
                                                           : dscore::CoreKind::Interpreter);
        /* Load signed N64 dylibs from Frameworks only. resourcePath/plugins is
           the same as PlugIns on case-insensitive APFS, and iOS will SIGKILL
           CODESIGNING if GLideN64 calls back into a dylib sitting there. */
        if (NSString *fw = NSBundle.mainBundle.privateFrameworksPath) {
            _core->setDataPath(fw.UTF8String ?: "");
        }
        _frames[0].assign(dscore::kScreenPixels * 2, 0xFF000000u);
        _frames[1].assign(dscore::kScreenPixels * 2, 0xFF000000u);
        _scales[0] = _scales[1] = 1; _renderScale = 1;
        NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
        BOOL hq = [ud objectForKey:@"highQualityAudio"] == nil || [ud boolForKey:@"highQualityAudio"];
        _core->setAudioInterpolation(hq ? 2 : 0);
        _frontIndex = 0; _sequence = 0; _frameSkip = 0; _renderThreads = 0;
        _buttons = 0; _touchDown = false; _touchX = 0; _touchY = 0;
        _analogX = 0; _analogY = 0; _cStickX = 0; _cStickY = 0;
        _romTitle = @""; _gameCode = @"";
        _saveCountdown = -1;
    }
    return self;
}

- (BOOL)loadROMAtURL:(NSURL *)url error:(NSError **)error {
    std::string err;
    if (_core->prefersPathLoad()) {
        if (!_core->loadROMPath(url.path.UTF8String ?: "", err)) {
            if (error) {
                *error = [NSError errorWithDomain:@"DSEmu" code:1
                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:err.c_str()] ?: @"Invalid ROM"}];
            }
            return NO;
        }
        _romTitle = [NSString stringWithUTF8String:_core->romInfo().title.c_str()] ?: @"";
        _gameCode = [NSString stringWithUTF8String:_core->romInfo().gameCode.c_str()] ?: @"";
        return YES;
    }
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:error];
    if (!data) return NO;
    if (!_core->loadROM(static_cast<const uint8_t *>(data.bytes), data.length, err)) {
        if (error) {
            *error = [NSError errorWithDomain:@"DSEmu" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:err.c_str()] ?: @"Invalid ROM"}];
        }
        return NO;
    }
    _romTitle = [NSString stringWithUTF8String:_core->romInfo().title.c_str()] ?: @"";
    _gameCode = [NSString stringWithUTF8String:_core->romInfo().gameCode.c_str()] ?: @"";
    return YES;
}

static std::vector<uint8_t> twinBytes(NSData *d) {
    if (d.length == 0) return {};
    const uint8_t *p = static_cast<const uint8_t *>(d.bytes);
    return std::vector<uint8_t>(p, p + d.length);
}

- (BOOL)setLLEBIOS9:(NSData *)bios9 bios7:(NSData *)bios7 firmware:(NSData *)firmware bootFirmware:(BOOL)bootFirmware {
    return _core->setLLEBIOS(twinBytes(bios9), twinBytes(bios7), twinBytes(firmware), bootFirmware);
}

- (BOOL)usingLLEBIOS { return _core->usingLLEBIOS(); }

- (void)setARM7BIOSURL:(NSURL *)url {
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (data.length == 0) return;
    const uint8_t *p = static_cast<const uint8_t *>(data.bytes);
    _core->setARM7BIOS(std::vector<uint8_t>(p, p + data.length));
}

- (void)attachSaveFileURL:(NSURL *)url {
    _saveURL = url;
    if (url.URLByDeletingLastPathComponent.path.length) {
        _core->setSaveDirectory(url.URLByDeletingLastPathComponent.path.UTF8String);
    }
    _saveCountdown = -1;
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (data.length > 0) {
        const uint8_t *p = static_cast<const uint8_t *>(data.bytes);
        _core->loadSaveData(std::vector<uint8_t>(p, p + data.length));
    }
}

- (void)setAntiAlias:(NSInteger)antiAlias textureFilter:(BOOL)textureFilter widescreen:(BOOL)widescreen {
    _core->setEnhancements((int)antiAlias, textureFilter, widescreen);
}

- (NSInteger)saveTypeOverride { return _saveTypeOverride; }
- (void)setSaveTypeOverride:(NSInteger)n { _saveTypeOverride = MAX(0, MIN(9, n)); _core->setSaveTypeOverride((int)_saveTypeOverride); }
- (NSString *)saveTypeDescription { return [NSString stringWithUTF8String:_core->saveTypeDescription().c_str()]; }
- (BOOL)loadedSaveRejected { return _core->loadedSaveRejected(); }

- (void)backUpSaveFile {
    if (!_saveURL || ![[NSFileManager defaultManager] fileExistsAtPath:_saveURL.path]) return;
    NSURL *bak = [_saveURL URLByAppendingPathExtension:@"bak"];
    [[NSFileManager defaultManager] removeItemAtURL:bak error:nil];
    [[NSFileManager defaultManager] moveItemAtURL:_saveURL toURL:bak error:nil];
}

- (void)deleteSaveData {
    [self backUpSaveFile];
    _core->loadSaveData({});
    _core->setSaveTypeOverride((int)_saveTypeOverride);
    _backedUp = YES;
    _saveCountdown = -1;
}

- (void)flushSave {
    if (!_saveURL || !_core->saveDataDirty()) return;
    if (_core->loadedSaveRejected() && !_backedUp) { [self backUpSaveFile]; _backedUp = YES; }
    std::vector<uint8_t> d = _core->saveData();
    _core->clearSaveDataDirty();
    NSData *data = [NSData dataWithBytes:d.data() length:d.size()];
    NSError *err = nil;
    if (![data writeToURL:_saveURL options:NSDataWritingAtomic error:&err]) {
        NSLog(@"TwinPlay: could not write the save file: %@", err);
    }
    _saveCountdown = -1;
}

- (void)reset { _core->reset(); }

+ (NSString *)cheatErrorForCode:(NSString *)code system:(NSString *)system {
    dscore::Cheat c; std::string err;
    if (dscore::parseCheat(system.UTF8String ?: "", code.UTF8String ?: "", c, err)) return nil;
    return [NSString stringWithUTF8String:err.c_str()] ?: @"Invalid code.";
}

- (uint32_t)achievementRead:(uint32_t)address buffer:(uint8_t *)buffer count:(uint32_t)count {
    return _core ? _core->achievementRead(address, buffer, count) : 0;
}

- (void)setCheatCodes:(NSArray<NSString *> *)codes system:(NSString *)system {
    std::vector<dscore::Cheat> list;
    for (NSString *code in codes) {
        dscore::Cheat c; std::string err;
        if (dscore::parseCheat(system.UTF8String ?: "", code.UTF8String ?: "", c, err)) list.push_back(std::move(c));
    }
    _cheats.set(std::move(list));
    _core->setRomPatches(_cheats.romPatches());
}

- (void)setAnalogX:(float)x y:(float)y stick:(NSInteger)stick {
    if (stick == 0) { _analogX.store(x); _analogY.store(y); }
    else { _cStickX.store(x); _cStickY.store(y); }
    _core->setAnalog((int)stick, stick == 0 ? x : _cStickX.load(), stick == 0 ? y : _cStickY.load());
}

- (void)runFrame {
    _core->setButtons(_buttons.load());
    _core->setAnalog(0, _analogX.load(), _analogY.load());
    _core->setAnalog(1, _cStickX.load(), _cStickY.load());
    _core->setTouch(_touchDown.load(), _touchX.load(), _touchY.load());
    _core->runFrame();
    if (!_cheats.empty()) _cheats.apply(*_core);      // cheats: once per frame, after the frame
    _framesRun.fetch_add(1);
    _captureInUse.store(_core->captureInUse());
    _stuckFrames.store(_core->stuckFrames());
    _irqLivelocks.store(_core->irqLivelockRecoveries());
    if (_saveURL) {                                   // debounce: write ~1 s after the last change
        if (_core->saveDataDirty()) {
            if (_saveCountdown < 0) _saveCountdown = 60;
            else if (--_saveCountdown == 0) [self flushSave];
        }
    }
    std::string status = _core->statusText();
    if (_core->frameDrawn()) {
        // Fill the back buffer without the lock (readers only touch the front one), then flip.
        int bi = _frontIndex ^ 1, sc = _core->renderScale();
        std::vector<uint32_t> &back = _frames[bi];
        const int sys = _core->system();
        // NES (256x240) and SNES (256x224) are wider in time than a DS screen. Pack the picture
        // into the top of the existing 256x384 staging buffer so the Metal crop can show every row.
        if (sys == 4 || sys == 5) {
            const size_t total = size_t(dscore::kScreenWidth) * size_t(dscore::kScreenHeight * 2);
            if (back.size() != total) back.assign(total, 0xFF000000u);
            else std::fill(back.begin(), back.end(), 0xFF000000u);
            const int sw = _core->screenWidth(), sh = _core->screenHeight();
            const int rows = sh < dscore::kScreenHeight * 2 ? sh : dscore::kScreenHeight * 2;
            const int cols = sw < dscore::kScreenWidth ? sw : dscore::kScreenWidth;
            const uint32_t *src = _core->framebuffer(0);
            for (int y = 0; y < rows; ++y)
                std::memcpy(back.data() + size_t(y) * dscore::kScreenWidth, src + size_t(y) * size_t(sw),
                            size_t(cols) * sizeof(uint32_t));
            sc = 1;
        } else {
            size_t per = dscore::kScreenPixels * size_t(sc) * size_t(sc);
            if (back.size() != per * 2) back.resize(per * 2);
            std::memcpy(back.data(), _core->framebufferHiRes(0), per * sizeof(uint32_t));
            std::memcpy(back.data() + per, _core->framebufferHiRes(1), per * sizeof(uint32_t));
        }
        _scales[bi] = sc;
        std::lock_guard<std::mutex> lk(_frameLock);
        _frontIndex ^= 1;
        ++_sequence;
        _status = std::move(status);
    } else {
        std::lock_guard<std::mutex> lk(_frameLock);
        _status = std::move(status);
    }
}

- (uint64_t)frameSequence {
    std::lock_guard<std::mutex> lk(_frameLock);
    return _sequence;
}

- (uint64_t)copyFrameInto:(uint32_t *)dst {
    std::lock_guard<std::mutex> lk(_frameLock);
    const std::vector<uint32_t> &f = _frames[_frontIndex];
    int sc = _scales[_frontIndex];
    if (sc == 1) { std::memcpy(dst, f.data(), dscore::kScreenPixels * 2 * sizeof(uint32_t)); return _sequence; }
    const int w = dscore::kScreenWidth * sc;
    for (int y = 0; y < dscore::kScreenHeight * 2; ++y)             // point-sample down to 1x
        for (int x = 0; x < dscore::kScreenWidth; ++x)
            dst[y * dscore::kScreenWidth + x] = f[size_t(y * sc) * size_t(w) + size_t(x * sc)];
    return _sequence;
}

- (uint64_t)copyHiResFrameInto:(uint32_t *)dst capacity:(NSInteger)pixels scale:(NSInteger *)scale {
    std::lock_guard<std::mutex> lk(_frameLock);
    const std::vector<uint32_t> &f = _frames[_frontIndex];
    if ((NSInteger)f.size() > pixels) { if (scale) *scale = 0; return _sequence; }
    std::memcpy(dst, f.data(), f.size() * sizeof(uint32_t));
    if (scale) *scale = _scales[_frontIndex];
    return _sequence;
}

- (NSInteger)renderScale { return _renderScale; }
- (void)setHighQualityAudio:(BOOL)on { _core->setAudioInterpolation(on ? 2 : 0); }
- (BOOL)captureInUse { return _captureInUse.load() ? YES : NO; }
- (uint64_t)framesRun { return _framesRun.load(); }
- (NSInteger)stuckFrames { return _stuckFrames.load(); }
- (uint64_t)irqLivelockRecoveries { return _irqLivelocks.load(); }
- (uint64_t)renderPoolStalls { return _core ? _core->renderPoolStalls() : 0; }   // atomic inside the core
- (NSString *)freezeReport { return [NSString stringWithUTF8String:_core->freezeReport().c_str()]; }
- (void)setRenderScale:(NSInteger)n { _renderScale = MAX(1, MIN(4, n)); _core->setRenderScale((int)_renderScale); }

- (BOOL)isGBA {
    const int s = _core->system();
    return s != 0 && s != 7;   // single screen. 0 is DS, 7 is 3DS. Not "this is a GBA game".
}
- (BOOL)isGameBoy { return _core->system() == 2 || _core->system() == 3; }
- (BOOL)isGameBoyColor { return _core->system() == 3; }
- (void)setGameBoyPalette:(NSInteger)palette colorCorrection:(BOOL)correct { _core->setVideoOptions((int)palette, correct); }
- (NSInteger)screenWidth { return _core->screenWidth(); }
- (void *)n3dsMetalLayer {
    return (_core && _core->system() == 7 && twinplay_3ds_available()) ? twinplay_3ds_metal_layer() : nullptr;
}

- (void *)n3dsMetalView {
    // Pre-layout core has no metal view helper; the host uses n3dsMetalLayer.
    return nullptr;
}
- (void)setN3DSSurfaceWidth:(NSInteger)width height:(NSInteger)height scale:(float)scale {
    if (_core && _core->system() == 7 && twinplay_3ds_available())
        twinplay_3ds_set_surface_size((int)width, (int)height, scale);
}
- (void)setN3DSScreenLayoutFbWidth:(NSInteger)fbWidth fbHeight:(NSInteger)fbHeight scale:(float)scale
                            topX:(NSInteger)topX topY:(NSInteger)topY topW:(NSInteger)topW topH:(NSInteger)topH
                            bottomX:(NSInteger)bottomX bottomY:(NSInteger)bottomY bottomW:(NSInteger)bottomW bottomH:(NSInteger)bottomH {
    // Pre-layout core has no custom-layout API; surface size is enough.
    if (_core && _core->system() == 7 && twinplay_3ds_available())
        twinplay_3ds_set_surface_size((int)fbWidth, (int)fbHeight, scale);
}
- (void)setN3DSCpuClockPercentage:(NSInteger)percent {
    if (twinplay_3ds_available()) twinplay_3ds_set_cpu_clock((int)percent);
}
- (void)n3dsFrameTimingLastMs:(double *)lastMs maxMs:(double *)maxMs p95Ms:(double *)p95Ms {
    if (_core && _core->system() == 7 && twinplay_3ds_available() && twinplay_3ds_frame_timing)
        twinplay_3ds_frame_timing(lastMs, maxMs, p95Ms);
    else {
        if (lastMs) *lastMs = 0;
        if (maxMs) *maxMs = 0;
        if (p95Ms) *p95Ms = 0;
    }
}
- (BOOL)n3dsUsingVulkan {
    return _core && _core->system() == 7 && twinplay_3ds_available() && twinplay_3ds_using_vulkan();
}
- (uint64_t)n3dsFrameCount {
    return (_core && _core->system() == 7 && twinplay_3ds_available()) ? twinplay_3ds_frame_count() : 0;
}
- (void)setN3DSPresentReady:(BOOL)ready {
    if (twinplay_3ds_available() && twinplay_3ds_set_present_ready)
        twinplay_3ds_set_present_ready(ready ? 1 : 0);
}
- (void)compositeN3DSToLayer:(void *)destLayer scale:(float)scale
                                  topX:(float)topX topY:(float)topY topW:(float)topW topH:(float)topH
                                  bottomX:(float)bottomX bottomY:(float)bottomY bottomW:(float)bottomW bottomH:(float)bottomH {
    if (destLayer && twinplay_3ds_available() && twinplay_3ds_composite_to_layer)
        twinplay_3ds_composite_to_layer(destLayer, scale, topX, topY, topW, topH, bottomX, bottomY, bottomW, bottomH);
}
- (NSInteger)screenHeight { return _core->screenHeight(); }

- (CGImageRef)copyThumbnailImage {
    if (self.isGBA) return [self copyScreenImage:0];
    std::vector<uint32_t> px(dscore::kScreenPixels * 2);
    [self copyFrameInto:px.data()];
    CFDataRef data = CFDataCreate(kCFAllocatorDefault, reinterpret_cast<const UInt8 *>(px.data()), CFIndex(px.size() * 4));
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef img = CGImageCreate(dscore::kScreenWidth, dscore::kScreenHeight * 2, 8, 32, dscore::kScreenWidth * 4, cs,
                                   (CGBitmapInfo)(kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst),
                                   provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(cs); CGDataProviderRelease(provider); CFRelease(data);
    return img;
}

static NSString *trimmedASCII(const uint8_t *p, size_t n) {
    std::string s;
    for (size_t i = 0; i < n && p[i]; ++i) s += (p[i] >= 0x20 && p[i] < 0x7F) ? char(p[i]) : ' ';
    while (!s.empty() && s.back() == ' ') s.pop_back();
    return [NSString stringWithUTF8String:s.c_str()] ?: @"";
}

+ (NSInteger)gameBoySystemOfROMAtURL:(NSURL *)url {
    NSString *ext = url.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"gba"] || [ext isEqualToString:@"nds"] || [ext isEqualToString:@"nes"]
        || [ext isEqualToString:@"sfc"] || [ext isEqualToString:@"smc"]) return 0;
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
    NSData *h = [fh readDataOfLength:0x150];
    [fh closeFile];
    const uint8_t *p = static_cast<const uint8_t *>(h.bytes);
    BOOL byExt = [ext isEqualToString:@"gb"] || [ext isEqualToString:@"gbc"] || [ext isEqualToString:@"sgb"];
    if (h.length < 0x150) return byExt ? ([ext isEqualToString:@"gbc"] ? 3 : 2) : 0;
    if (!byExt && !dscore::isGBImage(p, h.length)) return 0;
    return (p[0x143] & 0x80) ? 3 : 2;
}

+ (BOOL)isNESROMAtURL:(NSURL *)url {
    if ([url.pathExtension.lowercaseString isEqualToString:@"nes"]) return YES;
    NSString *ext = url.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"nds"] || [ext isEqualToString:@"gba"] || [ext isEqualToString:@"gb"]
        || [ext isEqualToString:@"gbc"] || [ext isEqualToString:@"sfc"] || [ext isEqualToString:@"smc"]
        || [ext isEqualToString:@"n64"] || [ext isEqualToString:@"z64"] || [ext isEqualToString:@"v64"]
        || [ext isEqualToString:@"3ds"] || [ext isEqualToString:@"cci"] || [ext isEqualToString:@"cxi"]) return NO;
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
    NSData *h = [fh readDataOfLength:16];
    [fh closeFile];
    return dscore::isNESImage(static_cast<const uint8_t *>(h.bytes), h.length);
}

+ (BOOL)isSNESROMAtURL:(NSURL *)url {
    NSString *ext = url.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"sfc"] || [ext isEqualToString:@"smc"]) return YES;
    if ([ext isEqualToString:@"nds"] || [ext isEqualToString:@"gba"] || [ext isEqualToString:@"nes"]
        || [ext isEqualToString:@"gb"] || [ext isEqualToString:@"gbc"]
        || [ext isEqualToString:@"n64"] || [ext isEqualToString:@"z64"] || [ext isEqualToString:@"v64"]
        || [ext isEqualToString:@"3ds"] || [ext isEqualToString:@"cci"] || [ext isEqualToString:@"cxi"]) return NO;
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
    NSData *h = [fh readDataOfLength:0x10040];
    [fh closeFile];
    if (h.length < 0x8000) return NO;
    return dscore::isSNESImage(static_cast<const uint8_t *>(h.bytes), h.length);
}

+ (BOOL)isN64ROMAtURL:(NSURL *)url {
    NSString *ext = url.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"n64"] || [ext isEqualToString:@"z64"] || [ext isEqualToString:@"v64"]) return YES;
    if ([ext isEqualToString:@"nds"] || [ext isEqualToString:@"gba"] || [ext isEqualToString:@"nes"]
        || [ext isEqualToString:@"sfc"] || [ext isEqualToString:@"smc"] || [ext isEqualToString:@"gb"]
        || [ext isEqualToString:@"gbc"] || [ext isEqualToString:@"3ds"] || [ext isEqualToString:@"cci"]
        || [ext isEqualToString:@"cxi"]) return NO;
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
    NSData *h = [fh readDataOfLength:4];
    [fh closeFile];
    return dscore::isN64Image(static_cast<const uint8_t *>(h.bytes), h.length);
}

+ (BOOL)is3DSROMAtURL:(NSURL *)url {
    NSString *ext = url.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"3ds"] || [ext isEqualToString:@"cci"] || [ext isEqualToString:@"cxi"]) return YES;
    if ([ext isEqualToString:@"nds"] || [ext isEqualToString:@"gba"] || [ext isEqualToString:@"nes"]
        || [ext isEqualToString:@"sfc"] || [ext isEqualToString:@"smc"] || [ext isEqualToString:@"n64"]
        || [ext isEqualToString:@"z64"] || [ext isEqualToString:@"v64"]) return NO;
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
    NSData *h = [fh readDataOfLength:0x110];
    [fh closeFile];
    return dscore::is3DSImage(static_cast<const uint8_t *>(h.bytes), h.length);
}

+ (BOOL)isGBAROMAtURL:(NSURL *)url {
    NSString *ext = url.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"gba"]) return YES;
    if ([ext isEqualToString:@"nds"] || [ext isEqualToString:@"nes"] || [ext isEqualToString:@"sfc"]
        || [ext isEqualToString:@"smc"]) return NO;
    if ([self gameBoySystemOfROMAtURL:url] != 0) return NO;
    if ([self isNESROMAtURL:url] || [self isSNESROMAtURL:url]) return NO;
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
    NSData *h = [fh readDataOfLength:0xC0];
    [fh closeFile];
    return dscore::isGBAImage(static_cast<const uint8_t *>(h.bytes), h.length);
}

+ (void)installCrashLoggerInDirectory:(NSString *)directory {
    static std::once_flag once;
    std::call_once(once, [&] {
        strlcpy(gCrashDir, directory.fileSystemRepresentation, sizeof gCrashDir);
        static char altStack[64 * 1024];                 // lets a stack overflow on this thread still be logged
        stack_t ss{}; ss.ss_sp = altStack; ss.ss_size = sizeof altStack; sigaltstack(&ss, nullptr);
        for (int s : kCrashSignals) {
            struct sigaction sa{}; sa.sa_sigaction = crashHandler; sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
            sigemptyset(&sa.sa_mask);
            sigaction(s, &sa, &gOldActions[s]);
        }
        NSSetUncaughtExceptionHandler(&exceptionHandler);
    });
}

+ (void)setCrashContext:(NSString *)context {
    strlcpy(gCrashContext, context.UTF8String ?: "", sizeof gCrashContext);
}

+ (nullable DSROMHeaderInfo *)headerInfoForROMAtURL:(NSURL *)url {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
    if (!fh) return nil;
    NSData *h = [fh readDataOfLength:0x200];
    [fh closeFile];
    if (h.length < 0xC0) return nil;
    const uint8_t *p = static_cast<const uint8_t *>(h.bytes);
    DSROMHeaderInfo *info = [[DSROMHeaderInfo alloc] init];
    if ([self isN64ROMAtURL:url]) {
        info.system = 6; info.isGBA = NO;
        std::string name = dscore::n64InternalName(p, h.length);
        if (h.length >= 4 && !dscore::isN64Image(p, 4)) {
            // v64/n64 names are byte-swapped until normalized. The extension path still shows the file name.
            name.clear();
        }
        info.title = name.empty() ? @"" : [NSString stringWithUTF8String:name.c_str()];
        info.gameCode = @"N64";
        return info;
    }
    if ([self is3DSROMAtURL:url]) {
        info.system = 7; info.isGBA = NO;
        info.title = @""; info.gameCode = @"3DS";
        return info;
    }
    if ([self isNESROMAtURL:url]) {
        info.system = 4; info.isGBA = NO;
        info.title = @""; info.gameCode = @"";
        return info;
    }
    if ([self isSNESROMAtURL:url]) {
        info.system = 5; info.isGBA = NO;
        NSFileHandle *fh2 = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
        NSData *whole = [fh2 readDataOfLength:0x10040];
        [fh2 closeFile];
        const uint8_t *d = static_cast<const uint8_t *>(whole.bytes);
        size_t n = whole.length;
        size_t base = (n % 1024 == 512) ? 512 : 0;
        BOOL hi = NO;
        if (d && n > base + 0xFFDF) {
            // Prefer the map byte the core uses: 0x20/0x30 LoROM, 0x21/0x31 HiROM.
            uint8_t loMap = (base + 0x7FD5 < n) ? d[base + 0x7FD5] : 0;
            uint8_t hiMap = (base + 0xFFD5 < n) ? d[base + 0xFFD5] : 0;
            hi = (hiMap == 0x21 || hiMap == 0x31) && !(loMap == 0x20 || loMap == 0x30);
        }
        size_t hdr = base + (hi ? 0xFFC0 : 0x7FC0);
        info.gameCode = hi ? @"HiROM" : @"LoROM";
        info.title = (d && hdr + 21 <= n) ? trimmedASCII(d + hdr, 21) : @"";
        return info;
    }
    NSInteger gb = [self gameBoySystemOfROMAtURL:url];
    if (gb != 0 && h.length >= 0x150) {
        info.system = gb; info.isGBA = NO;
        info.title = trimmedASCII(p + 0x134, (p[0x143] & 0x80) ? 15 : 16);
        BOOL code = (p[0x143] & 0x80) != 0;
        for (int i = 0; i < 4 && code; ++i) if (p[0x13F + i] < 'A' || p[0x13F + i] > 'Z') code = NO;
        info.gameCode = code ? trimmedASCII(p + 0x13F, 4) : @"";
        return info;
    }
    info.isGBA = [self isGBAROMAtURL:url];
    info.system = info.isGBA ? 1 : 0;
    if (info.isGBA) { info.title = trimmedASCII(p + 0xA0, 12); info.gameCode = trimmedASCII(p + 0xAC, 4); }
    else { info.title = trimmedASCII(p, 12); info.gameCode = trimmedASCII(p + 0x0C, 4); }
    return info;
}

+ (nullable DSROMBanner *)bannerForROMAtURL:(NSURL *)url {
    if ([self isGBAROMAtURL:url] || [self isNESROMAtURL:url] || [self isSNESROMAtURL:url]
        || [self isN64ROMAtURL:url] || [self is3DSROMAtURL:url] || [self gameBoySystemOfROMAtURL:url] != 0) {
        DSROMHeaderInfo *info = [self headerInfoForROMAtURL:url];
        if (!info || info.title.length == 0) return nil;
        DSROMBanner *b = [[DSROMBanner alloc] init];
        b.title = info.title;
        return b;
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
    if (!fh) return nil;
    NSData *header = [fh readDataOfLength:0x200];
    uint32_t off = dscore::romBannerOffset(static_cast<const uint8_t *>(header.bytes), header.length);
    DSROMBanner *result = nil;
    if (off >= 0x200) {
        @try {
            [fh seekToFileOffset:off];
            NSData *b = [fh readDataOfLength:0xA00];
            dscore::RomBanner bn;
            if (dscore::parseRomBanner(static_cast<const uint8_t *>(b.bytes), b.length, bn)) {
                result = [[DSROMBanner alloc] init];
                result.title = [NSString stringWithUTF8String:bn.title.c_str()] ?: @"";
                // 32x32 icon -> UIImage (premultiplied alpha; colours are fully opaque or transparent).
                CFDataRef data = CFDataCreate(kCFAllocatorDefault, reinterpret_cast<const UInt8 *>(bn.icon.data()),
                                              CFIndex(bn.icon.size() * 4));
                CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
                CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
                CGImageRef img = CGImageCreate(32, 32, 8, 32, 32 * 4, cs,
                                               (CGBitmapInfo)(kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst),
                                               provider, NULL, false, kCGRenderingIntentDefault);
                if (img) { result.icon = [UIImage imageWithCGImage:img]; CGImageRelease(img); }
                CGColorSpaceRelease(cs); CGDataProviderRelease(provider); CFRelease(data);
            }
        } @catch (NSException *) {
            result = nil;
        }
    }
    [fh closeFile];
    return result;
}

- (NSInteger)frameSkip { return _frameSkip; }
- (void)setFrameSkip:(NSInteger)n { _frameSkip = MAX(0, MIN(9, n)); _core->setFrameSkip((int)_frameSkip); }
- (NSInteger)renderThreads { return _renderThreads; }
- (void)setRenderThreads:(NSInteger)n { _renderThreads = MAX(0, MIN(7, n)); _core->setRenderThreads((int)_renderThreads); }
- (NSInteger)audioBufferedFrames { return (NSInteger)_core->audioBuffered(); }

- (void)setButtons:(uint32_t)mask { _buttons = mask; _core->setButtons(mask); }

- (void)setEmulationPaused:(BOOL)paused {
    const int sys = _core->system();
    if (sys == 6 && twinplay_n64_available()) twinplay_n64_set_paused(paused ? 1 : 0);
    if (sys == 7 && twinplay_3ds_available()) twinplay_3ds_set_paused(paused ? 1 : 0);
}

- (void)shutDownCore {
    if (_core) _core->shutDown();
}

- (void)setTouchDown:(BOOL)down x:(NSInteger)x y:(NSInteger)y {
    _touchX = (int)MAX(0, MIN(255, x));
    _touchY = (int)MAX(0, MIN(191, y));
    _touchDown = down;
}

- (CGImageRef)copyScreenImage:(NSInteger)screen {
    if (screen < 0 || screen > 1) return NULL;
    // Single-screen systems: the picture is screenWidth x screenHeight (GBA/GB sit in the
    // top-left of the 256-wide staging buffer; NES/SNES use that full width and more than 192 rows).
    const int outW = self.isGBA ? (int)_core->screenWidth() : dscore::kScreenWidth;
    const int outH = self.isGBA ? (int)_core->screenHeight() : dscore::kScreenHeight;
    const size_t pixels = size_t(outW) * size_t(outH);
    CFMutableDataRef bytes = CFDataCreateMutable(kCFAllocatorDefault, CFIndex(pixels * 4));
    CFDataSetLength(bytes, CFIndex(pixels * 4));
    {
        std::lock_guard<std::mutex> lk(_frameLock);
        const std::vector<uint32_t> &f = _frames[_frontIndex];
        int sc = _scales[_frontIndex];
        const size_t per = dscore::kScreenPixels * size_t(sc) * size_t(sc);
        const int w = dscore::kScreenWidth * sc;
        uint32_t *dst = reinterpret_cast<uint32_t *>(CFDataGetMutableBytePtr(bytes));
        for (int y = 0; y < outH; ++y)
            for (int x = 0; x < outW; ++x) {
                const size_t idx = size_t(screen) * per + size_t(y * sc) * size_t(w) + size_t(x * sc);
                dst[y * outW + x] = idx < f.size() ? f[idx] : 0xFF000000u;
            }
    }
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(bytes);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    // Pixels are 0xAARRGGBB stored little-endian => BGRA bytes.
    CGImageRef img = CGImageCreate(outW, outH, 8, 32, size_t(outW) * 4, cs,
                                   (CGBitmapInfo)(kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst),
                                   provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(provider);
    CFRelease(bytes);
    return img;
}

- (NSInteger)readAudio:(int16_t *)buffer maxFrames:(NSInteger)maxFrames {
    if (maxFrames <= 0) return 0;
    return (NSInteger)_core->readAudio(buffer, (size_t)maxFrames);
}

- (NSData *)saveState {
    std::vector<uint8_t> s = _core->saveState();
    if (s.empty()) return nil;
    return [NSData dataWithBytes:s.data() length:s.size()];
}

- (BOOL)loadState:(NSData *)data {
    const uint8_t *p = static_cast<const uint8_t *>(data.bytes);
    return _core->loadState(std::vector<uint8_t>(p, p + data.length)) ? YES : NO;
}

- (NSString *)romTitle { return _romTitle; }
- (NSString *)gameCode { return _gameCode; }
- (uint64_t)polygonsSubmitted { return _core ? _core->polygonsSubmitted() : 0; }
- (NSString *)statusText {
    std::lock_guard<std::mutex> lk(_frameLock);
    return [NSString stringWithUTF8String:_status.c_str()] ?: @"";
}

@end
