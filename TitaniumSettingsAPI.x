#import "TitaniumSettingsAPI.h"
#import <CoreFoundation/CoreFoundation.h>

#define TITANIUM_PREFS_PATH @"/var/mobile/Library/Preferences/com.dell.promotioncontrol.plist"
#define TITANIUM_PREFS_DOMAIN CFSTR("com.dell.promotioncontrol")
#define TITANIUM_CHANGED_NOTIFICATION CFSTR("com.dell.promotioncontrol.changed")

static NSDictionary *g_titaniumActiveConfig = nil;
static volatile int32_t g_titaniumActiveServerMode = 0;
static volatile int32_t g_titaniumCachedHz = 0;
static volatile int32_t g_titaniumCachedFPS = 0;
// Thêm các biến trạng thái mới
static volatile int32_t g_titaniumForceMaxDisplayRate = 0;
static volatile int32_t g_titaniumDisableThermalThrottle = 0;
static volatile int32_t g_titaniumOverclockCPU = 0;
static volatile int32_t g_titaniumOverclockGPU = 0;


BOOL g_isCurrentAppBlacklisted = NO;

static void Titanium_BridgePreferencesChanged(CFNotificationCenterRef center, void *observer,
                                              CFNotificationName name, const void *object,
                                              CFDictionaryRef userInfo);

static NSInteger Titanium_ClampRate(NSInteger value) {
    return MIN(MAX(value, 10), 244);
}

static NSString *Titanium_ServerName(NSInteger mode) {
    switch (MIN(MAX(mode, 0), 2)) {
        case 2: return @"ADMIN";
        case 1: return @"PREMIUM";
        default: return @"FREE";
    }
}

static NSInteger Titanium_ReadRate(NSDictionary *prefs, NSString *enabledKey, NSString *modeKey, NSString *customKey) {
    id enabled = prefs[enabledKey];
    if (![enabled respondsToSelector:@selector(boolValue)] || ![enabled boolValue]) return 0;

    id rawMode = prefs[modeKey];
    NSInteger mode = [rawMode respondsToSelector:@selector(integerValue)] ? [rawMode integerValue] : 0;
    if (mode == -1) {
        id rawCustom = prefs[customKey];
        if (![rawCustom respondsToSelector:@selector(integerValue)]) return 0;
        return Titanium_ClampRate([rawCustom integerValue]);
    }
    return mode > 0 ? Titanium_ClampRate(mode) : 0;
}

