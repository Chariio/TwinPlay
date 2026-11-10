// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Objective-C facade over the C++ EmulatorCore so Swift can use it.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
@class UIImage;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, DSCoreKind) {
    DSCoreKindTestPattern = 0,
    DSCoreKindInterpreter = 1,
    DSCoreKindGBA NS_SWIFT_NAME(gba) = 2,   // Game Boy Advance (single 240x160 screen)
    DSCoreKindGB NS_SWIFT_NAME(gb) = 3,     // Game Boy / Game Boy Color (single 160x144 screen)
    DSCoreKindNES NS_SWIFT_NAME(nes) = 4,   // NES (single 256x240 screen)
    DSCoreKindSNES NS_SWIFT_NAME(snes) = 5, // Super NES (single 256x224 screen)
    DSCoreKindN64 NS_SWIFT_NAME(n64) = 6,   // N64 (cached interpreter, no JIT)
    DSCoreKindN3DS NS_SWIFT_NAME(n3ds) = 7, // 3DS (Azahar FastInterp, no JIT)
};

/// Basic identity of a cartridge read from its header (DS or GBA). Used to find box art.
@interface DSROMHeaderInfo : NSObject
@property (nonatomic, copy) NSString *title;      // header title, e.g. "MARIOKART DS" / "GBAZELDA MC"
@property (nonatomic, copy) NSString *gameCode;   // 4 characters, last one is the region (E USA, P Europe, J Japan)
@property (nonatomic) BOOL isGBA;
/// 0 DS, 1 GBA, 2 Game Boy, 3 Game Boy Color, 4 NES, 5 Super NES, 6 N64, 7 3DS.
@property (nonatomic) NSInteger system;
@end

/// The built-in icon and title stored inside a cartridge image (read from the file, never downloaded).
@interface DSROMBanner : NSObject
@property (nonatomic, copy) NSString *title;          // English title, lines separated by "\n"
@property (nonatomic, strong, nullable) UIImage *icon; // 32x32
@end

/// Thread-safety: runFrame/loadROM/reset/saveState/loadState must be called from
/// one thread at a time (the emulation thread). Input setters, copyScreenImage,
/// statusText and readAudio may be called from any thread.
@interface DSCoreBridge : NSObject

- (instancetype)initWithKind:(DSCoreKind)kind NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Optional: the user's own ARM7 BIOS dump. Only its KEY1 table is used, to
/// decrypt encrypted cartridge secure areas. Call before loadROM. Never bundled.
- (void)setARM7BIOSURL:(NSURL *)url NS_SWIFT_NAME(setARM7BIOS(_:));
/// Optional low-level BIOS from the user's own dumps (DS: bios9 + bios7 [+ firmware]; GBA: bios9 =
/// gba_bios.bin). Pass nil for all to use the built-in HLE BIOS. Call before loadROM.
- (BOOL)setLLEBIOS9:(nullable NSData *)bios9 bios7:(nullable NSData *)bios7 firmware:(nullable NSData *)firmware
       bootFirmware:(BOOL)bootFirmware NS_SWIFT_NAME(setLLEBIOS(bios9:bios7:firmware:bootFirmware:));
@property (nonatomic, readonly) BOOL usingLLEBIOS;

