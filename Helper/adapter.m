#import <Foundation/Foundation.h>
#include <dlfcn.h>
typedef void (^InfoBlock)(CFDictionaryRef);
typedef void (^PlayBlock)(Boolean);
typedef void (*GetInfoFn)(dispatch_queue_t, InfoBlock);
typedef void (*IsPlayingFn)(dispatch_queue_t, PlayBlock);
typedef Boolean (*SendFn)(uint32_t, CFDictionaryRef);
typedef void (*SetElapsedFn)(double);
typedef void (^ClientBlock)(id);
typedef void (*GetClientFn)(dispatch_queue_t, ClientBlock);
typedef CFStringRef (*ClientBundleFn)(id);

static void *mr(void) {
    static void *h; if (!h) h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW); return h;
}
static id jsonSafe(id v) {
    if ([v isKindOfClass:NSData.class]) return [(NSData *)v base64EncodedStringWithOptions:0];
    if ([v isKindOfClass:NSDate.class]) return @([(NSDate *)v timeIntervalSince1970]);
    if ([v isKindOfClass:NSString.class] || [v isKindOfClass:NSNumber.class]) return v;
    return nil;
}
void adapter_get(void *a, void *b) {
    __block NSDictionary *info = nil; __block BOOL playing = NO; __block int got = 0;
    ((GetInfoFn)dlsym(mr(), "MRMediaRemoteGetNowPlayingInfo"))(dispatch_get_main_queue(), ^(CFDictionaryRef d) { info = (__bridge NSDictionary *)d; got |= 1; });
    ((IsPlayingFn)dlsym(mr(), "MRMediaRemoteGetNowPlayingApplicationIsPlaying"))(dispatch_get_main_queue(), ^(Boolean p) { playing = p; got |= 2; });
    __block NSString *bundle = nil;
    GetClientFn getClient = (GetClientFn)dlsym(mr(), "MRMediaRemoteGetNowPlayingClient");
    ClientBundleFn parentOf = (ClientBundleFn)dlsym(mr(), "MRNowPlayingClientGetParentAppBundleIdentifier");
    ClientBundleFn bundleOf = (ClientBundleFn)dlsym(mr(), "MRNowPlayingClientGetBundleIdentifier");
    if (getClient && (parentOf || bundleOf)) {
        getClient(dispatch_get_main_queue(), ^(id client) {
            if (client) {
                CFStringRef value = parentOf ? parentOf(client) : NULL;
                if (!value && bundleOf) value = bundleOf(client);
                if (value) bundle = [(__bridge NSString *)value copy];
            }
            got |= 4;
        });
    } else {
        got |= 4;
    }
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:2];
    while (got != 7 && [end timeIntervalSinceNow] > 0) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, true);
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *k in info) { id v = jsonSafe(info[k]); if (v) out[k] = v; }
    out[@"_playing"] = @(playing);
    if (bundle) out[@"_bundle"] = bundle;
    NSData *j = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
    fwrite(j.bytes, 1, j.length, stdout); fputc('\n', stdout); fflush(stdout);
}
void adapter_send(void *a, void *b) {
    const char *c = getenv("ISLAND_CMD"); if (!c) return;
    ((SendFn)dlsym(mr(), "MRMediaRemoteSendCommand"))((uint32_t)atoi(c), NULL);
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:0.15];
    while ([end timeIntervalSinceNow] > 0) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, true);
}
void adapter_seek(void *a, void *b) {
    const char *c = getenv("ISLAND_SEEK"); if (!c) return;
    ((SetElapsedFn)dlsym(mr(), "MRMediaRemoteSetElapsedTime"))(atof(c));
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:0.15];
    while ([end timeIntervalSinceNow] > 0) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, true);
}

// Все клиенты Now Playing сразу: у каждого свой трек и своё состояние. Команды этим API адресно
// не уходят (они всегда достаются активному клиенту), поэтому здесь только чтение.
typedef id (*OriginFn)(void);
typedef void (*ClientInfoFn)(id, id, long, dispatch_queue_t, InfoBlock);
typedef void (^ClientsBlock)(NSArray *);
typedef void (*GetClientsFn)(dispatch_queue_t, ClientsBlock);