static NSDictionary *Titanium_ReadRootPreferences(void) {
    NSDictionary *fromFile = [NSDictionary dictionaryWithContentsOfFile:TITANIUM_PREFS_PATH];
    if ([fromFile isKindOfClass:[NSDictionary class]]) return fromFile;

    CFPropertyListRef copied = CFPreferencesCopyMultiple(NULL, TITANIUM_PREFS_DOMAIN,
        kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (!copied) return @{};
    id value = CFBridgingRelease(copied);
    return [value isKindOfClass:[NSDictionary class]] ? value : @{};
}

static NSDictionary *Titanium_ResolveActiveConfig(NSDictionary *root, NSInteger *modeOut) {
    NSInteger mode = [root[@"ActiveServerMode"] respondsToSelector:@selector(integerValue)]
        ? MIN(MAX([root[@"ActiveServerMode"] integerValue], 0), 2) : 0;
    NSString *serverName = Titanium_ServerName(mode);
    NSDictionary *profiles = [root[@"ServerProfiles"] isKindOfClass:[NSDictionary class]]
        ? root[@"ServerProfiles"] : @{};
    NSDictionary *selected = [profiles[serverName] isKindOfClass:[NSDictionary class]]
        ? profiles[serverName] : @{};
    NSMutableDictionary *resolved = [root mutableCopy] ?: [NSMutableDictionary dictionary];
    [resolved addEntriesFromDictionary:selected];
    resolved[@"ActiveServerMode"] = @(mode);

    // Match the runtime resolver: named profile first, then current-app profile.
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
    NSDictionary *appProfiles = [resolved[@"AppProfiles"] isKindOfClass:[NSDictionary class]]
        ? resolved[@"AppProfiles"] : @{};
    NSDictionary *appProfile = [appProfiles[bundleID] isKindOfClass:[NSDictionary class]]
        ? appProfiles[bundleID] : @{};
    NSString *namedProfileKey = [appProfile[@"profile"] isKindOfClass:[NSString class]]
        ? appProfile[@"profile"] : ([resolved[@"profile"] isKindOfClass:[NSString class]] ? resolved[@"profile"] : @"");
    NSDictionary *namedProfiles = [resolved[@"profiles"] isKindOfClass:[NSDictionary class]]
        ? resolved[@"profiles"] : @{};
    NSDictionary *namedProfile = [namedProfiles[namedProfileKey] isKindOfClass:[NSDictionary class]]
        ? namedProfiles[namedProfileKey] : @{};
    NSArray<NSString *> *allowedKeys = @[
        @"Enabled", @"RefreshRateEnabled", @"FPSOverrideEnabled", @"AdvancedDisplayEnforcement",
        @"FramePacing", @"ExactRateEnforcement", @"RefreshMode", @"FPSMode", @"CustomRefreshRate", @"CustomFPS",
        // Thêm các cờ mới
        @"ForceMaxDisplayRate", @"DisableThermalThrottle", @"OverclockCPU", @"OverclockGPU"
    ];
    for (NSString *key in allowedKeys) {
        id namedValue = namedProfile[key];
        if (namedValue) resolved[key] = namedValue;
        id appValue = appProfile[key];
        if (appValue) resolved[key] = appValue;
    }

    if (modeOut) *modeOut = mode;
    return [resolved copy];
}

// Compatibility surface requested by TitaniumCoreBridge.m. It returns the same
// resolved FREE/PREMIUM/ADMIN snapshot as the API plus the lowercase keys that
// the supplied hook sources expect ("enabled", "hz", "fps").
NSDictionary *Titanium_LoadSharedConfig(void) {
    NSDictionary *root = Titanium_ReadRootPreferences();
    NSInteger mode = 0;
    NSDictionary *active = Titanium_ResolveActiveConfig(root, &mode);
    NSInteger hz = Titanium_ReadRate(active, @"RefreshRateEnabled", @"RefreshMode", @"CustomRefreshRate");
    NSInteger fps = Titanium_ReadRate(active, @"FPSOverrideEnabled", @"FPSMode", @"CustomFPS");
    BOOL enabled = [active[@"Enabled"] respondsToSelector:@selector(boolValue)]
        ? [active[@"Enabled"] boolValue] : NO;
    // Đọc các cờ mới
    BOOL forceMaxDisplayRate = [active[@"ForceMaxDisplayRate"] respondsToSelector:@selector(boolValue)] ? [active[@"ForceMaxDisplayRate"] boolValue] : NO;
    BOOL disableThermalThrottle = [active[@"DisableThermalThrottle"] respondsToSelector:@selector(boolValue)] ? [active[@"DisableThermalThrottle"] boolValue] : NO;
    BOOL overclockCPU = [active[@"OverclockCPU"] respondsToSelector:@selector(boolValue)] ? [active[@"OverclockCPU"] boolValue] : NO;
    BOOL overclockGPU = [active[@"OverclockGPU"] respondsToSelector:@selector(boolValue)] ? [active[@"OverclockGPU"] boolValue] : NO;


    NSMutableDictionary *compat = [active mutableCopy] ?: [NSMutableDictionary dictionary];
    compat[@"enabled"] = @(enabled);
    compat[@"hz"] = @(hz);
    compat[@"fps"] = @(fps);
    compat[@"ActiveServerMode"] = @(mode);
    // Thêm các cờ mới vào compat dictionary
    compat[@"ForceMaxDisplayRate"] = @(forceMaxDisplayRate);
    compat[@"DisableThermalThrottle"] = @(disableThermalThrottle);
    compat[@"OverclockCPU"] = @(overclockCPU);
    compat[@"OverclockGPU"] = @(overclockGPU);

    return [compat copy];
}

@implementation TitaniumSettingsAPI

+ (instancetype)sharedAPI {
    static TitaniumSettingsAPI *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[TitaniumSettingsAPI alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) [self reloadSettings];
    return self;
}

- (void)reloadSettings {
    @synchronized (self) {
        NSDictionary *root = Titanium_ReadRootPreferences();
        NSInteger mode = 0;
        NSDictionary *active = Titanium_ResolveActiveConfig(root, &mode);
        NSInteger hz = Titanium_ReadRate(active, @"RefreshRateEnabled", @"RefreshMode", @"CustomRefreshRate");
        NSInteger fps = Titanium_ReadRate(active, @"FPSOverrideEnabled", @"FPSMode", @"CustomFPS");
        // Đọc các cờ mới
        BOOL forceMaxDisplayRate = [active[@"ForceMaxDisplayRate"] respondsToSelector:@selector(boolValue)] ? [active[@"ForceMaxDisplayRate"] boolValue] : NO;
        BOOL disableThermalThrottle = [active[@"DisableThermalThrottle"] respondsToSelector:@selector(boolValue)] ? [active[@"DisableThermalThrottle"] boolValue] : NO;
        BOOL overclockCPU = [active[@"OverclockCPU"] respondsToSelector:@selector(boolValue)] ? [active[@"OverclockCPU"] boolValue] : NO;
        BOOL overclockGPU = [active[@"OverclockGPU"] respondsToSelector:@selector(boolValue)] ? [active[@"OverclockGPU"] boolValue] : NO;

        @synchronized ([TitaniumSettingsAPI class]) {
            g_titaniumActiveConfig = [active copy] ?: @{};
        }
        __atomic_store_n(&g_titaniumActiveServerMode, (int32_t)mode, __ATOMIC_RELEASE);
        __atomic_store_n(&g_titaniumCachedHz, (int32_t)hz, __ATOMIC_RELEASE);
        __atomic_store_n(&g_titaniumCachedFPS, (int32_t)fps, __ATOMIC_RELEASE);
        // Cập nhật các biến trạng thái mới
        __atomic_store_n(&g_titaniumForceMaxDisplayRate, forceMaxDisplayRate ? 1 : 0, __ATOMIC_RELEASE);
        __atomic_store_n(&g_titaniumDisableThermalThrottle, disableThermalThrottle ? 1 : 0, __ATOMIC_RELEASE);
        __atomic_store_n(&g_titaniumOverclockCPU, overclockCPU ? 1 : 0, __ATOMIC_RELEASE);
        __atomic_store_n(&g_titaniumOverclockGPU, overclockGPU ? 1 : 0, __ATOMIC_RELEASE);


        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
        NSArray *excluded = [active[@"excludedApps"] isKindOfClass:[NSArray class]] ? active[@"excludedApps"] : @[];
        g_isCurrentAppBlacklisted = bundleID.length > 0 && [excluded containsObject:bundleID];
    }
}

- (NSInteger)getSelectedHz {
    @synchronized (self) {
        return Titanium_ReadRate(g_titaniumActiveConfig ?: @{}, @"RefreshRateEnabled", @"RefreshMode", @"CustomRefreshRate");
    }
}

- (NSInteger)getSelectedFPS {
    @synchronized (self) {
        return Titanium_ReadRate(g_titaniumActiveConfig ?: @{}, @"FPSOverrideEnabled", @"FPSMode", @"CustomFPS");
    }
}

- (BOOL)isEngineEnabled {
    @synchronized (self) {
        NSDictionary *prefs = g_titaniumActiveConfig ?: @{};
        BOOL enabled = [prefs[@"Enabled"] respondsToSelector:@selector(boolValue)] ? [prefs[@"Enabled"] boolValue] : NO;
        NSInteger mode = __atomic_load_n(&g_titaniumActiveServerMode, __ATOMIC_ACQUIRE);
        NSString *schedulerKey = mode == 2 ? @"AdminRenderSchedulerEnabled" :
            (mode == 1 ? @"PremiumRenderSchedulerEnabled" : @"FreeRenderSchedulerEnabled");
        NSString *hookKey = mode == 2 ? @"AdminCADisplayLinkHookEnabled" :
            (mode == 1 ? @"PremiumCADisplayLinkHookEnabled" : @"FreeCADisplayLinkHookEnabled");
        BOOL scheduler = !prefs[schedulerKey] || [prefs[schedulerKey] boolValue];
        BOOL hook = !prefs[hookKey] || [prefs[hookKey] boolValue];
        BOOL enforcement = !prefs[@"AdvancedDisplayEnforcement"] || [prefs[@"AdvancedDisplayEnforcement"] boolValue];
        BOOL pacing = !prefs[@"FramePacing"] || [prefs[@"FramePacing"] boolValue];
        NSInteger selectedHz = Titanium_ReadRate(prefs, @"RefreshRateEnabled", @"RefreshMode", @"CustomRefreshRate");
        NSInteger selectedFPS = Titanium_ReadRate(prefs, @"FPSOverrideEnabled", @"FPSMode", @"CustomFPS");
        return enabled && scheduler && hook && enforcement && pacing && !g_isCurrentAppBlacklisted &&
            (selectedHz > 0 || selectedFPS > 0);
    }
}

// Triển khai các phương thức mới
- (BOOL)isForceMaxDisplayRateEnabled {
    return __atomic_load_n(&g_titaniumForceMaxDisplayRate, __ATOMIC_ACQUIRE) != 0;
}

- (BOOL)isDisableThermalThrottleEnabled {
    return __atomic_load_n(&g_titaniumDisableThermalThrottle, __ATOMIC_ACQUIRE) != 0;
}

- (BOOL)isOverclockCPUEnabled {
    return __atomic_load_n(&g_titaniumOverclockCPU, __ATOMIC_ACQUIRE) != 0;
}

- (BOOL)isOverclockGPUEnabled {
    return __atomic_load_n(&g_titaniumOverclockGPU, __ATOMIC_ACQUIRE) != 0;
}


@end

NSInteger Titanium_GetMasterRate(void) {
    return [[TitaniumSettingsAPI sharedAPI] getSelectedHz];
}

NSInteger Titanium_GetMasterFPS(void) {
    return [[TitaniumSettingsAPI sharedAPI] getSelectedFPS];
}

BOOL Apex_IsMasterEnabled(void) {
    return [[TitaniumSettingsAPI sharedAPI] isEngineEnabled];
}

NSInteger Titanium_CurrentServerMode(void) {
    return (NSInteger)__atomic_load_n(&g_titaniumActiveServerMode, __ATOMIC_ACQUIRE);
}

NSInteger Titanium_CurrentTargetHz(void) {
    return (NSInteger)__atomic_load_n(&g_titaniumCachedHz, __ATOMIC_ACQUIRE);
}

NSInteger Titanium_CurrentTargetFPS(void) {
    return (NSInteger)__atomic_load_n(&g_titaniumCachedFPS, __ATOMIC_ACQUIRE);
}

static id Titanium_CachedConfigValue(NSString *key) {
    if (![key isKindOfClass:[NSString class]] || key.length == 0) return nil;
    @synchronized ([TitaniumSettingsAPI class]) {
        NSDictionary *config = g_titaniumActiveConfig;
        return [config isKindOfClass:[NSDictionary class]] ? config[key] : nil;
    }
}

BOOL Titanium_ConfigBool(NSString *key, BOOL fallback) {
    id value = Titanium_CachedConfigValue(key);
    // Thêm kiểm tra cho các cờ mới nếu chúng không được cấu hình cho tier hiện tại
    // và tier hiện tại không phải ADMIN (admin sẽ tự động set defaults)
    if (!value) {
        if ([key isEqualToString:@"ForceMaxDisplayRate"] ||
            [key isEqualToString:@"DisableThermalThrottle"] ||
            [key isEqualToString:@"OverclockCPU"] ||
            [key isEqualToString:@"OverclockGPU"]) {
            return NO; // Mặc định các cờ mạnh là OFF
        }
    }
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

NSInteger Titanium_ConfigInteger(NSString *key, NSInteger fallback) {
    id value = Titanium_CachedConfigValue(key);
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : fallback;
}

void Titanium_ForceUpdateRate(NSInteger hz, NSInteger fps) {
    NSInteger safeHz = Titanium_ClampRate(hz);
    NSInteger safeFPS = Titanium_ClampRate(fps);
    NSDictionary *root = Titanium_ReadRootPreferences();
    NSMutableDictionary *updatedRoot = [root mutableCopy] ?: [NSMutableDictionary dictionary];

    NSInteger mode = [updatedRoot[@"ActiveServerMode"] respondsToSelector:@selector(integerValue)]
        ? MIN(MAX([updatedRoot[@"ActiveServerMode"] integerValue], 0), 2) : 0;
    NSString *serverName = Titanium_ServerName(mode);
    NSMutableDictionary *profiles = [updatedRoot[@"ServerProfiles"] isKindOfClass:[NSDictionary class]]
        ? [updatedRoot[@"ServerProfiles"] mutableCopy] : [NSMutableDictionary dictionary];
    NSMutableDictionary *active = [profiles[serverName] isKindOfClass:[NSDictionary class]]
        ? [profiles[serverName] mutableCopy] : [NSMutableDictionary dictionary];

    NSDictionary *rateChanges = @{
        @"RefreshRateEnabled": @YES, @"RefreshMode": @(-1), @"CustomRefreshRate": @(safeHz),
        @"FPSOverrideEnabled": @YES, @"FPSMode": @(-1), @"CustomFPS": @(safeFPS)
    };
    [active addEntriesFromDictionary:rateChanges];
    [profiles setObject:[active copy] forKey:serverName];
    [updatedRoot addEntriesFromDictionary:rateChanges];
    updatedRoot[@"ServerProfiles"] = [profiles copy];
    updatedRoot[@"ServerProfilesSchemaVersion"] = @1;

    BOOL fileSaved = [updatedRoot writeToFile:TITANIUM_PREFS_PATH atomically:YES];
    CFPreferencesSetMultiple((__bridge CFDictionaryRef)updatedRoot, NULL, TITANIUM_PREFS_DOMAIN,
        kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    BOOL preferencesSaved = CFPreferencesAppSynchronize(TITANIUM_PREFS_DOMAIN);
    if (fileSaved || preferencesSaved) {
        [[TitaniumSettingsAPI sharedAPI] reloadSettings];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            TITANIUM_CHANGED_NOTIFICATION, NULL, NULL, true);
    }
}

// ----------------------------------------------------------------------------------------------------
// KHỞI TẠO HỆ THỐNG & ĐỒNG BỘ BỘ NHỚ ĐỆM CẤU HÌNH LÚC NẠP MODULE
// ----------------------------------------------------------------------------------------------------
static void Titanium_BridgePreferencesChanged(CFNotificationCenterRef center, void *observer,
                                              CFNotificationName name, const void *object,
                                              CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    // Keep the cached tier/rate snapshot in sync with the ControlApp. Hooks only
    // ever read atomics, so a settings change never triggers plist I/O inline.
    [[TitaniumSettingsAPI sharedAPI] reloadSettings];
}

__attribute__((constructor)) static void Titanium_BridgeInitializer(void) {
    @autoreleasepool {
        [[TitaniumSettingsAPI sharedAPI] reloadSettings];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            Titanium_BridgePreferencesChanged, TITANIUM_CHANGED_NOTIFICATION, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        // reloadSettings() already resolved the active FREE/PREMIUM/ADMIN snapshot
        // and refreshed g_isCurrentAppBlacklisted for this bundle. Refresh it here
        // explicitly so the initializer is self-contained.
        NSDictionary *config = Titanium_LoadSharedConfig();
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        NSArray *excluded = config[@"excludedApps"];
        if ([excluded isKindOfClass:[NSArray class]] && bundleID && [excluded containsObject:bundleID]) {
            g_isCurrentAppBlacklisted = YES;
        } else {
            g_isCurrentAppBlacklisted = NO;
        }

        // Do not pin CPU cores or request real-time scheduler privileges.
        // iOS owns core placement and DVFS; hook callbacks read the atomic cache.
    }
}
