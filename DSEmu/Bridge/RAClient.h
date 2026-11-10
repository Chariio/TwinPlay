// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// RetroAchievements through rcheevos' rc_client (MIT, Vendor/rcheevos). TwinPlay never stores
// the password: it is sent once to sign in, then only the returned token is kept (Keychain).
#import <Foundation/Foundation.h>
@class DSCoreBridge;

NS_ASSUME_NONNULL_BEGIN

/// rcheevos console ids.
typedef NS_ENUM(NSInteger, RAConsole) {
    RAConsoleGameBoy = 4,
    RAConsoleGameBoyAdvance = 5,
    RAConsoleGameBoyColor = 6,
    RAConsoleNES = 7,
    RAConsoleSNES = 3,
    RAConsoleNintendoDS = 18,
};

typedef NS_ENUM(NSInteger, RAEventKind) {
    RAEventKindUnlocked = 1,       // title, detail = description, points
    RAEventKindMastered = 2,       // every achievement of the game
    RAEventKindServerError = 3,
    RAEventKindDisconnected = 4,
    RAEventKindReconnected = 5,
    RAEventKindResetRequested = 6, // hardcore was turned on: the game must restart
};

/// One rc_client for the app. Login and game loading are asynchronous (completions on the main
/// queue). doFrame runs on the emulation thread after every emulated frame.
@interface RAClient : NSObject

@property (class, readonly) RAClient *shared;

/// Memory comes from this core while a game is loaded.
@property (nonatomic, weak, nullable) DSCoreBridge *core;
/// Unlocks, mastery and connection changes (main queue).
@property (nonatomic, copy, nullable) void (^onEvent)(RAEventKind kind, NSString *title, NSString *detail, NSInteger points);
/// Hardcore mode (RetroAchievements rules: no cheats, no loading save states). Default off.
@property (nonatomic) BOOL hardcore;
@property (nonatomic, readonly) BOOL loggedIn;
@property (nonatomic, readonly, nullable) NSString *displayName;
@property (nonatomic, readonly) NSInteger score;
@property (nonatomic, readonly) BOOL gameLoaded;
@property (nonatomic, readonly, nullable) NSString *gameTitle;
@property (nonatomic, readonly) NSInteger unlockedCount;
@property (nonatomic, readonly) NSInteger achievementCount;
/// "TwinPlay/1.1 (iOS 27.1) rcheevos/12.1" style user agent sent to the server.
@property (nonatomic, readonly) NSString *userAgent;

/// The completion gets the token to keep (never the password), or an error message.
- (void)loginWithUsername:(NSString *)username password:(NSString *)password
               completion:(void (^)(NSString *_Nullable token, NSString *_Nullable error))completion;
- (void)loginWithUsername:(NSString *)username token:(NSString *)token
               completion:(void (^)(NSString *_Nullable token, NSString *_Nullable error))completion;
- (void)logout;

/// Identifies the game by its hash and loads its achievements. `error` is nil on success; a
/// game RetroAchievements does not know finishes with total 0.
- (void)loadGameAtPath:(NSString *)path console:(RAConsole)console
            completion:(void (^)(NSString *_Nullable title, NSInteger unlocked, NSInteger total, NSString *_Nullable error))completion;
- (void)unloadGame;

/// Emulation thread, after each frame.
- (void)doFrame;
/// While paused (keeps the session alive, retries pending unlocks).
- (void)idle;
/// The game was reset / a save state was loaded: re-evaluate from scratch.
- (void)gameReset;
- (void)stateLoaded;

@end

NS_ASSUME_NONNULL_END