- (BOOL)loadROMAtURL:(NSURL *)url error:(NSError **)error NS_SWIFT_NAME(loadROM(at:));
/// Cartridge save file (EEPROM/FRAM/Flash). Loads it now if it exists; the bridge
/// then writes it back automatically ~1 s after the game stops writing, and on flushSave.
- (void)attachSaveFileURL:(NSURL *)url NS_SWIFT_NAME(attachSaveFile(_:));
/// Writes pending save data to disk. Call from the emulation thread (or when it is stopped).
- (void)flushSave;
/// Save chip override: 0 Auto, 1 EEPROM 0.5K, 2 EEPROM 8K, 3 EEPROM 64K, 4 EEPROM 128K,
/// 5 FRAM 32K, 6 Flash 256K, 7 Flash 512K, 8 Flash 1M, 9 Flash 8M. Set before attachSaveFile
/// (or call reset afterwards).
@property (nonatomic) NSInteger saveTypeOverride;
/// 3D enhancements (not hardware behaviour): antiAlias 0 off, 1 edge smoothing, 2 2x supersampling;
/// bilinear texture filtering; widescreen 16:9 projection (experimental).
- (void)setAntiAlias:(NSInteger)antiAlias textureFilter:(BOOL)textureFilter widescreen:(BOOL)widescreen
    NS_SWIFT_NAME(setEnhancements(antiAlias:textureFilter:widescreen:));
/// Detected or forced chip, e.g. "EEPROM 8 KB".
@property (nonatomic, readonly) NSString *saveTypeDescription;
/// The save file did not match the game's chip. The original is kept as "<name>.sav.bak".
@property (nonatomic, readonly) BOOL loadedSaveRejected;
/// Moves the save file to "<name>.sav.bak" and gives the game a blank chip. Call while stopped
/// or on the emulation thread, then reset.
- (void)deleteSaveData;

- (void)reset;
- (void)runFrame;

- (void)setButtons:(uint32_t)mask NS_SWIFT_NAME(setButtons(_:));
/// Pause or resume a free-running N64/3DS core. Safe to call from the main thread (does not join).
- (void)setEmulationPaused:(BOOL)paused;
/// Stop and join a free-running N64/3DS core. Call when leaving a game, not on willResignActive.
- (void)shutDownCore;
- (void)setTouchDown:(BOOL)down x:(NSInteger)x y:(NSInteger)y NS_SWIFT_NAME(setTouch(down:x:y:));
/// Analog stick. stick 0 is the N64 stick / 3DS circle pad; stick 1 is the 3DS C-stick.
/// Each axis is -1..1. Ignored by the other systems.
- (void)setAnalogX:(float)x y:(float)y stick:(NSInteger)stick NS_SWIFT_NAME(setAnalog(x:y:stick:));

/// Sequence number of the newest complete frame (increments only when a picture was drawn).
@property (nonatomic, readonly) uint64_t frameSequence;
/// Copies the newest complete frame (top screen rows 0-191, then bottom rows 192-383,
/// 256 pixels each, BGRA) into dst (256*384*4 bytes). Both screens always come from the
/// same emulated frame. Returns its sequence number. Any thread.
- (uint64_t)copyFrameInto:(uint32_t *)dst NS_SWIFT_NAME(copyFrame(into:));

/// Like copyFrame(into:) but at the 3D internal resolution: (256*scale) x (384*scale) pixels.
/// capacity is in pixels; on success *scale is set (0 if the buffer was too small).
- (uint64_t)copyHiResFrameInto:(uint32_t *)dst capacity:(NSInteger)pixels scale:(NSInteger *)scale
    NS_SWIFT_NAME(copyHiResFrame(into:capacity:scale:));