static NSString *bundleForClient(id client) {
    ClientBundleFn parentOf = (ClientBundleFn)dlsym(mr(), "MRNowPlayingClientGetParentAppBundleIdentifier");
    ClientBundleFn bundleOf = (ClientBundleFn)dlsym(mr(), "MRNowPlayingClientGetBundleIdentifier");
    CFStringRef value = parentOf ? parentOf(client) : NULL;
    if (!value && bundleOf) value = bundleOf(client);
    return value ? [(__bridge NSString *)value copy] : nil;
}

void adapter_all(void *a, void *b) {
    OriginFn localOrigin = (OriginFn)dlsym(mr(), "MRMediaRemoteGetLocalOrigin");
    GetClientsFn getClients = (GetClientsFn)dlsym(mr(), "MRMediaRemoteGetNowPlayingClients");
    ClientInfoFn infoFor = (ClientInfoFn)dlsym(mr(), "MRMediaRemoteGetNowPlayingInfoForClient");
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSMutableArray *list = [NSMutableArray array];
    out[@"clients"] = list;

    __block NSArray *clients = nil;
    __block BOOL gotClients = NO;
    if (getClients) getClients(dispatch_get_main_queue(), ^(NSArray *c) { clients = c; gotClients = YES; });
    else gotClients = YES;

    // Активный клиент и его признак «играет» — как в adapter_get.
    __block BOOL playing = NO; __block int got = 0;
    ((IsPlayingFn)dlsym(mr(), "MRMediaRemoteGetNowPlayingApplicationIsPlaying"))(dispatch_get_main_queue(), ^(Boolean p) { playing = p; got |= 1; });
    __block NSString *active = nil;
    GetClientFn getClient = (GetClientFn)dlsym(mr(), "MRMediaRemoteGetNowPlayingClient");
    if (getClient) {
        getClient(dispatch_get_main_queue(), ^(id client) { if (client) active = bundleForClient(client); got |= 2; });
    } else {
        got |= 2;
    }
    // Обложку отдаёт только общий запрос — и только для активного клиента.
    __block NSData *activeArtwork = nil;
    ((GetInfoFn)dlsym(mr(), "MRMediaRemoteGetNowPlayingInfo"))(dispatch_get_main_queue(), ^(CFDictionaryRef d) {
        id art = ((__bridge NSDictionary *)d)[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
        if ([art isKindOfClass:NSData.class]) activeArtwork = art;
        got |= 4;
    });
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:2];
    while ((!gotClients || got != 7) && [end timeIntervalSinceNow] > 0) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, true);
    if (active) out[@"active"] = active;
    out[@"activePlaying"] = @(playing);

    id origin = localOrigin ? localOrigin() : nil;
    __block int pending = 0;
    NSMutableArray *slots = [NSMutableArray array];
    for (id client in clients) {
        NSString *bundle = bundleForClient(client);
        if (!bundle || !origin || !infoFor) continue;
        NSMutableDictionary *slot = [NSMutableDictionary dictionaryWithObject:bundle forKey:@"bundle"];
        [slots addObject:slot];
        pending++;
        @try {
            infoFor(client, origin, 0, dispatch_get_main_queue(), ^(CFDictionaryRef d) {
                NSMutableDictionary *info = [NSMutableDictionary dictionary];
                for (NSString *k in (__bridge NSDictionary *)d) { id v = jsonSafe(((__bridge NSDictionary *)d)[k]); if (v) info[k] = v; }
                slot[@"info"] = info;
                pending--;
            });
        } @catch (NSException *e) { pending--; }
    }
    end = [NSDate dateWithTimeIntervalSinceNow:2.5];
    while (pending > 0 && [end timeIntervalSinceNow] > 0) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, true);
    for (NSMutableDictionary *slot in slots) {
        if (!slot[@"info"]) continue;
        if (activeArtwork && [slot[@"bundle"] isEqualToString:active] && !slot[@"info"][@"kMRMediaRemoteNowPlayingInfoArtworkData"]) {
            slot[@"info"][@"kMRMediaRemoteNowPlayingInfoArtworkData"] = [activeArtwork base64EncodedStringWithOptions:0];
        }
        [list addObject:slot];
    }

    NSData *j = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
    fwrite(j.bytes, 1, j.length, stdout); fputc('\n', stdout); fflush(stdout);
}
