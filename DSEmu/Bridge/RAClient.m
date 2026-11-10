// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
#import "RAClient.h"
#import "DSCoreBridge.h"
#import <UIKit/UIKit.h>
#include "rc_client.h"
#include "rc_consoles.h"
#include "rc_error.h"

@interface RAClient ()
@property (nonatomic) rc_client_t *client;
@property (nonatomic, strong) NSURLSession *session;
@end

typedef void (^RALoginBlock)(int result, NSString *_Nullable error);

static RAClient *RASelf(const rc_client_t *client) { return (__bridge RAClient *)rc_client_get_userdata(client); }

// rcheevos asks for memory in its own layout for the console; the core maps it.
static uint32_t RC_CCONV ra_read_memory(uint32_t address, uint8_t *buffer, uint32_t num_bytes, rc_client_t *client) {
    DSCoreBridge *core = RASelf(client).core;
    if (!core) return 0;
    return [core achievementRead:address buffer:buffer count:num_bytes];
}

// HTTP for rcheevos: POST (form data) or GET, answered on a background queue.
static void RC_CCONV ra_server_call(const rc_api_request_t *request, rc_client_server_callback_t callback,
                                    void *callback_data, rc_client_t *client) {
    RAClient *me = RASelf(client);
    NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:request->url]];
    if (!url) {
        rc_api_server_response_t r = { "", 0, RC_API_SERVER_RESPONSE_CLIENT_ERROR };
        callback(&r, callback_data);
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setValue:me.userAgent forHTTPHeaderField:@"User-Agent"];
    req.timeoutInterval = 30;
    if (request->post_data) {
        req.HTTPMethod = @"POST";
        req.HTTPBody = [NSData dataWithBytes:request->post_data length:strlen(request->post_data)];
        NSString *type = request->content_type ? [NSString stringWithUTF8String:request->content_type] : @"application/x-www-form-urlencoded";
        [req setValue:type forHTTPHeaderField:@"Content-Type"];
    }
    [[me.session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSMutableData *body = [NSMutableData dataWithData:data ?: [NSData data]];
        [body appendBytes:"\0" length:1];   // rcheevos reads body_length bytes; keep it NUL-terminated anyway
        rc_api_server_response_t r;
        r.body = body.bytes;
        r.body_length = data.length;
        r.http_status_code = error ? RC_API_SERVER_RESPONSE_RETRYABLE_CLIENT_ERROR : (int)status;
        callback(&r, callback_data);
    }] resume];
}

static NSString *RAString(const char *s) { return s ? ([NSString stringWithUTF8String:s] ?: @"") : @""; }

static void RC_CCONV ra_event(const rc_client_event_t *event, rc_client_t *client) {
    RAClient *me = RASelf(client);
    void (^handler)(RAEventKind, NSString *, NSString *, NSInteger) = me.onEvent;
    if (!handler) return;
    RAEventKind kind; NSString *title = @"", *detail = @""; NSInteger points = 0;
    switch (event->type) {
        case RC_CLIENT_EVENT_ACHIEVEMENT_TRIGGERED:
            kind = RAEventKindUnlocked;
            title = RAString(event->achievement->title); detail = RAString(event->achievement->description);
            points = event->achievement->points;
            break;
        case RC_CLIENT_EVENT_GAME_COMPLETED: {
            kind = RAEventKindMastered;
            const rc_client_game_t *g = rc_client_get_game_info(client);
            title = g ? RAString(g->title) : @"";
            break;
        }
        case RC_CLIENT_EVENT_SERVER_ERROR:
            kind = RAEventKindServerError;
            detail = event->server_error ? RAString(event->server_error->error_message) : @"";
            break;
        case RC_CLIENT_EVENT_DISCONNECTED: kind = RAEventKindDisconnected; break;
        case RC_CLIENT_EVENT_RECONNECTED: kind = RAEventKindReconnected; break;
        case RC_CLIENT_EVENT_RESET: kind = RAEventKindResetRequested; break;
        default: return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ handler(kind, title, detail, points); });
}

static void RC_CCONV ra_callback(int result, const char *error_message, rc_client_t *client, void *userdata) {
    RALoginBlock block = (__bridge_transfer RALoginBlock)userdata;
    NSString *err = result == RC_OK ? nil : (error_message ? RAString(error_message) : RAString(rc_error_str(result)));
    dispatch_async(dispatch_get_main_queue(), ^{ block(result, err); });
}

static void RC_CCONV ra_log(const char *message, const rc_client_t *client) {
#if DEBUG
    NSLog(@"[rcheevos] %s", message);
#endif
}

@implementation RAClient