/// 3D internal resolution 1...4. Emulation thread.
@property (nonatomic) NSInteger renderScale;
/// DS sound: cubic resampling (YES, default) or raw sample-and-hold like the hardware DAC.
- (void)setHighQualityAudio:(BOOL)on;
/// True while the game used display capture in the last ~2 s (results screens, transitions).
@property (nonatomic, readonly) BOOL captureInUse;
/// Frames run by the emulation thread (heartbeat for the stall watchdog). Thread-safe.
@property (nonatomic, readonly) uint64_t framesRun;
/// Frames in a row with no CPU activity (the game locked up). Thread-safe.
@property (nonatomic, readonly) NSInteger stuckFrames;
/// Times the core's IRQ-livelock watchdog had to recover a game stuck in an interrupt wait. Thread-safe.
@property (nonatomic, readonly) uint64_t irqLivelockRecoveries;
/// Times the emulation thread waited >100 ms for the 3D worker threads (re-woken each time). Thread-safe.
@property (nonatomic, readonly) uint64_t renderPoolStalls;
/// Hardware snapshot for the diagnostics log. Call on the emulation thread.
- (NSString *)freezeReport;
/// 256x384 picture of the newest frame (both screens), e.g. for save-slot thumbnails
/// (GBA: the 240x160 screen only).
- (nullable CGImageRef)copyThumbnailImage CF_RETURNS_RETAINED NS_SWIFT_NAME(copyThumbnailImage());
/// Reads the banner from a .nds file (header + banner only). For .gba files the title comes
/// from the cartridge header and there is no icon. Any thread.
+ (nullable DSROMBanner *)bannerForROMAtURL:(NSURL *)url NS_SWIFT_NAME(banner(forROMAt:));
/// True if the file is a Game Boy Advance image (by extension or header). Any thread.
+ (BOOL)isGBAROMAtURL:(NSURL *)url NS_SWIFT_NAME(isGBAROM(at:));
/// True if the file is an NES image (iNES header, or a .nes name). Any thread.
+ (BOOL)isNESROMAtURL:(NSURL *)url NS_SWIFT_NAME(isNESROM(at:));
/// True if the file is a Super NES image (.sfc/.smc, or a LoROM/HiROM header). Any thread.
+ (BOOL)isSNESROMAtURL:(NSURL *)url NS_SWIFT_NAME(isSNESROM(at:));
/// .n64/.z64/.v64, or the three N64 byte orders in the first four bytes.
+ (BOOL)isN64ROMAtURL:(NSURL *)url NS_SWIFT_NAME(isN64ROM(at:));
/// .3ds/.cci/.cxi, or an NCSD/NCCH magic at 0x100.
+ (BOOL)is3DSROMAtURL:(NSURL *)url NS_SWIFT_NAME(is3DSROM(at:));
/// 0 if the file is not a Game Boy cartridge, 2 for Game Boy, 3 for Game Boy Color
/// (CGB flag in the header, or the .gbc extension). Any thread.
+ (NSInteger)gameBoySystemOfROMAtURL:(NSURL *)url NS_SWIFT_NAME(gameBoySystem(ofROMAt:));
/// Writes a short report (signal, faulting address, backtrace with the image load address for
/// symbolication) to `directory`/crash-<unix time>.log when the app crashes, then lets the
/// system crash report proceed. Call once at launch.
+ (void)installCrashLoggerInDirectory:(NSString *)directory NS_SWIFT_NAME(installCrashLogger(directory:));
/// Short context line (game, settings) included in a crash report. Any thread.
+ (void)setCrashContext:(NSString *)context NS_SWIFT_NAME(setCrashContext(_:));
/// Header title and game code of a DS or GBA file. Any thread.
+ (nullable DSROMHeaderInfo *)headerInfoForROMAtURL:(NSURL *)url NS_SWIFT_NAME(headerInfo(forROMAt:));

/// The loaded game is a Game Boy Advance game: one screen of screenWidth x screenHeight
/// (240x160) in the top-left corner of screen 0's 256x192 area; screen 1 is unused.
@property (nonatomic, readonly) BOOL isGBA;
/// The loaded game is a Game Boy / Game Boy Color game (isGBA is also true: single screen).
@property (nonatomic, readonly) BOOL isGameBoy;
/// The loaded Game Boy game runs in Game Boy Color mode.
@property (nonatomic, readonly) BOOL isGameBoyColor;
/// Game Boy only: DMG shade palette (0 green, 1 gray) and GBC LCD colour correction. Any time.
- (void)setGameBoyPalette:(NSInteger)palette colorCorrection:(BOOL)correct NS_SWIFT_NAME(setGameBoyVideo(palette:colorCorrection:));
@property (nonatomic, readonly) NSInteger screenWidth;
@property (nonatomic, readonly) NSInteger screenHeight;
/// 3DS Vulkan/MoltenVK present layer (CAMetalLayer*). Nil for other systems.
- (nullable void *)n3dsMetalLayer;
- (nullable void *)n3dsMetalView;
- (void)setN3DSSurfaceWidth:(NSInteger)width height:(NSInteger)height scale:(float)scale;
- (void)setN3DSScreenLayoutFbWidth:(NSInteger)fbWidth fbHeight:(NSInteger)fbHeight scale:(float)scale
                            topX:(NSInteger)topX topY:(NSInteger)topY topW:(NSInteger)topW topH:(NSInteger)topH
                            bottomX:(NSInteger)bottomX bottomY:(NSInteger)bottomY bottomW:(NSInteger)bottomW bottomH:(NSInteger)bottomH;
- (void)setN3DSCpuClockPercentage:(NSInteger)percent;
- (void)n3dsFrameTimingLastMs:(double *)lastMs maxMs:(double *)maxMs p95Ms:(double *)p95Ms;
@property (nonatomic, readonly) BOOL n3dsUsingVulkan;
@property (nonatomic, readonly) uint64_t n3dsFrameCount;
- (void)setN3DSPresentReady:(BOOL)ready;
- (void)compositeN3DSToLayer:(void *)destLayer scale:(float)scale
                         topX:(float)topX topY:(float)topY topW:(float)topW topH:(float)topH
                      bottomX:(float)bottomX bottomY:(float)bottomY bottomW:(float)bottomW bottomH:(float)bottomH;


/// Frame skip: draw 1 of every (n + 1) frames; emulation speed is unaffected. Emulation thread.
@property (nonatomic) NSInteger frameSkip;
/// Extra 3D rasterizer threads (0 = none). Emulation thread.
@property (nonatomic) NSInteger renderThreads;
/// Audio frames produced but not yet played. Any thread.
@property (nonatomic, readonly) NSInteger audioBufferedFrames;

/// screen 0 = top, 1 = bottom. Returns a new 256x192 image of the latest frame (GBA: 240x160).
- (nullable CGImageRef)copyScreenImage:(NSInteger)screen CF_RETURNS_RETAINED NS_SWIFT_NAME(copyScreenImage(_:));

/// Interleaved stereo Int16 @ 48 kHz. Returns frames written. Never blocks.
- (NSInteger)readAudio:(int16_t *)buffer maxFrames:(NSInteger)maxFrames NS_SWIFT_NAME(readAudio(_:maxFrames:));

/// Cheats. system is "ds", "gba" or "gb" (GB and GBC). Validates one code (several lines allowed):
/// nil when it is fine, else a short message. Any thread.
+ (nullable NSString *)cheatErrorForCode:(NSString *)code system:(NSString *)system NS_SWIFT_NAME(cheatError(code:system:));
/// Replaces the active cheats (invalid ones are skipped). Applied after every frame. Emulation thread.
- (void)setCheatCodes:(NSArray<NSString *> *)codes system:(NSString *)system NS_SWIFT_NAME(setCheats(_:system:));
/// RetroAchievements: `count` bytes at `address` in rcheevos' memory layout for the loaded
/// console. Plain memory, no side effects. Returns how many bytes exist there. Any thread.
- (uint32_t)achievementRead:(uint32_t)address buffer:(uint8_t *)buffer count:(uint32_t)count;
- (nullable NSData *)saveState;
- (BOOL)loadState:(NSData *)data;

@property (nonatomic, readonly, copy) NSString *romTitle;
@property (nonatomic, readonly, copy) NSString *gameCode;
/// DS polygons submitted since the game started. 0 on every other system. Cheap to read.
@property (nonatomic, readonly) uint64_t polygonsSubmitted;
@property (nonatomic, readonly, copy) NSString *statusText;

@end

NS_ASSUME_NONNULL_END