+ (RAClient *)shared {
    static RAClient *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[RAClient alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.HTTPCookieStorage = nil; cfg.URLCache = nil;
        _session = [NSURLSession sessionWithConfiguration:cfg];
        _client = rc_client_create(ra_read_memory, ra_server_call);
        rc_client_set_userdata(_client, (__bridge void *)self);
        rc_client_set_event_handler(_client, ra_event);
        rc_client_enable_logging(_client, RC_CLIENT_LOG_LEVEL_WARN, ra_log);
        rc_client_set_hardcore_enabled(_client, 0);   // softcore by default
        rc_client_set_unofficial_enabled(_client, 0);
        NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"1";
        char clause[64] = {0};
        rc_client_get_user_agent_clause(_client, clause, sizeof clause);
        _userAgent = [NSString stringWithFormat:@"TwinPlay/%@ (iOS %@) %s", version, UIDevice.currentDevice.systemVersion, clause];
    }
    return self;
}

- (void)dealloc { if (_client) rc_client_destroy(_client); }

- (BOOL)hardcore { return rc_client_get_hardcore_enabled(_client) != 0; }
- (void)setHardcore:(BOOL)on { rc_client_set_hardcore_enabled(_client, on ? 1 : 0); }

- (BOOL)loggedIn { return rc_client_get_user_info(_client) != NULL; }
- (NSString *)displayName {
    const rc_client_user_t *u = rc_client_get_user_info(_client);
    return u ? RAString(u->display_name) : nil;
}
- (NSInteger)score {
    const rc_client_user_t *u = rc_client_get_user_info(_client);
    return u ? (self.hardcore ? u->score : u->score_softcore) : 0;
}
- (BOOL)gameLoaded { return rc_client_is_game_loaded(_client) != 0; }
- (NSString *)gameTitle {
    const rc_client_game_t *g = rc_client_get_game_info(_client);
    return g ? RAString(g->title) : nil;
}
- (NSInteger)unlockedCount { rc_client_user_game_summary_t s = {0}; rc_client_get_user_game_summary(_client, &s); return s.num_unlocked_achievements; }
- (NSInteger)achievementCount { rc_client_user_game_summary_t s = {0}; rc_client_get_user_game_summary(_client, &s); return s.num_core_achievements; }

- (void)finishLogin:(int)result error:(NSString *)error completion:(void (^)(NSString *, NSString *))completion {
    const rc_client_user_t *u = result == RC_OK ? rc_client_get_user_info(_client) : NULL;
    if (u && u->token) completion(RAString(u->token), nil);
    else completion(nil, error ?: @"Sign-in failed.");
}

- (void)loginWithUsername:(NSString *)username password:(NSString *)password completion:(void (^)(NSString *, NSString *))completion {
    __weak RAClient *weakSelf = self;
    RALoginBlock done = ^(int result, NSString *error) { [weakSelf finishLogin:result error:error completion:completion]; };
    rc_client_begin_login_with_password(_client, username.UTF8String, password.UTF8String, ra_callback, (__bridge_retained void *)[done copy]);
}

- (void)loginWithUsername:(NSString *)username token:(NSString *)token completion:(void (^)(NSString *, NSString *))completion {
    __weak RAClient *weakSelf = self;
    RALoginBlock done = ^(int result, NSString *error) { [weakSelf finishLogin:result error:error completion:completion]; };
    rc_client_begin_login_with_token(_client, username.UTF8String, token.UTF8String, ra_callback, (__bridge_retained void *)[done copy]);
}

- (void)logout { rc_client_unload_game(_client); rc_client_logout(_client); }

- (void)loadGameAtPath:(NSString *)path console:(RAConsole)console
            completion:(void (^)(NSString *, NSInteger, NSInteger, NSString *))completion {
    __weak RAClient *weakSelf = self;
    RALoginBlock done = ^(int result, NSString *error) {
        RAClient *me = weakSelf;
        if (!me) return;
        if (result == RC_OK) completion(me.gameTitle, me.unlockedCount, me.achievementCount, nil);
        else completion(nil, 0, 0, error);
    };
    rc_client_begin_identify_and_load_game(_client, (uint32_t)console, path.fileSystemRepresentation, NULL, 0,
                                           ra_callback, (__bridge_retained void *)[done copy]);
}

- (void)unloadGame { rc_client_unload_game(_client); }
- (void)doFrame { rc_client_do_frame(_client); }
- (void)idle { rc_client_idle(_client); }
- (void)gameReset { rc_client_reset(_client); }
- (void)stateLoaded { rc_client_deserialize_progress_sized(_client, NULL, 0); }

@end
