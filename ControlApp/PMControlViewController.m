#import "PMControlViewController.h"
#import "PMPremiumOptimizationEngine.h"
#import "PMEarthNetworkViewControllers.h"
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import <mach/mach.h>
#import <mach/host_info.h>
#import <stdint.h>
#import <math.h>
#import <float.h>
#import <stdlib.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <mach/task_info.h>
#import <Metal/Metal.h>
#import <dlfcn.h>
#import <stdio.h>
#import <CommonCrypto/CommonDigest.h>

static NSString * const PMDomainName = @"com.dell.promotioncontrol";
static NSString * const PMChangedNotification = @"com.dell.promotioncontrol.changed";
static NSInteger PMLastWriteState = -1; // -1 unknown, 0 not verified, 1 verified
static BOOL PMEnglishSelected = NO;
static BOOL PMLightThemeSelected = NO;
// Protected-mode authorization uses the injected tweak installation ID when
// available. Without an injected runtime, a process-scoped fallback still lets
// the standalone app authenticate its local Premium/Admin controls.
static NSString * const PMPremiumActivationHistoryKey = @"PMServerPremiumPreviouslyActivated";
static NSString * const PMPremiumAuthorizedInstallationIDKey = @"PMServerPremiumAuthorizedInstallationID";
static NSString * const PMPremiumSelectedModeKey = @"PMServerPremiumSelectedMode";
static NSString * const PMAdminSelectedModeKey = @"PMServerAdminSelectedMode";
static NSString * const PMAdminAuthorizedInstallationIDKey = @"PMServerAdminAuthorizedInstallationID";
static NSString * const PMLastActiveServerModeKey = @"PMServerLastActiveMode";
static NSString * const PMLastActiveServerAtKey = @"PMServerLastActiveAt";
static NSString * const PMProtectedAuthFailureCountPrefix = @"PMProtectedAuthFailureCount_";
static NSString * const PMProtectedAuthLockUntilPrefix = @"PMProtectedAuthLockUntil_";
static BOOL PMServerPremiumSessionActive = NO;
static BOOL PMServerAdminSessionActive = NO;

static BOOL PMPremiumWasEverActivated(void)
{
    return [[NSUserDefaults standardUserDefaults] boolForKey:PMPremiumActivationHistoryKey];
}

static NSString *PMPremiumTweakInstallationID(void)
{
    typedef const char *(*PMTweakInstallationIDFunction)(void);
    void *symbol = dlsym(RTLD_DEFAULT, "PMControlTweakInstallationID");
    if (!symbol) return nil;
    PMTweakInstallationIDFunction readIdentifier = (PMTweakInstallationIDFunction)symbol;
    const char *rawIdentifier = readIdentifier();
    if (!rawIdentifier || rawIdentifier[0] == '\0') return nil;
    NSString *identifier = [NSString stringWithUTF8String:rawIdentifier];
    if (![identifier isKindOfClass:[NSString class]] || identifier.length < 32 || identifier.length > 128) return nil;
    return [identifier copy];
}

static BOOL PMPremiumTweakRuntimeIsPresent(void)
{
    typedef int (*PMTweakPresenceFunction)(void);
    void *symbol = dlsym(RTLD_DEFAULT, "PMControlTweakRuntimeMarker");
    if (!symbol) return NO;
    PMTweakPresenceFunction marker = (PMTweakPresenceFunction)symbol;
    return marker() == 0x504D4354 && PMPremiumTweakInstallationID().length >= 32;
}

// When injected, bind authorization to the package identity so remove/reinstall
// rotates access. Without the marker, use a process-only identity: password
// unlock still works in this app, but no stale grant survives a relaunch.
static NSString *PMCurrentServerAuthorizationInstallationID(void)
{
    if (PMPremiumTweakRuntimeIsPresent()) {
        NSString *runtimeIdentifier = PMPremiumTweakInstallationID();
        if (runtimeIdentifier.length >= 32) return runtimeIdentifier;
    }
    static NSString *sessionIdentifier = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *rawIdentifier = [[NSUUID UUID] UUIDString];
        sessionIdentifier = [rawIdentifier stringByReplacingOccurrencesOfString:@"-" withString:@""];
    });
    return sessionIdentifier;
}

static BOOL PMPremiumAuthorizationMatchesCurrentInstall(void)
{
    NSString *currentIdentifier = PMCurrentServerAuthorizationInstallationID();
    NSString *authorizedIdentifier = [[NSUserDefaults standardUserDefaults] stringForKey:PMPremiumAuthorizedInstallationIDKey];
    return currentIdentifier.length >= 32 && [authorizedIdentifier isEqualToString:currentIdentifier];
}

static BOOL PMAdminAuthorizationMatchesCurrentInstall(void)
{
    if (!PMPremiumAuthorizationMatchesCurrentInstall()) return NO;
    NSString *currentIdentifier = PMCurrentServerAuthorizationInstallationID();
    NSString *adminIdentifier = [[NSUserDefaults standardUserDefaults] stringForKey:PMAdminAuthorizedInstallationIDKey];
    return currentIdentifier.length >= 32 && [adminIdentifier isEqualToString:currentIdentifier];
}

static BOOL PMShouldAutoActivateAdmin(void)
{
    return PMAdminAuthorizationMatchesCurrentInstall() &&
           [[NSUserDefaults standardUserDefaults] boolForKey:PMAdminSelectedModeKey];
}

static NSString *PMServerDisplayNameForMode(NSInteger mode)
{
    if (mode == 2) return @"SERVER ADMIN";
    if (mode == 1) return @"SERVER PREMIUM";
    return @"SERVER FREE";
}

// The last protected tier is remembered separately from ActiveServerMode so the
// relaunch gate can name it even after a deliberate downgrade to FREE. The value is
// only trusted while the install-bound authorization still matches this install.
static NSInteger PMLastActiveProtectedServerMode(void)
{
    NSInteger mode = [[NSUserDefaults standardUserDefaults] integerForKey:PMLastActiveServerModeKey];
    if (mode == 2) return PMAdminAuthorizationMatchesCurrentInstall() ? 2 : 0;
    if (mode == 1) return PMPremiumAuthorizationMatchesCurrentInstall() ? 1 : 0;
    return 0;
}

static void PMRememberLastActiveServerMode(NSInteger mode)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSInteger clamped = MIN(MAX(mode, 0), 2);
    [defaults setInteger:clamped forKey:PMLastActiveServerModeKey];
    if (clamped > 0) {
        [defaults setDouble:[NSDate date].timeIntervalSince1970 forKey:PMLastActiveServerAtKey];
    }
    [defaults synchronize];
}

// Compare SHA-256 digests in constant time. Local app-side checks are a
// convenience gate, not a substitute for a remote authentication service.
static BOOL PMProtectedPasswordMatches(NSString *provided, BOOL adminPassword)
{
    if (![provided isKindOfClass:[NSString class]] || provided.length == 0 || provided.length > 64) return NO;
    NSData *data = [provided dataUsingEncoding:NSUTF8StringEncoding];
    if (!data || data.length == 0 || data.length > 256) return NO;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    static const char *premiumDigest = "a5d149071723ad0ce570d322251c01d4c8229dd77b6308735813f71f4ac2b0b5";
    static const char *adminDigest = "9f981038884a60f27d6ef5cabb2ee3a721e52062d8622dc258f00f93ba63edee";
    const char *expected = adminPassword ? adminDigest : premiumDigest;
    char actual[CC_SHA256_DIGEST_LENGTH * 2 + 1] = {0};
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        snprintf(actual + (i * 2), 3, "%02x", digest[i]);
    }
    unsigned int difference = 0;
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH * 2; i++) {
        difference |= (unsigned int)(actual[i] ^ expected[i]);
    }
    return difference == 0;
}

static NSString *PMAuthScopeForMode(NSInteger mode)
{
    return mode == 2 ? @"ADMIN" : @"PREMIUM";
}

static BOOL PMProtectedAuthAttemptAllowed(NSInteger mode, NSString **message)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *scope = PMAuthScopeForMode(mode);
    NSString *lockKey = [PMProtectedAuthLockUntilPrefix stringByAppendingString:scope];
    NSTimeInterval lockUntil = [defaults doubleForKey:lockKey];
    NSTimeInterval remaining = lockUntil - [NSDate date].timeIntervalSince1970;
    if (remaining > 0.0) {
        if (message) *message = [NSString stringWithFormat:@"Quá nhiều lần nhập sai. Vui lòng thử lại sau %.0f giây.", ceil(remaining)];
        return NO;
    }
    if (lockUntil > 0.0) {
        [defaults removeObjectForKey:lockKey];
        [defaults removeObjectForKey:[PMProtectedAuthFailureCountPrefix stringByAppendingString:scope]];
    }
    return YES;
}

static void PMRecordProtectedAuthFailure(NSInteger mode)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *scope = PMAuthScopeForMode(mode);
    NSString *countKey = [PMProtectedAuthFailureCountPrefix stringByAppendingString:scope];
    NSInteger count = [defaults integerForKey:countKey] + 1;
    [defaults setInteger:count forKey:countKey];
    if (count >= 5) {
        [defaults setDouble:([NSDate date].timeIntervalSince1970 + 60.0)
                     forKey:[PMProtectedAuthLockUntilPrefix stringByAppendingString:scope]];
        [defaults setInteger:0 forKey:countKey];
    }
    [defaults synchronize];
}

static void PMClearProtectedAuthFailures(NSInteger mode)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *scope = PMAuthScopeForMode(mode);
    [defaults removeObjectForKey:[PMProtectedAuthFailureCountPrefix stringByAppendingString:scope]];
    [defaults removeObjectForKey:[PMProtectedAuthLockUntilPrefix stringByAppendingString:scope]];
    [defaults synchronize];
}

static BOOL PMShouldAutoActivatePremium(void)
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return PMPremiumAuthorizationMatchesCurrentInstall() &&
           ([defaults boolForKey:PMPremiumSelectedModeKey] || [defaults boolForKey:PMAdminSelectedModeKey]);
}

static void PMSetPremiumSelectedMode(BOOL selected)
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:selected forKey:PMPremiumSelectedModeKey];
    if (!selected) [defaults setBool:NO forKey:PMAdminSelectedModeKey];
    [defaults synchronize];
}

static void PMSetAdminSelectedMode(BOOL selected)
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:selected forKey:PMAdminSelectedModeKey];
    if (selected) [defaults setBool:YES forKey:PMPremiumSelectedModeKey];
    [defaults synchronize];
}

static BOOL PMRememberPremiumActivation(void)
{
    NSString *identifier = PMCurrentServerAuthorizationInstallationID();
    if (identifier.length < 32) return NO;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:YES forKey:PMPremiumActivationHistoryKey];
    [defaults setObject:identifier forKey:PMPremiumAuthorizedInstallationIDKey];
    [defaults setBool:YES forKey:PMPremiumSelectedModeKey];
    [defaults synchronize];
    return YES;
}

static BOOL PMRememberAdminActivation(void)
{
    NSString *identifier = PMCurrentServerAuthorizationInstallationID();
    if (identifier.length < 32 || !PMRememberPremiumActivation()) return NO;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:identifier forKey:PMAdminAuthorizedInstallationIDKey];
    [defaults setBool:YES forKey:PMAdminSelectedModeKey];
    [defaults setBool:YES forKey:PMPremiumSelectedModeKey];
    [defaults synchronize];
    return YES;
}

static void PMRefreshUIOptions(void);
static NSString *PMTranslateString(NSString *text);
static void PMInstallLocalizationHooks(void);
static void PMRebuildUIForPreferenceChange(void);

static UIColor *PMRGB(CGFloat r, CGFloat g, CGFloat b)
{
    return [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:1.0];
}
// Dark appearance follows the black / cyan-neon reference UI. The optional
// light theme remains intact and continues to use its original blue palette.
static UIColor *PMBackgroundColor(void) { return PMLightThemeSelected ? PMRGB(244, 248, 253) : PMRGB(8, 6, 17); }
static UIColor *PMCardColor(void) { return PMLightThemeSelected ? PMRGB(255, 255, 255) : PMRGB(10, 14, 24); }
static UIColor *PMCardAltColor(void) { return PMLightThemeSelected ? PMRGB(233, 241, 250) : PMRGB(15, 22, 34); }
static UIColor *PMAccentColor(void) { return PMLightThemeSelected ? PMRGB(0, 105, 210) : PMRGB(43, 207, 225); }
static UIColor *PMMutedColor(void) { return PMLightThemeSelected ? PMRGB(77, 94, 115) : PMRGB(142, 159, 177); }
static UIColor *PMBorderColor(void) { return PMLightThemeSelected ? PMRGB(204, 217, 232) : PMRGB(34, 61, 79); }
static UIColor *PMPrimaryTextColor(void) { return PMLightThemeSelected ? PMRGB(18, 31, 49) : UIColor.whiteColor; }
static NSString *PMAppVersionString(void)
{
    NSString *numericVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (![numericVersion isKindOfClass:[NSString class]] || numericVersion.length == 0) numericVersion = @"5.8.48";
    return [numericVersion stringByAppendingString:@"t"];
}

static NSDictionary *PMReadDomain(void)
{
    // Read-only cross-process preference fallback: do not synchronize or block the
    // UI thread here. Entitlements are signed capabilities, not run-time prompts;
    // if the sandbox denies this custom domain, report failure rather than faking it.
    NSDictionary *foundationDomain = [[NSUserDefaults standardUserDefaults] persistentDomainForName:PMDomainName];
    CFDictionaryRef copied = CFPreferencesCopyMultiple(NULL, (__bridge CFStringRef)PMDomainName,
        kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    NSDictionary *cfDomain = copied ? CFBridgingRelease(copied) : nil;
    NSMutableDictionary *merged = [NSMutableDictionary dictionary];
    // Foundation's snapshot can lag behind a cross-process CFPreferences write.
    // Overlay CFPreferences last so the current persisted switch value wins.
    if ([foundationDomain isKindOfClass:[NSDictionary class]]) [merged addEntriesFromDictionary:foundationDomain];
    if ([cfDomain isKindOfClass:[NSDictionary class]]) [merged addEntriesFromDictionary:cfDomain];
    return [merged copy];
}

// One-time migration for builds that exposed the now-removed animation lock.
// Remove the obsolete key and its timestamp/tombstone from both preferences APIs.
static void PMRefreshUIOptions(void)
{
    NSDictionary *domain = PMReadDomain();
    NSString *language = [domain[@"Language"] isKindOfClass:[NSString class]] ? domain[@"Language"] : @"vi";
    NSString *theme = [domain[@"Theme"] isKindOfClass:[NSString class]] ? domain[@"Theme"] : @"dark";
    PMEnglishSelected = [language.lowercaseString isEqualToString:@"en"] || [language.lowercaseString isEqualToString:@"english"];
    PMLightThemeSelected = [theme.lowercaseString isEqualToString:@"light"] || [theme.lowercaseString isEqualToString:@"sáng"];
}

static NSString *PMTranslateString(NSString *text)
{
    if (![text isKindOfClass:[NSString class]] || text.length == 0 || !PMEnglishSelected) return text;
    static NSDictionary<NSString *, NSString *> *translations;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        translations = @{
            @"Trang chủ": @"Home",
            @"ProMotionControl": @"ProMotionControl",
            @"Tối ưu hiệu năng · Mượt mà và ổn định": @"Performance tuning · Smooth and stable",
            @"TRẠNG THÁI HIỆN TẠI": @"CURRENT STATUS",
            @"Cấu hình đã bật": @"Configuration enabled",
            @"Cấu hình đang tắt": @"Configuration is off",
            @"TRUY CẬP NHANH": @"QUICK ACCESS",
            @"Ứng dụng": @"Apps",
            @"Thông số": @"Stats",
            @"SERVER": @"SERVER",
            @"SERVER FREE": @"SERVER FREE",
            @"SERVER PREMIUM": @"SERVER PREMIUM",
            @"THÔNG SỐ": @"METRICS",
            @"CÔNG TẮC": @"SWITCHES",
            @"Giới thiệu": @"About",
            @"Cài đặt": @"Settings",
            @"Cài đặt chung": @"General Settings",
            @"Tần số quét & FPS": @"Refresh Rate & FPS",
            @"Hiệu năng nâng cao": @"Advanced Performance",
            @"Chẩn đoán runtime": @"Runtime Diagnostics",
            @"Chủ đề": @"Theme",
            @"Giao diện tối · tím neon": @"Dark · Neon purple",
            @"Giao diện sáng": @"Light theme",
            @"Ngôn ngữ": @"Language",
            @"Ngôn ngữ giao diện hiện có": @"Choose the app language",
            @"Tiếng Việt": @"Vietnamese",
            @"Tiếng Anh": @"English",
            @"Đang bật": @"Enabled",
            @"Bật": @"On",
            @"Tắt": @"Off",
            @"Tất cả": @"All",
            @"Đã cài": @"Installed",
            @"Được hỗ trợ": @"Supported",
            @"Hệ thống": @"System",
            @"Bật ProMotion Control": @"Enable ProMotion Control",
            @"Bật/tắt các điều khiển runtime tương thích": @"Enable or disable compatible runtime controls",
            @"Frame Pacing": @"Frame pacing",
            @"Cho phép runtime yêu cầu khoảng khung hình": @"Allow the runtime to request a frame-rate range",
            @"Adaptive FPS": @"Adaptive FPS",
            @"Tôn trọng chế độ nguồn và trạng thái nhiệt": @"Respect power mode and thermal state",
            @"Thermal Guard": @"Thermal guard",
            @"Giảm mục tiêu khi nhiệt tăng, nếu runtime hỗ trợ": @"Lower the target when the device heats up, when supported",
            @"Conflict Guard": @"Conflict guard",
            @"Ưu tiên tương thích khi có thay đổi xung đột": @"Prefer compatibility when conflicting changes are detected",
            @"Tùy chọn hiệu năng": @"Performance options",
            @"Điều khiển": @"Controls",
            @"Tùy chọn khác": @"Other options",
            @"Hiển thị icon trên màn hình chính": @"Show the Home Screen app icon",
            @"Ứng dụng độc lập · được đăng ký khi cài gói": @"Standalone app · registered during package installation",
            @"Không cần mở hoặc chỉnh mục Cài đặt của iOS để dùng ứng dụng này.": @"You do not need to open or change iOS Settings to use this app.",
            @"Điều khiển & chẩn đoán": @"Controls & diagnostics",
            @"Các trang nâng cao được mở khi cần": @"Advanced pages open only when needed",
            @"Chọn mục tiêu Hz và FPS": @"Choose target Hz and FPS",
            @"Chính sách nhiệt, nền, mạng và pin": @"Thermal, background, network and battery policies",
            @"Đối chiếu báo cáo do app đích gửi về": @"Review reports sent by target apps",
            @"Tần số quét (Hz)": @"Refresh rate (Hz)",
            @"Giới hạn FPS": @"FPS limit",
            @"Tùy chỉnh FPS…": @"Custom FPS…",
            @"Tùy chỉnh Hz…": @"Custom Hz…",
            @"Tất cả ứng dụng": @"All apps",
            @"Quản lý ứng dụng": @"App management",
            @"Danh sách và cấu hình riêng từng ứng dụng": @"App list and per-app settings",
            @"Thông tin chip & thiết bị": @"Chip & device information",
            @"Thông tin chung": @"General information",
            @"Thông tin khác": @"More information",
            @"Tên chip / SoC": @"Chip / SoC name",
            @"Mã thiết bị": @"Device identifier",
            @"Phiên bản iOS": @"iOS version",
            @"Số lõi CPU": @"CPU cores",
            @"Số lõi GPU": @"GPU cores",
            @"Dung lượng lưu trữ": @"Storage capacity",
            @"Dung lượng trống": @"Available storage",
            @"RAM vật lý tổng": @"Total physical RAM",
            @"RAM của ProMotion Control": @"ProMotion Control memory",
            @"Tải CPU toàn hệ thống": @"System CPU load",
            @"Đo tải CPU": @"Measure CPU load",
            @"Đo bộ nhớ tiến trình": @"Measure process memory",
            @"Đang đọc…": @"Reading…",
            @"Không khả dụng": @"Unavailable",
            @"Không xác định": @"Unknown",
            @"Bình thường": @"Normal",
            @"Nóng — hệ thống có thể giảm hiệu năng": @"Warm — the system may reduce performance",
            @"Rất nóng — hệ thống có thể giới hạn mạnh": @"Critical heat — the system may apply strong limits",
            @"Trạng thái nhiệt": @"Thermal state",
            @"Nhiệt độ máy": @"Device temperature",
            @"Nhiệt pin (°C)": @"Battery temperature (°C)",
            @"Nhiệt hệ thống": @"System thermal state",
            @"iOS không công khai nhiệt độ SoC; bản an toàn chỉ hiển thị trạng thái nhiệt do iOS cung cấp.": @"iOS does not publicly expose SoC temperature; safe mode displays the thermal state provided by iOS.",
            @"Trạng thái nhiệt iOS": @"iOS thermal state",
            @"Trạng thái pin iOS": @"iOS battery state",
            @"Màn hình": @"Display",
            @"Tổng quan": @"Overview",
            @"CPU": @"CPU",
            @"GPU": @"GPU",
            @"Pin": @"Battery",
            @"Mạng": @"Network",
            @"Nhạc": @"Music",
            @"Trái đất": @"Earth",
            @"Hiệu năng": @"Performance",
            @"Thông số chip": @"Chip information",
            @"Thông tin ứng dụng": @"App information",
            @"Tác giả": @"Author",
            @"Nguyễn Minh Hải, Taojb": @"Nguyễn Minh Hải, Taojb",
            @"Link Bio": @"Link Bio",
            @"Nhóm Discord": @"Discord community",
            @"Giao diện: tối · xanh neon": @"Interface: dark · neon blue",
            @"Chọn mức mục tiêu Hz và FPS": @"Choose target Hz and FPS",
            @"Dùng chung": @"Use global setting",
            @"Tự động": @"Automatic",
            @"Cân bằng": @"Balanced",
            @"Tiết kiệm pin": @"Battery saver",
            @"Hiệu năng cao": @"High performance",
            @"Cho phép": @"Allow",
            @"Bị chặn": @"Blocked",
            @"Chặn": @"Block",
            @"Đặt lại": @"Reset",
            @"Đặt lại cấu hình": @"Reset configuration",
            @"Lưu": @"Save",
            @"Hủy": @"Cancel",
            @"Huỷ": @"Cancel",
            @"Đóng": @"Close",
            @"Xong": @"Done",
            @"Trở về": @"Back",
            @"Dọn cache an toàn": @"Clear app cache safely",
            @"Dọn cache riêng của ProMotion Control?": @"Clear ProMotion Control's app cache?",
            @"Chỉ xóa tệp trong thư mục Caches và tmp riêng của ứng dụng này. Không xóa dữ liệu người dùng, cấu hình, cache app khác hay tệp hệ thống. iOS tự quản lý RAM chung.": @"Only cache and temporary files owned by this app are deleted. User data, settings, other apps' caches and system files are preserved. iOS manages system RAM.",
            @"Tìm kiếm theo tên hoặc Bundle ID": @"Search by name or Bundle ID",
            @"Tìm kiếm ứng dụng…": @"Search apps…",
            @"Thêm thủ công": @"Add manually",
            @"Thêm hồ sơ ứng dụng": @"Add app profile",
            @"Tạo hồ sơ": @"Create profile",
            @"Kết quả kiểm tra": @"Check results",
            @"Chưa chạy kiểm tra.": @"No check has been run yet.",
            @"Cấu hình Hz/FPS đã lưu": @"Saved Hz/FPS settings",
            @"Mục tiêu so với màn hình": @"Target vs. display capability",
            @"Đã gửi yêu cầu": @"Request sent",
            @"API không tương thích": @"API not compatible",
            @"Chưa được nạp tweak hoặc chưa có báo cáo từ tiến trình": @"Tweak not injected or no process report yet",
            @"Đang bị giới hạn bởi màn hình/nhiệt độ/nguồn điện": @"Limited by display, temperature or power mode",
            @"FPS thực tế chưa được xác nhận": @"Actual FPS not verified",
            @"Sáng": @"Light",
            @"Màu mặc định": @"Default colors",
            @"Độ sáng": @"Appearance",
            @"Hiển thị & ngôn ngữ": @"Appearance & language",
            @"Áp dụng ngay cho toàn bộ giao diện ProMotion Control": @"Applied immediately throughout ProMotion Control",
            @"Chọn Sáng hoặc Màu mặc định": @"Choose Light or Default colors",
            @"Chọn Tiếng Việt hoặc Tiếng Anh": @"Choose Vietnamese or English",
            @"Chọn ngôn ngữ": @"Choose language",
            @"Tối": @"Dark",
            @"Chọn giao diện sáng hoặc tối": @"Choose a light or dark theme",
            @"Chạm để đổi giao diện sáng hoặc tối": @"Tap to switch between light and dark themes",
            @"Chạm để chọn Tiếng Việt hoặc English": @"Tap to choose Vietnamese or English",
            @"Chẩn đoán": @"Diagnostics",
            @"Ổn định": @"Stable",
            @"Đang sạc": @"Charging",
            @"Đang dùng pin": @"On battery",
            @"Đã đầy": @"Full",
            @"Thông tin thiết bị": @"Device information",
            @"Trạng thái đang hoạt động": @"Runtime status",

            @"Không đọc được mã thiết bị": @"Could not read device identifier",
            @"Thiết bị Apple": @"Apple device",
            @"mã máy không rõ": @"unknown model identifier",
            @"Không xác định — iOS không cung cấp tên SoC trực tiếp": @"Unknown — iOS does not expose the SoC name directly",
            @"Không khả dụng qua API iOS": @"Unavailable through the iOS API",
            @"Không khả dụng trên phiên bản iOS này": @"Unavailable on this iOS version",
            @"Ấm": @"Warm",
            @"Không rõ": @"Unknown",
            @"Tùy chỉnh…": @"Custom…",
            @"Chưa xác nhận được lưu cấu hình": @"Settings save not verified",
            @"Đã hiểu": @"Got it",
            @"Tùy chỉnh %@": @"Customize %@",
            @"Nhập mục tiêu từ 10 đến 244. Đây là yêu cầu; tốc độ thực tế vẫn bị giới hạn bởi màn hình và iOS.": @"Enter a target from 10 to 244. This is a request; actual rates remain limited by the display and iOS.",
            @"10–244 %@": @"10–244 %@",
            @"Đã bật từ ứng dụng ProMotion Control": @"Enabled from ProMotion Control",
            @"Đã tắt từ ứng dụng ProMotion Control": @"Disabled from ProMotion Control",
            @"Đã bật runtime toàn cục cho app UIKit tương thích": @"Global runtime enabled for compatible UIKit apps",
            @"Áp dụng Hz/FPS cho app tương thích, kể cả hồ sơ bị chặn": @"Apply Hz/FPS to compatible apps, including blocked profiles",
            @"Không mở được liên kết": @"Could not open link",
            @"iOS không thể mở liên kết này. Hãy thử lại hoặc kiểm tra kết nối mạng.": @"iOS could not open this link. Try again or check your network connection.",
            @"Mở %@": @"Open %@",
            @"Trạng thái chưa rõ": @"Status unknown",
            @"Giao diện: đang đo…": @"UI: measuring…",
            @"Giao diện chính gặp lỗi khi khởi tạo.": @"The main interface failed to initialize.",
            @"Đã giữ ứng dụng mở ở chế độ an toàn. Lỗi: %@ — %@. Hãy lấy crash log để xác định nguyên nhân gốc.": @"The app remains open in safe mode. Error: %@ — %@. Collect the crash log to identify the root cause.",
            @"không có mô tả": @"No description",
            @"ProMotion Control đã mở ở chế độ an toàn. Hãy kiểm tra crash log.": @"ProMotion Control opened in safe mode. Check the crash log.",
            @"Tối ưu hiệu năng · Kiểm soát Hz/FPS": @"Performance optimization · Hz/FPS control",
            @"Cấu hình đang bật": @"Configuration enabled",
            @"Cấu hình đang tắt / chưa xác minh": @"Configuration disabled / unverified",
            @"Trạng thái runtime thực tế xem trong Chẩn đoán": @"View actual runtime status in Diagnostics",
            @"Mục tiêu đã lưu · đo giao diện": @"Saved target · UI measurement",
            @"Xung GPU không có API công khai": @"GPU clock has no public API",
            @"Tăng tốc & ổn định": @"Boost & stability",
            @"Tùy chọn kết nối": @"Connectivity options",
            @"Giao diện, tùy chọn runtime và thông tin ứng dụng": @"Appearance, runtime options and app information",
            @"Tác giả, Link Bio và cộng đồng Discord": @"Author, Link Bio and Discord community",
            @"Chọn mục tiêu FPS": @"Choose FPS target",
            @"Đặt mục tiêu toàn cục cho ứng dụng tương thích. Giới hạn iOS và màn hình luôn được ưu tiên.": @"Set a global target for compatible apps. iOS and display limits always take priority.",
            @"Cho phép runtime xử lý cấu hình tương thích": @"Allow the runtime to apply compatible settings",
            @"Áp dụng cho mọi ứng dụng tương thích": @"Apply to all compatible apps",
            @"Áp dụng lựa chọn chung cho app được tweak nạp": @"Apply global selections to apps where the tweak is loaded",
            @"Yêu cầu khoảng khung hình qua CADisplayLink tương thích": @"Request a frame-rate range through compatible CADisplayLink APIs",
            @"Thiết lập toàn cục": @"Global configuration",
            @"Tự động theo ứng dụng hoặc chọn mục tiêu; giá trị thực tế phụ thuộc API của app đích.": @"Follow the app automatically or choose a target; actual results depend on the target app's APIs.",
            @"Tự động (theo ứng dụng)": @"Automatic (per app)",
            @"Để ứng dụng/iOS tự quyết định": @"Let the app/iOS decide",
            @"Cân bằng hiệu năng và pin": @"Balance performance and battery",
            @"Tăng độ mượt nếu được hỗ trợ": @"Improve smoothness when supported",
            @"Mức cao nếu màn hình hỗ trợ": @"Highest level supported by the display",
            @"Yêu cầu 144 FPS; màn hình có thể giới hạn mức thực tế": @"144 FPS requested; the display may limit the actual rate",
            @"Mục tiêu thử nghiệm; chỉ có tác dụng trong giới hạn phần cứng": @"Test target; works only within hardware limits",
            @"Tôn trọng trạng thái nguồn và giới hạn nhiệt": @"Respect power state and thermal limits",
            @"Giảm mục tiêu khi trạng thái nhiệt yêu cầu": @"Lower the target when required by thermal state",
            @"Dưới 39°C pin: theo trạng thái nhiệt iOS; từ 39°C: giảm tải FPS để hạn chế tụt khung hình do quá nhiệt. iOS vẫn tự bảo vệ": @"Below 39°C battery: follow iOS thermal state; at 39°C or above, reduce requested FPS to help avoid a larger thermal drop. iOS protection remains active",
            @"Dưới 39°C pin: theo trạng thái nhiệt iOS; từ 39°C: Thermal Guard có thể hạ mục tiêu và hồi dần khi nguội. iOS vẫn tự bảo vệ.": @"Below 39°C battery: follow iOS thermal state; at 39°C or above, Thermal Guard may lower the target and recover gradually after cooling. iOS protection remains active.",
            @"Ổn định và tương thích": @"Stability & compatibility",
            @"Chạm Thiết lập để mở hồ sơ. App chưa có hồ sơ sẽ được tạo ở trạng thái tắt.": @"Tap Configure to open the profile. A missing profile will be created disabled.",
            @"Dùng khi LaunchServices không trả về một ứng dụng.": @"Use when LaunchServices does not return an app.",
            @"＋  Thêm ứng dụng theo Bundle ID": @"＋ Add app by Bundle ID",
            @"Đang đọc danh sách ứng dụng ở nền… Bạn vẫn có thể thêm Bundle ID thủ công ngay bên dưới.": @"Loading the app list in the background… You can still enter a Bundle ID manually below.",
            @"Danh sách tự động chưa phản hồi. Hồ sơ đã lưu và mục thêm Bundle ID vẫn dùng được.": @"The automatic list has not responded. Saved profiles and manual Bundle ID entry remain available.",
            @"Chưa có ứng dụng nào đang được can thiệp. Mở hồ sơ để bật ứng dụng.": @"No apps are currently being managed. Open a profile to enable an app.",
            @"Chưa có app nào được đặt chính sách Cho phép.": @"No apps have an Allow policy.",
            @"Chưa có app nào bị chặn bởi chính sách của ProMotion Control.": @"No apps are blocked by ProMotion Control policy.",
            @"Không có kết quả phù hợp. Thử từ khóa khác hoặc nhập Bundle ID thủ công.": @"No matching results. Try another keyword or enter a Bundle ID manually.",
            @"Ứng dụng hệ thống quan trọng · không can thiệp": @"Critical system app · not managed",
            @"● Đang bật · công tắc hồ sơ được ưu tiên": @"● Enabled · per-app switch takes priority",
            @"● Đang áp dụng toàn cục · ghi đè hồ sơ Chặn": @"● Global enforcement · overrides ProMotion Control's Block profile",
            @"● Bị chặn bởi chính sách ProMotion": @"● Blocked by ProMotion policy",
            @"● Cho phép · đang bật": @"● Allowed · enabled",
            @"Cho phép · chưa bật": @"Allowed · not enabled",
            @"● Đang áp dụng toàn cục": @"● Global enforcement active",
            @"Hồ sơ đã lưu · Tắt": @"Profile saved · Off",
            @"Chưa có hồ sơ": @"No profile",
            @"Ứng dụng hệ thống · runtime phụ thuộc iOS": @"System app · runtime depends on iOS",
            @"Ứng dụng đã cài": @"Installed apps",
            @"Thiết lập  ›": @"Configure ›",
            @"Thiết lập %@": @"Configure %@",
            @"Mở hồ sơ Hz/FPS riêng cho ứng dụng này": @"Open this app's Hz/FPS profile",
            @"Đang hiển thị %lu/%lu ứng dụng.": @"Showing %lu/%lu apps.",
            @"Hiển thị thêm %lu ứng dụng": @"Show %lu more apps",
            @"Hồ sơ mới sẽ ở trạng thái TẮT cho đến khi bạn bật thủ công.": @"New profiles stay OFF until you enable them manually.",
            @"Bundle ID · com.example.app": @"Bundle ID · com.example.app",
            @"Tên hiển thị (không bắt buộc)": @"Display name (optional)",
            @"Bundle ID không hợp lệ": @"Invalid Bundle ID",
            @"Ví dụ: com.example.app": @"Example: com.example.app",
            @"Hồ sơ đã tồn tại": @"Profile already exists",
            @"Mở hồ sơ hiện tại để chỉnh sửa.": @"Open the existing profile to edit it.",
            @"Chính sách tương thích": @"Compatibility policy",
            @"Chặn ưu tiên bình thường; tuỳ chọn toàn cục áp dụng hồ sơ bị chặn có thể ghi đè.": @"Block is normally respected; the global override can override ProMotion Control's blocked profiles.",
            @"Bật can thiệp cho ứng dụng": @"Enable intervention for this app",
            @"Khi bật, hồ sơ tự chuyển sang Cho phép và bật runtime/Frame Pacing": @"When enabled, the profile switches to Allow and enables runtime/frame pacing",
            @"Trạng thái hồ sơ": @"Profile status",
            @"Chế độ ưu tiên": @"Priority mode",
            @"Chỉ thay đổi mục tiêu khung hình tương thích; không ép xung CPU/GPU.": @"Changes compatible frame-rate targets only; it does not overclock the CPU/GPU.",
            @"Tiết kiệm": @"Saver",
            @"Hz riêng cho ứng dụng": @"Per-app Hz",
            @"Dùng chung kế thừa lựa chọn toàn cục · Auto để iOS tự chọn": @"Use global selection · Auto lets iOS decide",
            @"FPS riêng cho ứng dụng": @"Per-app FPS",
            @"Đây là mục tiêu yêu cầu, không phải FPS đo thực tế": @"This is a requested target, not measured FPS",
            @"Chọn chính sách rồi tinh chỉnh các giới hạn runtime. iOS vẫn quản lý nhiệt và phần cứng.": @"Choose a policy, then fine-tune runtime limits. iOS still manages thermals and hardware.",
            @"Các chế độ là preset cho các công tắc runtime bên dưới, không phải ép xung phần cứng.": @"Modes are presets for the runtime switches below, not hardware overclocking.",
            @"Chỉ số xung CPU/GPU tức thời không có API công khai ổn định trên mọi iPhone.": @"No stable public API exposes real-time CPU/GPU clock speeds on every iPhone.",
            @"CPU: xem mức tải ở Trang chủ": @"CPU: view load on Home",
            @"GPU: xung thực tế không khả dụng qua API công khai": @"GPU: real clock speed is unavailable through a public API",
            @"Tự động điều chỉnh FPS": @"Adaptive FPS",
            @"Giảm tải khi chạy nền": @"Reduce load in the background",
            @"Sau 5 phút app ở nền liên tục, khôi phục FPS gốc và dừng ghi đè của tweak; không đóng app. iOS có thể suspend sớm hơn.": @"Restore original range when the app enters background",
            @"Tự động điều chỉnh": @"Automatic adjustment",
            @"Yêu cầu khoảng CADisplayLink đã chọn": @"Request the selected CADisplayLink range",
            @"Tránh ghi đè khi phát hiện thay đổi xung đột": @"Avoid overriding conflicting changes",
            @"Cho phép khoảng thích ứng khi mục tiêu cao": @"Allow adaptive range for high targets",
            @"Chế độ tương thích cho CADisplayLink": @"CADisplayLink compatibility mode",
            @"Giới hạn khi quay màn hình": @"Screen recording limit",
            @"Giảm mục tiêu khi đang ghi màn hình": @"Lower target while screen recording",
            @"Tối ưu khi quay màn hình": @"Screen recording optimization",
            @"Giữ mục tiêu FPS đã chọn khi quay; giảm ghi chẩn đoán phụ, iOS vẫn tự điều tiết nhiệt": @"Keep the selected FPS target while recording; reduce diagnostic writes while iOS manages thermals",
            @"Tùy chỉnh nâng cao": @"Advanced customization",
            @"Bao gồm app người dùng và app hệ thống có bundle được hỗ trợ; Settings/SpringBoard vẫn bị loại trừ": @"Includes supported user and system app bundles; Settings/SpringBoard remain excluded",
            @"Ghi đè hồ sơ bị chặn": @"Override blocked profiles",
            @"Giới hạn mục tiêu khung hình theo chính sách runtime": @"Limit frame-rate targets according to runtime policy",
            @"Giảm tải dashboard khi sạc": @"Reduce dashboard sampling while charging",
            @"Giảm tần suất lấy mẫu/chẩn đoán phụ; không hạ Hz/FPS đã chọn": @"Reduce auxiliary telemetry sampling; keep the selected Hz/FPS target",
            @"Tương thích & nguồn điện": @"Compatibility & power",
            @"Thông tin tham khảo, không thay đổi phần cứng thật": @"Reference information; does not change physical hardware",
            @"Xem thông số chip & hiệu năng": @"View chip and performance details",
            @"CPU · GPU · Neural Engine · RAM · bộ nhớ · nhiệt": @"CPU · GPU · Neural Engine · RAM · storage · thermals",
            @"%@ · đọc dữ liệu từ thiết bị hiện tại": @"%@ · read from the current device",
            @"Không khả dụng qua Metal": @"Unavailable through Metal",
            @"Tối đa danh nghĩa %ld Hz": @"Reported maximum: %ld Hz",
            @"Tên SoC được suy luận từ mã máy nếu có bản ánh xạ; iOS không công khai tên chip trực tiếp.": @"The SoC name is inferred from the model identifier when mapped; iOS does not expose the chip name directly.",
            @"Trạng thái xử lý trực tiếp": @"Live processing status",
            @"Cập nhật theo chu kỳ 1 giây khi trang này mở.": @"Updates every second while this page is open.",
            @"Bộ xử lý CPU": @"CPU processor",
            @"Một số chi tiết tần số bị iOS ẩn; số liệu không có quyền đọc sẽ được báo rõ.": @"iOS hides some frequency details; unavailable values are reported clearly.",
            @"Kiến trúc ứng dụng": @"App architecture",
            @"Số lõi logic": @"Logical cores",
            @"Tần số CPU hiện tại": @"Current CPU frequency",
            @"Tần số CPU tối đa": @"Maximum CPU frequency",
            @"RAM tiến trình app": @"App process RAM",
            @"Bộ xử lý đồ họa GPU": @"GPU graphics processor",
            @"Thông tin nhận diện qua Metal trên thiết bị đang dùng.": @"Identification information reported by Metal on this device.",
            @"Thiết bị GPU": @"GPU device",
            @"Không được iOS công khai ổn định": @"Not reliably exposed by iOS",
            @"Xung GPU hiện tại": @"Current GPU clock",
            @"Không có API công khai ổn định": @"No stable public API",
            @"Tên SoC": @"SoC name",
            @"Tên thiết bị Metal là thông tin hệ thống trả về; số lõi và xung GPU không được suy đoán.": @"The Metal device name comes from the system; GPU core count and clock speed are not guessed.",
            @"Thông tin thiết bị khác": @"Other device information",
            @"Model phần cứng": @"Hardware model",
            @"Tần số quét tối đa của màn hình": @"Maximum display refresh rate",
            @"Đang đo mẫu đầu…": @"Taking initial sample…",
            @"Trang cài đặt trong app · không nằm trong Settings của iOS": @"In-app settings · not iOS Settings",
            @"Giao diện": @"Appearance",
            @"Tuỳ chỉnh hiển thị ứng dụng": @"Customize app appearance",
            @"Điều tiết nhiệt, pin và chính sách runtime": @"Thermal, battery and runtime policies",
            @"Về ứng dụng": @"About",
            @"Chọn ngôn ngữ cho ProMotion Control": @"Choose the ProMotion Control language",
            @"Đặt lại cấu hình toàn cục?": @"Reset global configuration?",
            @"Các mục chung sẽ về trạng thái an toàn mặc định. Hồ sơ từng ứng dụng sẽ được giữ nguyên.": @"Global options will return to safe defaults. Per-app profiles will be kept.",
            @"GIỚI THIỆU": @"ABOUT",
            @"Thông tin ứng dụng và liên kết cộng đồng": @"App information and community links",
            @"Phiên bản": @"Version",
            @"Kiểu gói": @"Package type",
            @"Jailbreak · Rootless · Theos": @"Jailbreak · Rootless · Theos",
            @"Liên kết & cộng đồng": @"Links & community",
            @"Chạm để mở ứng dụng tương ứng hoặc trình duyệt mặc định": @"Tap to open the relevant app or the default browser",
            @"Kiểm tra tổng quan": @"Overview check",
            @"Tiến trình kiểm tra": @"Check progress",
            @"Đo lại CPU theo thời gian, kiểm tra cấu hình, thông tin thiết bị, lưu trữ và trạng thái nhiệt.": @"Sample CPU over time and inspect settings, device information, storage and thermal state.",
            @"Sau khi hoàn tất, mỗi mục sẽ có dấu ✓ hoặc ✕ cùng giải thích.": @"When finished, each item shows ✓ or ✕ with an explanation.",
            @"Đang thu thập mẫu CPU và kiểm tra cấu hình…": @"Collecting CPU samples and checking configuration…",
            @"Màn hình iOS báo tối đa %ld Hz; đã chọn Hz %@, FPS %@.": @"iOS reports a maximum display rate of %ld Hz; selected Hz %@, FPS %@.",
            @"Mục tiêu cao hơn giới hạn phần cứng nên không thể đạt mức đó trên màn hình này.": @"The target exceeds hardware limits and cannot be reached on this display.",
            @"Không đọc được mẫu tải CPU qua Mach API trong phiên này.": @"Could not read CPU load through the Mach API in this session.",
            @"Không đọc được dung lượng trống từ vùng dữ liệu ứng dụng.": @"Could not read free storage from the app data container.",
            @"Thiết bị/iOS không cung cấp mức pin hiện tại.": @"The device/iOS does not provide the current battery level.",
            @"Trạng thái nhiệt iOS: %@.": @"iOS thermal state: %@.",
            @"Mã máy %@; SoC %@.": @"Model %@; SoC %@.",
            @"Bundle và executable ứng dụng": @"App bundle and executable",
            @"Bundle ID và executable khớp; không dùng tên dpkg-tmp.": @"Bundle ID and executable match; no dpkg-tmp name is used.",
            @"Metadata hoặc executable không khớp. Kiểm tra gói cài đặt và Info.plist.": @"Metadata or executable mismatch. Check the package and Info.plist.",
            @"Icon ứng dụng": @"App icon",
            @"Hai kích thước icon chính có trong bundle.": @"Both primary icon sizes are present in the bundle.",
            @"Thiếu một hoặc nhiều tệp icon trong bundle.": @"One or more icon files are missing from the bundle.",
            @"Đọc được cấu hình; runtime %@.": @"Settings readable; runtime %@.",
            @"đang bật": @"enabled",
            @"đang tắt": @"disabled",
            @"Không thấy đủ khóa Enabled và FramePacing trong domain cấu hình.": @"The configuration domain lacks Enabled and FramePacing keys.",
            @"RAM cư trú của riêng ProMotion Control: %@. Đây không phải tổng RAM trống hệ thống.": @"ProMotion Control resident memory: %@. This is not total free system RAM.",
            @"Đọc mức pin": @"Read battery level",
            @"Nhận diện chip theo mã máy": @"Identify chip from model identifier",
            @"Báo cáo runtime gần đây": @"Recent runtime report",
            @"Dọn an toàn": @"Safe cleanup",
            @"Dọn cache hoàn tất": @"Cache cleanup complete",
            @"Đối chiếu cấu hình": @"Compare configuration",
            @"Các số dưới đây là yêu cầu và báo cáo từ tiến trình, không phải bộ đo FPS toàn hệ thống.": @"The values below are requests and process reports, not a system-wide FPS meter.",
            @"Cấu hình toàn cục": @"Global configuration",
            @"Chưa ghi": @"Not recorded",
            @"Chẩn đoán theo app": @"Per-app diagnostics",
            @"Chưa có hồ sơ ứng dụng để đối chiếu.": @"No app profiles are available for comparison.",
            @"Chưa có báo cáo từ app": @"No report from app",
            @"Chưa có kết quả áp dụng": @"No apply result yet",
            @"Chưa có báo cáo": @"No report yet",
            @"công tắc tổng đang tắt": @"the master switch is off",
            @"hồ sơ riêng của ứng dụng đang tắt": @"the per-app profile is disabled",
            @"Đã nạp tweak · cấu hình đang tắt": @"Tweak injected · configuration disabled",
            @"cấu hình đã nạp": @"configuration loaded",
            @"đang chờ cadisplaylink": @"waiting for CADisplayLink",
            @"Đã nạp tweak · đang chờ CADisplayLink tương thích": @"Tweak injected · waiting for compatible CADisplayLink",
            @"Đã nạp tweak · chưa có báo cáo áp dụng": @"Tweak injected · no apply report yet",
            @"Có": @"Yes",
            @"Không": @"No",
            @"Kiểm tra quyền lưu": @"Check write access",
            @"Chưa có thao tác ghi trong phiên app này.": @"No write operation in this app session.",
            @"Không xác minh được giá trị sau khi ghi; có thể sandbox chặn domain dùng chung.": @"Could not verify the value after writing; the sandbox may restrict the shared domain.",
            @"Kiểm tra ghi cấu hình": @"Test configuration write"
        };
    });
    NSString *translated = translations[text];
    if (translated) return translated;
    // Translate common dynamic status strings without changing numeric values.
    if ([text hasPrefix:@"Đang kiểm tra… "]) return [text stringByReplacingOccurrencesOfString:@"Đang kiểm tra… " withString:@"Checking… "];
    if ([text hasPrefix:@"Đang hiển thị "]) return [text stringByReplacingOccurrencesOfString:@"Đang hiển thị " withString:@"Showing "];
    if ([text hasPrefix:@"Mã máy "]) return [text stringByReplacingOccurrencesOfString:@"Mã máy " withString:@"Model "];
    if ([text hasPrefix:@"Pin hiện tại "]) return [text stringByReplacingOccurrencesOfString:@"Pin hiện tại " withString:@"Current battery "];
    if ([text hasPrefix:@"Mức tải toàn hệ thống gần nhất: "]) return [text stringByReplacingOccurrencesOfString:@"Mức tải toàn hệ thống gần nhất: " withString:@"Latest system load: "];
    if ([text hasPrefix:@"Dung lượng trống filesystem được báo: "]) return [text stringByReplacingOccurrencesOfString:@"Dung lượng trống filesystem được báo: " withString:@"Reported free filesystem space: "];
    if ([text hasPrefix:@"Màn hình iOS báo tối đa "]) return [text stringByReplacingOccurrencesOfString:@"Màn hình iOS báo tối đa " withString:@"iOS reports a display maximum of "];
    // Translate common phrases inside dynamic status strings as a fallback.
    static NSArray<NSArray<NSString *> *> *phrases;
    static dispatch_once_t phraseOnce;
    dispatch_once(&phraseOnce, ^{
        phrases = @[
            @[@"Đang kiểm tra", @"Checking"], @[@"Đang hiển thị", @"Showing"],
            @[@"Đã bật", @"Enabled"], @[@"Đã tắt", @"Disabled"],
            @[@"Chưa có", @"No"], @[@"Không khả dụng", @"Unavailable"],
            @[@"Màn hình", @"Display"], @[@"ứng dụng", @"app"],
            @[@"cấu hình", @"configuration"], @[@"đã chọn", @"selected"],
            @[@"giới hạn", @"limited"], @[@"nhiệt độ", @"temperature"],
            @[@"nguồn điện", @"power"], @[@"Trạng thái", @"Status"],
            @[@"Thiết bị", @"Device"], @[@"Đang đo", @"Measuring"],
            @[@"đã lưu", @"saved"], @[@"tối đa", @"maximum"],
            @[@"thực tế", @"actual"], @[@"Không thể", @"Cannot"],
            @[@"Không đọc được", @"Could not read"], @[@"tương thích", @"compatible"],
            @[@"Đang sạc", @"Charging"], @[@"Đã đầy", @"Full"],
            @[@"Đang dùng pin", @"On battery"], @[@"đang bật", @"enabled"],
            @[@"đang tắt", @"disabled"], @[@"Cho phép", @"Allow"],
            @[@"Bị chặn", @"Blocked"], @[@"Chặn", @"Block"]
        ];
    });
    NSMutableString *partial = [text mutableCopy];
    for (NSArray<NSString *> *pair in phrases) {
        [partial replaceOccurrencesOfString:pair[0] withString:pair[1] options:NSCaseInsensitiveSearch range:NSMakeRange(0, partial.length)];
    }
    return partial;

}

static void PMInstallLocalizationHooks(void)
{
    // Runtime swizzling of common UIKit setters is intentionally disabled in
    // the crash-containment release. Static screen labels still use
    // PMTranslateString explicitly; this avoids conflicts with other tweaks.
}

// Best-effort system CPU load measurement using the public Mach host statistics API.
// Return -1 when the OS denies the query or there is not yet a previous sample.
// The app intentionally does not invent CPU/GPU clock frequencies: iOS has no
// stable public API for real-time CPU/GPU MHz or system-wide GPU utilization.
static double PMSystemCPUUsagePercent(void)
{
    static uint64_t previousUser = 0, previousSystem = 0, previousNice = 0, previousIdle = 0;
    static BOOL hasPreviousSample = NO;

    mach_port_t host = mach_host_self();
    if (host == MACH_PORT_NULL) return -2.0;
    host_cpu_load_info_data_t info;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    kern_return_t result = host_statistics(host, HOST_CPU_LOAD_INFO, (host_info_t)&info, &count);
    mach_port_deallocate(mach_task_self(), host);
    if (result != KERN_SUCCESS) return -2.0;

    uint64_t user = (uint64_t)info.cpu_ticks[CPU_STATE_USER];
    uint64_t system = (uint64_t)info.cpu_ticks[CPU_STATE_SYSTEM];
    uint64_t nice = (uint64_t)info.cpu_ticks[CPU_STATE_NICE];
    uint64_t idle = (uint64_t)info.cpu_ticks[CPU_STATE_IDLE];
    if (!hasPreviousSample || user < previousUser || system < previousSystem ||
        nice < previousNice || idle < previousIdle) {
        previousUser = user; previousSystem = system; previousNice = nice; previousIdle = idle;
        hasPreviousSample = YES;
        return -1.0;
    }

    uint64_t dUser = user - previousUser;
    uint64_t dSystem = system - previousSystem;
    uint64_t dNice = nice - previousNice;
    uint64_t dIdle = idle - previousIdle;
    previousUser = user; previousSystem = system; previousNice = nice; previousIdle = idle;
    uint64_t total = dUser + dSystem + dNice + dIdle;
    if (total == 0) return -1.0;
    double usage = 100.0 * (double)(dUser + dSystem + dNice) / (double)total;
    return fmin(100.0, fmax(0.0, usage));
}

static dispatch_queue_t PMSystemCPUStatsQueue(void)
{
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.dell.promotioncontrol.system-cpu-stats", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSString *PMReadSysctlString(const char *key)
{
    if (!key) return nil;
    size_t length = 0;
    if (sysctlbyname(key, NULL, &length, NULL, 0) != 0 || length == 0 || length > 4096) return nil;
    char *buffer = calloc(1, length + 1);
    if (!buffer) return nil;
    NSString *result = nil;
    if (sysctlbyname(key, buffer, &length, NULL, 0) == 0) {
        result = [NSString stringWithUTF8String:buffer];
        if (result.length == 0) result = nil;
    }
    free(buffer);
    return result;
}

static uint64_t PMReadSysctlUInt64(const char *key, BOOL *success)
{
    uint64_t value = 0;
    size_t length = sizeof(value);
    int result = key ? sysctlbyname(key, &value, &length, NULL, 0) : -1;
    BOOL valid = (result == 0 && length > 0 && value > 0);
    if (success) *success = valid;
    return valid ? value : 0;
}

static NSString *PMHardwareMachineIdentifier(void)
{
    NSString *machine = PMReadSysctlString("hw.machine");
    return machine.length ? machine : @"Không đọc được mã thiết bị";
}

static NSString *PMFriendlyDeviceName(NSString *machine)
{
    static NSDictionary<NSString *, NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = @{
            @"iPhone6,1": @"iPhone 5s", @"iPhone6,2": @"iPhone 5s",
            @"iPhone7,1": @"iPhone 6 Plus", @"iPhone7,2": @"iPhone 6",
            @"iPhone8,1": @"iPhone 6s", @"iPhone8,2": @"iPhone 6s Plus", @"iPhone8,4": @"iPhone SE (thế hệ 1)",
            @"iPhone9,1": @"iPhone 7", @"iPhone9,3": @"iPhone 7",
            @"iPhone9,2": @"iPhone 7 Plus", @"iPhone9,4": @"iPhone 7 Plus",
            @"iPhone10,1": @"iPhone 8", @"iPhone10,4": @"iPhone 8", @"iPhone10,2": @"iPhone 8 Plus", @"iPhone10,5": @"iPhone 8 Plus",
            @"iPhone10,3": @"iPhone X", @"iPhone10,6": @"iPhone X",
            @"iPhone11,2": @"iPhone XS", @"iPhone11,4": @"iPhone XS Max", @"iPhone11,6": @"iPhone XS Max", @"iPhone11,8": @"iPhone XR",
            @"iPhone12,1": @"iPhone 11", @"iPhone12,3": @"iPhone 11 Pro", @"iPhone12,5": @"iPhone 11 Pro Max", @"iPhone12,8": @"iPhone SE (thế hệ 2)",
            @"iPhone13,1": @"iPhone 12 mini", @"iPhone13,2": @"iPhone 12", @"iPhone13,3": @"iPhone 12 Pro", @"iPhone13,4": @"iPhone 12 Pro Max",
            @"iPhone14,2": @"iPhone 13 Pro", @"iPhone14,3": @"iPhone 13 Pro Max", @"iPhone14,4": @"iPhone 13 mini", @"iPhone14,5": @"iPhone 13", @"iPhone14,6": @"iPhone SE (thế hệ 3)", @"iPhone14,7": @"iPhone 14", @"iPhone14,8": @"iPhone 14 Plus",
            @"iPhone15,2": @"iPhone 14 Pro", @"iPhone15,3": @"iPhone 14 Pro Max", @"iPhone15,4": @"iPhone 15", @"iPhone15,5": @"iPhone 15 Plus",
            @"iPhone16,1": @"iPhone 15 Pro", @"iPhone16,2": @"iPhone 15 Pro Max",
            @"iPhone17,1": @"iPhone 16 Pro", @"iPhone17,2": @"iPhone 16 Pro Max", @"iPhone17,3": @"iPhone 16", @"iPhone17,4": @"iPhone 16 Plus"
        };
    });
    NSString *known = names[machine];
    if (known.length) return known;
    NSString *generic = UIDevice.currentDevice.model;
    if (![generic isKindOfClass:[NSString class]] || generic.length == 0) generic = @"Thiết bị Apple";
    return [NSString stringWithFormat:@"%@ · %@", generic, machine ?: @"mã máy không rõ"];
}

static NSString *PMEstimatedSoCName(NSString *machine)
{
    // iOS does not expose a public API that directly returns the marketing SoC name.
    // Known entries are inferred from the hardware identifier; unknown devices are not guessed.
    static NSDictionary<NSString *, NSString *> *chips;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        chips = @{
            @"iPhone6,1": @"Apple A7 (suy luận theo mã máy)", @"iPhone6,2": @"Apple A7 (suy luận theo mã máy)",
            @"iPhone7,1": @"Apple A8 (suy luận theo mã máy)", @"iPhone7,2": @"Apple A8 (suy luận theo mã máy)",
            @"iPhone8,1": @"Apple A9 (suy luận theo mã máy)", @"iPhone8,2": @"Apple A9 (suy luận theo mã máy)", @"iPhone8,4": @"Apple A9 (suy luận theo mã máy)",
            @"iPhone9,1": @"Apple A10 Fusion (suy luận theo mã máy)", @"iPhone9,2": @"Apple A10 Fusion (suy luận theo mã máy)",
            @"iPhone9,3": @"Apple A10 Fusion (suy luận theo mã máy)", @"iPhone9,4": @"Apple A10 Fusion (suy luận theo mã máy)",
            @"iPhone10,1": @"Apple A11 Bionic (suy luận theo mã máy)", @"iPhone10,2": @"Apple A11 Bionic (suy luận theo mã máy)",
            @"iPhone10,3": @"Apple A11 Bionic (suy luận theo mã máy)", @"iPhone10,4": @"Apple A11 Bionic (suy luận theo mã máy)",
            @"iPhone10,5": @"Apple A11 Bionic (suy luận theo mã máy)", @"iPhone10,6": @"Apple A11 Bionic (suy luận theo mã máy)",
            @"iPhone11,2": @"Apple A12 Bionic (suy luận theo mã máy)", @"iPhone11,4": @"Apple A12 Bionic (suy luận theo mã máy)", @"iPhone11,6": @"Apple A12 Bionic (suy luận theo mã máy)", @"iPhone11,8": @"Apple A12 Bionic (suy luận theo mã máy)",
            @"iPhone12,1": @"Apple A13 Bionic (suy luận theo mã máy)", @"iPhone12,3": @"Apple A13 Bionic (suy luận theo mã máy)", @"iPhone12,5": @"Apple A13 Bionic (suy luận theo mã máy)", @"iPhone12,8": @"Apple A13 Bionic (suy luận theo mã máy)",
            @"iPhone13,1": @"Apple A14 Bionic (suy luận theo mã máy)", @"iPhone13,2": @"Apple A14 Bionic (suy luận theo mã máy)", @"iPhone13,3": @"Apple A14 Bionic (suy luận theo mã máy)", @"iPhone13,4": @"Apple A14 Bionic (suy luận theo mã máy)",
            @"iPhone14,2": @"Apple A15 Bionic (suy luận theo mã máy)", @"iPhone14,3": @"Apple A15 Bionic (suy luận theo mã máy)", @"iPhone14,4": @"Apple A15 Bionic (suy luận theo mã máy)", @"iPhone14,5": @"Apple A15 Bionic (suy luận theo mã máy)", @"iPhone14,6": @"Apple A15 Bionic (suy luận theo mã máy)", @"iPhone14,7": @"Apple A15 Bionic (suy luận theo mã máy)", @"iPhone14,8": @"Apple A15 Bionic (suy luận theo mã máy)",
            @"iPhone15,2": @"Apple A16 Bionic (suy luận theo mã máy)", @"iPhone15,3": @"Apple A16 Bionic (suy luận theo mã máy)", @"iPhone15,4": @"Apple A16 Bionic (suy luận theo mã máy)", @"iPhone15,5": @"Apple A16 Bionic (suy luận theo mã máy)",
            @"iPhone16,1": @"Apple A17 Pro (suy luận theo mã máy)", @"iPhone16,2": @"Apple A17 Pro (suy luận theo mã máy)",
            @"iPhone17,1": @"Apple A18 Pro (suy luận theo mã máy)", @"iPhone17,2": @"Apple A18 Pro (suy luận theo mã máy)", @"iPhone17,3": @"Apple A18 (suy luận theo mã máy)", @"iPhone17,4": @"Apple A18 (suy luận theo mã máy)"
        };
    });
    return chips[machine] ?: @"Không xác định — iOS không cung cấp tên SoC trực tiếp";
}

static NSString *PMHumanBytes(uint64_t bytes)
{
    if (bytes == 0) return @"Không khả dụng";
    NSByteCountFormatter *formatter = [NSByteCountFormatter new];
    formatter.countStyle = NSByteCountFormatterCountStyleFile;
    formatter.allowedUnits = NSByteCountFormatterUseGB | NSByteCountFormatterUseMB;
    formatter.includesUnit = YES;
    return [formatter stringFromByteCount:(long long)bytes];
}

static NSString *PMFrequencyLabel(const char *key)
{
    BOOL ok = NO;
    uint64_t hz = PMReadSysctlUInt64(key, &ok);
    if (!ok || hz < 1000000ULL) return @"Không khả dụng qua API iOS";
    if (hz >= 1000000000ULL) return [NSString stringWithFormat:@"%.2f GHz", (double)hz / 1000000000.0];
    return [NSString stringWithFormat:@"%.0f MHz", (double)hz / 1000000.0];
}

static NSString *PMProcessResidentMemoryLabel(void)
{
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count);
    if (kr != KERN_SUCCESS) return @"Không khả dụng";
    return PMHumanBytes((uint64_t)info.resident_size);
}

static NSString *PMThermalStateLabel(void)
{
    if (@available(iOS 11.0, *)) {
        switch (NSProcessInfo.processInfo.thermalState) {
            case NSProcessInfoThermalStateNominal: return @"Bình thường";
            case NSProcessInfoThermalStateFair: return @"Ấm";
            case NSProcessInfoThermalStateSerious: return @"Nóng — hệ thống có thể giảm hiệu năng";
            case NSProcessInfoThermalStateCritical: return @"Rất nóng — hệ thống có thể giới hạn mạnh";
            default: return @"Không rõ";
        }
    }
    return @"Không khả dụng trên phiên bản iOS này";
}

// Battery-pack temperature is not queried in the crash-containment release.
// The dashboard reports NSProcessInfo thermal state through the public API.

static NSString *PMSelectedRateText(NSDictionary *domain, NSString *modeKey,
                                    NSString *customKey, NSString *unit)
{
    id rawMode = domain[modeKey];
    NSInteger mode = [rawMode respondsToSelector:@selector(integerValue)] ? [rawMode integerValue] : 0;
    if (mode == 0) return @"Auto";
    if (mode == -1) {
        id rawCustom = domain[customKey];
        NSInteger custom = [rawCustom respondsToSelector:@selector(integerValue)] ? [rawCustom integerValue] : 60;
        return [NSString stringWithFormat:@"%ld %@", (long)MIN(MAX(custom, 10), 244), unit];
    }
    if (mode < 0) return @"Dùng chung";
    return [NSString stringWithFormat:@"%ld %@", (long)MIN(MAX(mode, 1), 244), unit];
}

// Read the numeric global choice for the dashboard's native CADisplayLink test.
// This probes what the current app can request and receive; it is not a claim
// that another process or the physical panel is running at the same rate.
static NSInteger PMDashboardRateValue(NSDictionary *domain, NSString *modeKey, NSString *customKey)
{
    id rawMode = domain[modeKey];
    NSInteger mode = [rawMode respondsToSelector:@selector(integerValue)] ? [rawMode integerValue] : 0;
    if (mode == -1) {
        id rawCustom = domain[customKey];
        NSInteger custom = [rawCustom respondsToSelector:@selector(integerValue)] ? [rawCustom integerValue] : 60;
        return MIN(MAX(custom, 10), 244);
    }
    return mode > 0 ? MIN(MAX(mode, 10), 244) : 0;
}

static NSArray<NSString *> *PMServerScopedConfigurationKeys(void)
{
    static NSArray<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = @[
            @"Enabled", @"RefreshRateEnabled", @"FPSOverrideEnabled",
            @"AdvancedDisplayEnforcement", @"FramePacing",
            @"AdaptiveFPS", @"ThermalGuard", @"BackgroundReduction", @"ConflictGuard",
            @"StutterFix",
            @"AppStabilityFix", @"ScreenRecordingFix", @"OverrideBlockedApps",
            @"BatterySaver", @"ChargingOptimization", @"RefreshMode", @"FPSMode",
            @"CustomRefreshRate", @"CustomFPS", @"PerformancePreset",
            @"FreeRenderSchedulerEnabled", @"FreeSmoothEngineEnabled", @"FreeTouchTuningEnabled", @"FreeAdaptiveCadenceEnabled",
            @"FreeThermalGuardEnabled", @"FreeCADisplayLinkHookEnabled",
            @"FreeBackgroundAudioGuardEnabled", @"FreeActivityBoostEnabled", @"FreeBackgroundKeepAliveEnabled",
            @"FreeBackgroundContinuityEnabled", @"FreeMemoryGuardEnabled", @"FreeRateSentinelEnabled",
            @"PremiumRenderSchedulerEnabled", @"PremiumTouchTuningEnabled",
            @"PremiumLowLatencyModeEnabled", @"PremiumThermalGuardEnabled",
            @"PremiumChargingGuardEnabled", @"PremiumTier4DisplayPolicyEnabled", @"PremiumCADisplayLinkHookEnabled",
            @"PremiumActivityBoostEnabled", @"PremiumBackgroundAudioGuardEnabled", @"PremiumBackgroundKeepAliveEnabled",
            @"PremiumBackgroundContinuityEnabled", @"PremiumMemoryGuardEnabled", @"PremiumRateSentinelEnabled",
            @"AdminRenderSchedulerEnabled",
            @"AdminTouchTuningEnabled", @"AdminFastScrollEnabled",
            @"AdminHideScrollIndicatorsEnabled", @"AdminStaticSurfaceCacheEnabled",
            @"AdminThermalCooldownEnabled", @"AdminLocalDaemonBridgeEnabled",
            @"AdminChargingCooldownEnabled", @"AdminAdaptiveFramePacingEnabled",
            @"AdminDashboardLoadShedEnabled", @"AdminTitaniumHardwareRateAdapterEnabled", @"AdminCADisplayLinkHookEnabled",
            @"AdminHomeTransitionShieldEnabled",
            @"AdminBackgroundAudioGuardEnabled", @"AdminBackgroundKeepAliveEnabled",
            @"AdminBackgroundContinuityEnabled",
            @"AdminMemoryGuardEnabled", @"AdminRateSentinelEnabled", @"AppProfiles"
        ];
    });
    return keys;
}

static NSString *PMServerProfileName(NSInteger mode)
{
    switch (mode) {
        case 1: return @"PREMIUM";
        case 2: return @"ADMIN";
        default: return @"FREE";
    }
}

static NSDictionary *PMServerDefaultSettings(NSInteger mode, NSDictionary *base)
{
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    if ([base isKindOfClass:[NSDictionary class]]) [settings addEntriesFromDictionary:base];

    NSDictionary *defaults = @{
        @"Enabled": @NO, @"RefreshRateEnabled": @NO, @"FPSOverrideEnabled": @NO,
        @"AdvancedDisplayEnforcement": @YES, @"FramePacing": @YES,
        @"AdaptiveFPS": @YES,
        @"ThermalGuard": @YES, @"BackgroundReduction": @YES, @"ConflictGuard": @YES,
        @"StutterFix": @YES, @"MetalLayerCompatibility": @YES,
        @"MetalFramebufferOnlyOptimization": @NO, @"AppStabilityFix": @YES,
        @"ScreenRecordingFix": @YES, @"OverrideBlockedApps": @NO,
        @"BatterySaver": @NO, @"ChargingOptimization": @NO,
        @"RefreshMode": @0, @"FPSMode": @0,
        @"CustomRefreshRate": @60, @"CustomFPS": @60, @"PerformancePreset": @0,
        @"FreeRenderSchedulerEnabled": @YES, @"FreeSmoothEngineEnabled": @YES, @"FreeTouchTuningEnabled": @YES,
        @"FreeAdaptiveCadenceEnabled": @YES, @"FreeThermalGuardEnabled": @YES,
        @"FreeCADisplayLinkHookEnabled": @YES,
        @"FreeBackgroundAudioGuardEnabled": @YES, @"FreeActivityBoostEnabled": @YES,
        @"FreeBackgroundKeepAliveEnabled": @YES,
        @"FreeBackgroundContinuityEnabled": @YES,
        @"FreeMemoryGuardEnabled": @YES, @"FreeRateSentinelEnabled": @YES,
        @"PremiumRenderSchedulerEnabled": @YES, @"PremiumTouchTuningEnabled": @YES,
        @"PremiumLowLatencyModeEnabled": @YES, @"PremiumThermalGuardEnabled": @YES,
        @"PremiumChargingGuardEnabled": @YES, @"PremiumTier4DisplayPolicyEnabled": @YES, @"PremiumCADisplayLinkHookEnabled": @YES,
        @"PremiumActivityBoostEnabled": @YES, @"PremiumBackgroundAudioGuardEnabled": @YES,
        @"PremiumBackgroundKeepAliveEnabled": @YES,
        @"PremiumBackgroundContinuityEnabled": @YES,
        @"PremiumMemoryGuardEnabled": @YES, @"PremiumRateSentinelEnabled": @YES,
        @"AdminRenderSchedulerEnabled": @YES, @"AdminTouchTuningEnabled": @YES,
        @"AdminFastScrollEnabled": @NO, @"AdminHideScrollIndicatorsEnabled": @NO,
        @"AdminStaticSurfaceCacheEnabled": @NO, @"AdminThermalCooldownEnabled": @YES,
        @"AdminLocalDaemonBridgeEnabled": @NO, @"AdminChargingCooldownEnabled": @YES,
        @"AdminAdaptiveFramePacingEnabled": @YES, @"AdminDashboardLoadShedEnabled": @YES,
        @"AdminTitaniumHardwareRateAdapterEnabled": @YES,
        @"AdminCADisplayLinkHookEnabled": @YES, @"AdminHomeTransitionShieldEnabled": @YES,
        @"AdminBackgroundAudioGuardEnabled": @YES, @"AdminBackgroundKeepAliveEnabled": @YES,
        @"AdminBackgroundContinuityEnabled": @YES,
        @"AdminMemoryGuardEnabled": @YES, @"AdminRateSentinelEnabled": @YES,
        @"AppProfiles": @{}
    };
    [defaults enumerateKeysAndObjectsUsingBlock:^(id key, id value, __unused BOOL *stop) {
        if (!settings[key]) settings[key] = value;
    }];

    // Keep tier capabilities explicit in each profile. They do not change CPU/GPU
    // clocks; they select which bounded, app-local optimization path may run.
    if (mode == 0) {
        settings[@"FreeRenderSchedulerEnabled"] = settings[@"FreeRenderSchedulerEnabled"] ?: @YES;
        settings[@"FreeTouchTuningEnabled"] = settings[@"FreeTouchTuningEnabled"] ?: @YES;
        settings[@"FreeAdaptiveCadenceEnabled"] = settings[@"FreeAdaptiveCadenceEnabled"] ?: @YES;
    } else if (mode == 1) {
        settings[@"PremiumRenderSchedulerEnabled"] = settings[@"PremiumRenderSchedulerEnabled"] ?: @YES;
        settings[@"PremiumTouchTuningEnabled"] = settings[@"PremiumTouchTuningEnabled"] ?: @YES;
        settings[@"PremiumLowLatencyModeEnabled"] = settings[@"PremiumLowLatencyModeEnabled"] ?: @YES;
        settings[@"PremiumThermalGuardEnabled"] = settings[@"PremiumThermalGuardEnabled"] ?: @YES;
        settings[@"PremiumChargingGuardEnabled"] = settings[@"PremiumChargingGuardEnabled"] ?: @YES;
    } else {
        settings[@"AdminRenderSchedulerEnabled"] = settings[@"AdminRenderSchedulerEnabled"] ?: @YES;
        settings[@"AdminTouchTuningEnabled"] = settings[@"AdminTouchTuningEnabled"] ?: @YES;
        settings[@"AdminThermalCooldownEnabled"] = settings[@"AdminThermalCooldownEnabled"] ?: @YES;
        settings[@"AdminChargingCooldownEnabled"] = settings[@"AdminChargingCooldownEnabled"] ?: @YES;
        settings[@"AdminAdaptiveFramePacingEnabled"] = settings[@"AdminAdaptiveFramePacingEnabled"] ?: @YES;
        settings[@"AdminDashboardLoadShedEnabled"] = settings[@"AdminDashboardLoadShedEnabled"] ?: @YES;
    }
    return [settings copy];
}

static NSDictionary *PMServerSnapshotFromDomain(NSDictionary *domain)
{
    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
    for (NSString *key in PMServerScopedConfigurationKeys()) {
        id value = domain[key];
        if (value) snapshot[key] = value;
    }
    return [snapshot copy];
}

static BOOL PMChangesContainServerSettings(NSDictionary *changes)
{
    for (NSString *key in PMServerScopedConfigurationKeys()) {
        if (changes[key]) return YES;
    }
    return NO;
}

static NSMutableDictionary *PMBuildDomainForServerChanges(NSDictionary *current, NSDictionary *changes)
{
    NSMutableDictionary *domain = [current isKindOfClass:[NSDictionary class]]
        ? [current mutableCopy] : [NSMutableDictionary dictionary];
    NSMutableDictionary *profiles = [domain[@"ServerProfiles"] isKindOfClass:[NSDictionary class]]
        ? [domain[@"ServerProfiles"] mutableCopy] : [NSMutableDictionary dictionary];

    // One-time migration: the pre-profile global configuration becomes FREE.
    // PREMIUM and ADMIN start from the same safe baseline but keep their own tier switches.
    if (profiles.count == 0) {
        NSDictionary *baseline = PMServerSnapshotFromDomain(domain);
        profiles[@"FREE"] = PMServerDefaultSettings(0, baseline);
        profiles[@"PREMIUM"] = PMServerDefaultSettings(1, baseline);
        profiles[@"ADMIN"] = PMServerDefaultSettings(2, baseline);
    } else {
        for (NSInteger mode = 0; mode <= 2; mode++) {
            NSString *name = PMServerProfileName(mode);
            NSDictionary *existing = [profiles[name] isKindOfClass:[NSDictionary class]] ? profiles[name] : @{};
            profiles[name] = PMServerDefaultSettings(mode, existing);
        }
    }

    NSInteger oldMode = [domain[@"ActiveServerMode"] respondsToSelector:@selector(integerValue)]
        ? MIN(MAX([domain[@"ActiveServerMode"] integerValue], 0), 2) : 0;
    BOOL requestsModeChange = changes[@"ActiveServerMode"] != nil;
    NSInteger newMode = requestsModeChange
        ? MIN(MAX([changes[@"ActiveServerMode"] integerValue], 0), 2) : oldMode;
    BOOL switching = requestsModeChange && newMode != oldMode;

    if (switching) {
        // Persist the outgoing server's entire configuration, including its per-app profiles.
        profiles[PMServerProfileName(oldMode)] = PMServerDefaultSettings(oldMode, PMServerSnapshotFromDomain(domain));
        NSDictionary *target = PMServerDefaultSettings(newMode, profiles[PMServerProfileName(newMode)]);
        for (NSString *key in PMServerScopedConfigurationKeys()) {
            id value = target[key];
            if (value) domain[key] = value;
            else [domain removeObjectForKey:key];
        }
        domain[@"ActiveServerMode"] = @(newMode);
        NSMutableDictionary *remaining = [changes mutableCopy];
        [remaining removeObjectForKey:@"ActiveServerMode"];
        [domain addEntriesFromDictionary:remaining];
        if (PMChangesContainServerSettings(remaining)) {
            profiles[PMServerProfileName(newMode)] = PMServerDefaultSettings(newMode, PMServerSnapshotFromDomain(domain));
        }
    } else {
        [domain addEntriesFromDictionary:changes];
        domain[@"ActiveServerMode"] = @(newMode);
        if (PMChangesContainServerSettings(changes)) {
            profiles[PMServerProfileName(newMode)] = PMServerDefaultSettings(newMode, PMServerSnapshotFromDomain(domain));
        }
    }

    domain[@"ServerProfiles"] = [profiles copy];
    domain[@"ServerProfilesSchemaVersion"] = @1;
    return domain;
}

static BOOL PMWriteDomainChanges(NSDictionary *changes)
{
    if (![changes isKindOfClass:[NSDictionary class]] || changes.count == 0) return YES;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDictionary *current = PMReadDomain();
    NSMutableDictionary *domain = PMBuildDomainForServerChanges(current, changes);

    // Persist the complete canonical snapshot: server switching may change dozens
    // of values at once. CFPreferences receives the same active profile as the app.
    [defaults setPersistentDomain:domain forName:PMDomainName];
    [defaults synchronize];
    CFPreferencesSetMultiple((__bridge CFDictionaryRef)domain, NULL,
                             (__bridge CFStringRef)PMDomainName,
                             kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    BOOL cfSyncOK = CFPreferencesAppSynchronize((__bridge CFStringRef)PMDomainName);
    if (!cfSyncOK) NSLog(@"[ProMotion Control] CFPreferences sync failed for %@", PMDomainName);

    // Keep the legacy Filza master switch aligned with the active server snapshot.
    id masterEnabledChange = domain[@"Enabled"];
    if ([masterEnabledChange respondsToSelector:@selector(boolValue)]) {
        CFStringRef legacyDomain = CFSTR("com.promotioncontrol.prefs");
        CFPreferencesSetAppValue(CFSTR("enabled"), (__bridge CFPropertyListRef)masterEnabledChange, legacyDomain);
        if (!CFPreferencesAppSynchronize(legacyDomain)) NSLog(@"[ProMotion Control] Legacy Filza master switch sync failed.");
    }

    NSMutableDictionary *verification = [changes mutableCopy];
    [verification addEntriesFromDictionary:PMServerSnapshotFromDomain(domain)];
    verification[@"ActiveServerMode"] = domain[@"ActiveServerMode"] ?: @0;
    verification[@"ServerProfiles"] = domain[@"ServerProfiles"] ?: @{};
    NSDictionary *roundTrip = PMReadDomain();
    __block BOOL verified = cfSyncOK;
    [verification enumerateKeysAndObjectsUsingBlock:^(id key, id value, __unused BOOL *stop) {
        id readValue = roundTrip[key];
        id cfValue = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                (__bridge CFStringRef)PMDomainName));
        BOOL foundationConfirmed = readValue && [readValue isEqual:value];
        BOOL coreFoundationConfirmed = cfValue && [cfValue isEqual:value];
        if (!foundationConfirmed && !coreFoundationConfirmed) verified = NO;
    }];
    PMLastWriteState = verified ? 1 : 0;
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)PMChangedNotification, NULL, NULL, true);
    return verified;
}

static NSDictionary *PMReadProfile(NSString *bundleID)
{
    NSDictionary *domain = PMReadDomain();
    NSDictionary *profiles = [domain[@"AppProfiles"] isKindOfClass:[NSDictionary class]] ? domain[@"AppProfiles"] : @{};
    NSDictionary *profile = [profiles[bundleID] isKindOfClass:[NSDictionary class]] ? profiles[bundleID] : @{};
    return profile;
}

// Best-effort app catalog. LaunchServices is queried dynamically and off the main
// thread; if the selector is unavailable or restricted, the UI falls back to
// saved profiles and manual Bundle ID entry without blocking navigation.
static id PMSafeSend(id target, SEL selector)
{
    if (!target || ![target respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

static dispatch_queue_t PMAppIconDecodeQueue(void)
{
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.dell.promotioncontrol.app-icon-decode", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

// Best-effort icon extraction from the already-discovered LaunchServices proxy.
// This runs on a utility queue and always falls back to the generic app symbol
// when the private selector is missing or restricted on a given iOS build.
static UIImage *PMInstalledAppIconForProxy(id proxy)
{
    if (!proxy) return nil;
    SEL selector = sel_registerName("iconDataForVariant:");
    if (![proxy respondsToSelector:selector]) return nil;
    for (NSInteger variant = 2; variant >= 0; variant--) {
        @try {
            id value = ((id (*)(id, SEL, NSInteger))objc_msgSend)(proxy, selector, variant);
            if (![value isKindOfClass:[NSData class]]) continue;
            NSData *data = (NSData *)value;
            if (data.length == 0 || data.length > (2 * 1024 * 1024)) continue;
            UIImage *image = [UIImage imageWithData:data];
            if (image) return image;
        } @catch (NSException *exception) {
            NSLog(@"[ProMotionControl] App icon lookup skipped: %@", exception.reason);
        } @catch (...) {
        }
    }
    return nil;
}

static NSArray<NSDictionary *> *PMInstalledAppRecords(void)
{
    @try {
        Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        id workspace = PMSafeSend((id)workspaceClass, sel_registerName("defaultWorkspace"));

        // Try the primary LaunchServices catalog API first, then compatible
        // alternatives found on some iOS/jailbreak builds. Call off the UI thread.
        id result = PMSafeSend(workspace, sel_registerName("allInstalledApplications"));
        if (![result isKindOfClass:[NSArray class]])
            result = PMSafeSend(workspace, sel_registerName("allApplications"));
        if (![result isKindOfClass:[NSArray class]])
            result = PMSafeSend(workspace, sel_registerName("installedApplications"));
        if (![result isKindOfClass:[NSArray class]]) return @[];

        NSMutableDictionary<NSString *, NSDictionary *> *unique = [NSMutableDictionary dictionary];
        for (id proxy in (NSArray *)result) {
            @autoreleasepool {
                id rawBundleID = PMSafeSend(proxy, sel_registerName("applicationIdentifier"));
                if (![rawBundleID isKindOfClass:[NSString class]])
                    rawBundleID = PMSafeSend(proxy, sel_registerName("bundleIdentifier"));
                if (![rawBundleID isKindOfClass:[NSString class]]) continue;
                NSString *bundleID = (NSString *)rawBundleID;
                // Include Apple/system apps in the catalogue. The manager app itself
                // is omitted, but system-critical runtime processes are excluded by Tweak.x.
                if (bundleID.length < 3 || [bundleID isEqualToString:@"com.dell.promotioncontrol.app"]) continue;
                id rawName = PMSafeSend(proxy, sel_registerName("localizedName"));
                if (![rawName isKindOfClass:[NSString class]] || [(NSString *)rawName length] == 0)
                    rawName = PMSafeSend(proxy, sel_registerName("name"));
                NSString *name = [rawName isKindOfClass:[NSString class]] && [(NSString *)rawName length]
                    ? (NSString *)rawName : bundleID;
                BOOL isSystem = [bundleID hasPrefix:@"com.apple."];
                // Keep the LaunchServices proxy for lazy, off-main-thread icon lookup.
                unique[bundleID] = @{ @"id": bundleID, @"name": name, @"isSystem": @(isSystem), @"proxy": proxy };
            }
        }
        return [[unique allValues] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
        }];
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] LaunchServices enumeration failed: %@: %@", exception.name, exception.reason);
        return @[];
    }
}

static BOOL PMWriteProfile(NSString *bundleID, NSDictionary *changes)
{
    if (bundleID.length == 0 || changes.count == 0) return NO;
    NSDictionary *domain = PMReadDomain();
    NSDictionary *oldProfiles = [domain[@"AppProfiles"] isKindOfClass:[NSDictionary class]] ? domain[@"AppProfiles"] : @{};
    NSMutableDictionary *profiles = [oldProfiles mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *profile = [PMReadProfile(bundleID) mutableCopy] ?: [NSMutableDictionary dictionary];
    [changes enumerateKeysAndObjectsUsingBlock:^(id key, id value, __unused BOOL *stop) {
        if (value == [NSNull null]) {
            [profile removeObjectForKey:key];
        } else if (key && value) {
            profile[key] = value;
        }
    }];
    // Selecting a per-app tuning value means the user intends to apply that
    // profile. Auto-enable it unless this same write explicitly blocks/disables
    // the app. This fixes older UI paths that saved rate values while leaving
    // the profile's seeded Enabled=NO flag in place.
    BOOL tuningChanged =
        changes[@"RefreshMode"] != nil ||
        changes[@"FPSMode"] != nil ||
        changes[@"CustomRefreshRate"] != nil ||
        changes[@"CustomFPS"] != nil ||
        changes[@"PerformanceMode"] != nil;
    id enabledChange = changes[@"Enabled"];
    id policyChange = changes[@"InterventionPolicy"];
    BOOL explicitlyDisabled = [enabledChange respondsToSelector:@selector(boolValue)] &&
                              ![enabledChange boolValue];
    BOOL explicitlyBlocked = [policyChange respondsToSelector:@selector(integerValue)] &&
                             [policyChange integerValue] == 2;
    if ([enabledChange respondsToSelector:@selector(boolValue)] && [enabledChange boolValue]) {
        profile[@"Enabled"] = @YES;
        profile[@"InterventionPolicy"] = @1;
    } else if (tuningChanged && !explicitlyDisabled && !explicitlyBlocked) {
        profile[@"Enabled"] = @YES;
        profile[@"InterventionPolicy"] = @1;
    }
    profiles[bundleID] = profile;

    NSMutableDictionary *globalChanges = [@{@"AppProfiles": profiles} mutableCopy];
    // A user explicitly enabling a profile also enables the two master switches
    // required by the existing runtime. Turning a single profile off does not
    // turn off any other application.
    BOOL explicitlyEnabled = [enabledChange respondsToSelector:@selector(boolValue)] &&
                             [enabledChange boolValue];
    if (explicitlyEnabled || (tuningChanged && !explicitlyDisabled && !explicitlyBlocked)) {
        globalChanges[@"Enabled"] = @YES;
        globalChanges[@"FramePacing"] = @YES;
    }
    return PMWriteDomainChanges(globalChanges);
}

static UILabel *PMLabel(NSString *text, CGFloat size, UIFontWeight weight, UIColor *color)
{
    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = PMTranslateString(text ?: @"");
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.numberOfLines = 0;
    return label;
}

static void PMStyleButton(UIButton *button, NSString *title)
{
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.layer.cornerRadius = 15.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = PMBorderColor().CGColor;
    button.backgroundColor = PMCardAltColor();
    button.layer.shadowColor = PMAccentColor().CGColor;
    button.layer.shadowOpacity = PMLightThemeSelected ? 0.03f : 0.12f;
    button.layer.shadowRadius = 8.0f;
    button.layer.shadowOffset = CGSizeZero;
    button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    button.titleLabel.numberOfLines = 2;
    button.titleLabel.textAlignment = NSTextAlignmentCenter;
    button.contentEdgeInsets = UIEdgeInsetsMake(10, 10, 10, 10);
    [button setTitle:PMTranslateString(title ?: @"") forState:UIControlStateNormal];
    [button setTitleColor:PMMutedColor() forState:UIControlStateNormal];
}

static UIButton *PMButton(NSString *title)
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    PMStyleButton(button, title);
    return button;
}

static UIView *PMSeparator(void)
{
    UIView *line = [UIView new];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    line.backgroundColor = PMBorderColor();
    [line.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale].active = YES;
    return line;
}

static UIStackView *PMNeonSectionHeader(NSString *title, NSString *symbol)
{
    UIStackView *header = [[UIStackView alloc] initWithFrame:CGRectZero];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;
    header.spacing = 10.0;
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = PMAccentColor();
    icon.layer.shadowColor = PMAccentColor().CGColor;
    icon.layer.shadowOpacity = PMLightThemeSelected ? 0.0f : 0.38f;
    icon.layer.shadowRadius = 8.0f;
    icon.layer.shadowOffset = CGSizeZero;
    [NSLayoutConstraint activateConstraints:@[[icon.widthAnchor constraintEqualToConstant:25.0], [icon.heightAnchor constraintEqualToConstant:25.0]]];
    [header addArrangedSubview:icon];
    UILabel *label = PMLabel(title ?: @"", 16.0, UIFontWeightBold, PMAccentColor());
    [header addArrangedSubview:label];
    return header;
}

static void PMApplyNeonSurface(UIView *view, CGFloat radius)
{
    if (!view) return;
    view.layer.cornerRadius = radius;
    view.layer.borderWidth = 1.0;
    view.layer.borderColor = PMBorderColor().CGColor;
    view.layer.shadowColor = PMAccentColor().CGColor;
    view.layer.shadowOpacity = PMLightThemeSelected ? 0.05f : 0.16f;
    view.layer.shadowRadius = PMLightThemeSelected ? 5.0f : 12.0f;
    view.layer.shadowOffset = CGSizeZero;
    view.layer.masksToBounds = NO;
}

@interface PMTelemetryWaveformView : UIView
@property (nonatomic, strong) NSMutableArray<NSNumber *> *samples;
- (void)appendValue:(CGFloat)value;
@end

@implementation PMTelemetryWaveformView

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        self.opaque = NO;
        self.backgroundColor = UIColor.clearColor;
        self.samples = [NSMutableArray array];
        for (NSUInteger index = 0; index < 42; index++) [self.samples addObject:@(0.0)];
        self.accessibilityLabel = @"Biểu đồ biến thiên tải CPU theo thời gian";
    }
    return self;
}

- (void)appendValue:(CGFloat)value
{
    if (!isfinite(value)) return;
    CGFloat safeValue = MIN(MAX(value, 0.0), 100.0);
    [self.samples addObject:@(safeValue)];
    while (self.samples.count > 42) [self.samples removeObjectAtIndex:0];
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect
{
    [super drawRect:rect];
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (!context) return;
    CGRect bounds = self.bounds;
    if (CGRectGetWidth(bounds) < 4.0 || CGRectGetHeight(bounds) < 4.0) return;

    UIColor *grid = PMLightThemeSelected
        ? [PMRGB(0, 105, 210) colorWithAlphaComponent:0.12]
        : [PMRGB(67, 204, 218) colorWithAlphaComponent:0.16];
    CGContextSetStrokeColorWithColor(context, grid.CGColor);
    CGContextSetLineWidth(context, 0.6);
    for (NSUInteger row = 1; row < 4; row++) {
        CGFloat y = CGRectGetHeight(bounds) * (CGFloat)row / 4.0;
        CGContextMoveToPoint(context, 0.0, y);
        CGContextAddLineToPoint(context, CGRectGetMaxX(bounds), y);
    }
    for (NSUInteger column = 1; column < 8; column++) {
        CGFloat x = CGRectGetWidth(bounds) * (CGFloat)column / 8.0;
        CGContextMoveToPoint(context, x, 0.0);
        CGContextAddLineToPoint(context, x, CGRectGetMaxY(bounds));
    }
    CGContextStrokePath(context);

    if (self.samples.count < 2) return;
    CGFloat minimum = 100.0, maximum = 0.0;
    for (NSNumber *number in self.samples) {
        CGFloat sample = number.doubleValue;
        minimum = MIN(minimum, sample);
        maximum = MAX(maximum, sample);
    }
    CGFloat range = MAX(4.0, maximum - minimum);
    CGFloat top = CGRectGetHeight(bounds) * 0.16;
    CGFloat drawableHeight = CGRectGetHeight(bounds) * 0.68;
    UIBezierPath *line = [UIBezierPath bezierPath];
    line.lineWidth = 2.0;
    line.lineJoinStyle = kCGLineJoinRound;
    line.lineCapStyle = kCGLineCapRound;

    NSUInteger count = self.samples.count;
    for (NSUInteger index = 0; index < count; index++) {
        CGFloat x = CGRectGetWidth(bounds) * (CGFloat)index / (CGFloat)(count - 1);
        CGFloat normalized = (self.samples[index].doubleValue - minimum) / range;
        CGFloat y = top + (1.0 - normalized) * drawableHeight;
        if (index == 0) [line moveToPoint:CGPointMake(x, y)];
        else [line addLineToPoint:CGPointMake(x, y)];
    }

    UIBezierPath *area = [line copy];
    CGPoint finalPoint = [line currentPoint];
    [area addLineToPoint:CGPointMake(finalPoint.x, CGRectGetHeight(bounds) * 0.91)];
    [area addLineToPoint:CGPointMake(0.0, CGRectGetHeight(bounds) * 0.91)];
    [area closePath];
    UIColor *waveColor = PMLightThemeSelected ? PMRGB(0, 126, 215) : PMRGB(54, 226, 207);
    [[waveColor colorWithAlphaComponent:0.13] setFill];
    [area fill];
    [waveColor setStroke];
    [line stroke];
}

@end

@interface PMNeonGradientView : UIView
@property (nonatomic, strong) CAGradientLayer *pmGradientLayer;
@end

@implementation PMNeonGradientView
- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        self.pmGradientLayer = [CAGradientLayer layer];
        self.pmGradientLayer.startPoint = CGPointMake(0.0, 0.0);
        self.pmGradientLayer.endPoint = CGPointMake(1.0, 1.0);
        self.pmGradientLayer.colors = PMLightThemeSelected
            ? @[(__bridge id)PMRGB(75, 143, 220).CGColor, (__bridge id)PMRGB(147, 104, 220).CGColor]
            : @[(__bridge id)PMRGB(11, 112, 147).CGColor, (__bridge id)PMRGB(14, 57, 91).CGColor, (__bridge id)PMRGB(8, 24, 37).CGColor];
        self.pmGradientLayer.locations = @[@0.0, @0.62, @1.0];
        [self.layer insertSublayer:self.pmGradientLayer atIndex:0];
        self.layer.cornerRadius = 20.0;
        self.layer.masksToBounds = YES;
    }
    return self;
}
- (void)layoutSubviews
{
    [super layoutSubviews];
    self.pmGradientLayer.frame = self.bounds;
    self.pmGradientLayer.cornerRadius = self.layer.cornerRadius;
}
@end

@interface PMModeChip : UIButton
@property (nonatomic, copy) NSString *prefKey;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic) NSInteger modeValue;
@end

@interface PMCustomChip : UIButton
@property (nonatomic, copy) NSString *customKey;
@property (nonatomic, copy) NSString *modeKey;
@property (nonatomic, copy) NSString *bundleID;
@end

@interface PMRouteButton : UIButton
@property (nonatomic, copy) NSString *route;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *appName;
@end

// Minimal implementations: these UIButton subclasses store routing/mode state.
@implementation PMModeChip
@end

@implementation PMCustomChip
@end

@implementation PMRouteButton
@end

@interface PMRateSettingsViewController : PMBaseViewController
@end
@interface PMAppsViewController : PMBaseViewController <UISearchBarDelegate>
@property (nonatomic, copy) NSArray<NSDictionary *> *installedApps;
@property (nonatomic, strong) UISearchBar *appSearchBar;
@property (nonatomic, strong) UISegmentedControl *filterControl;
@property (nonatomic, strong) UIStackView *resultsStack;
@property (nonatomic, copy) NSString *searchText;
@property (nonatomic) NSInteger filterIndex;
@property (nonatomic) BOOL enumerationStarted;
@property (nonatomic) BOOL enumerationFinished;
@property (nonatomic) BOOL enumerationTimedOut;
@property (nonatomic) NSUInteger displayLimit;
- (void)buildAppsScreen;
- (void)loadInstalledApps;
- (void)refreshResults;
- (void)showMoreResults:(UIButton *)sender;
- (void)addProfile;
@end
@interface PMAdvancedViewController : PMBaseViewController
@end
@interface PMDiagnosticsViewController : PMBaseViewController
@end
@interface PMSettingsViewController : PMBaseViewController
- (void)chooseTheme:(UITapGestureRecognizer *)gesture;
- (void)chooseLanguage:(UITapGestureRecognizer *)gesture;
@end
@interface PMInfoViewController : PMBaseViewController
- (void)confirmSafeClean;
- (void)chooseInfoAppearance:(UITapGestureRecognizer *)gesture;
- (void)chooseInfoLanguage:(UITapGestureRecognizer *)gesture;
@end
@interface PMChipInfoViewController : PMBaseViewController
@property (nonatomic) NSInteger selectedInfoIndex;
@property (nonatomic, strong) UISegmentedControl *infoSegments;
@property (nonatomic, strong) NSTimer *metricsTimer;
@property (nonatomic, strong) UILabel *cpuLoadValueLabel;
@property (nonatomic) BOOL cpuUsageSamplePending;
@property (nonatomic, strong) UILabel *processMemoryValueLabel;
@property (nonatomic, strong) UILabel *batteryValueLabel;
@property (nonatomic, strong) UILabel *thermalValueLabel;
@end
@interface PMAppProfileViewController : PMBaseViewController
@property (nonatomic, copy) NSString *bundleID;
- (instancetype)initWithBundleID:(NSString *)bundleID;
@end

@interface PMBaseViewController ()
@property (nonatomic, strong) UIView *pmOrientationSweepContainer;
@property (nonatomic, strong) CAGradientLayer *pmOrientationSweepLayer;
@end

@implementation PMBaseViewController

// ProMotion Control's pages are built to adapt to both phone orientations.
// This explicit mask mirrors Info.plist and keeps all five tabs consistent.
- (BOOL)shouldAutorotate
{
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        return UIInterfaceOrientationMaskAll;
    }
    return UIInterfaceOrientationMaskPortrait |
           UIInterfaceOrientationMaskLandscapeLeft |
           UIInterfaceOrientationMaskLandscapeRight;
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];

    BOOL currentlyLandscape = CGRectGetWidth(self.view.bounds) > CGRectGetHeight(self.view.bounds);
    BOOL willBeLandscape = size.width > size.height;
    if (currentlyLandscape == willBeLandscape || !coordinator) {
        [self.view setNeedsLayout];
        return;
    }

    // Respect Reduce Motion. UIKit still performs the rotation and adaptive
    // layout; only the optional decorative sweep/settle animation is skipped.
    BOOL reduceMotion = UIAccessibilityIsReduceMotionEnabled();
    UIView *content = self.scrollView ?: self.view;
    if (!reduceMotion) {
        // A very small settle transition avoids a large fake rotation transform
        // that could fight UIKit's own orientation animation or Auto Layout.
        content.transform = CGAffineTransformMakeScale(0.988, 0.988);
        content.alpha = 0.965;

        [self.pmOrientationSweepContainer removeFromSuperview];
        self.pmOrientationSweepContainer = [UIView new];
        self.pmOrientationSweepContainer.translatesAutoresizingMaskIntoConstraints = NO;
        self.pmOrientationSweepContainer.userInteractionEnabled = NO;
        self.pmOrientationSweepContainer.clipsToBounds = YES;
        self.pmOrientationSweepContainer.backgroundColor = UIColor.clearColor;
        [self.view addSubview:self.pmOrientationSweepContainer];
        [NSLayoutConstraint activateConstraints:@[
            [self.pmOrientationSweepContainer.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:1.0],
            [self.pmOrientationSweepContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [self.pmOrientationSweepContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
            [self.pmOrientationSweepContainer.heightAnchor constraintEqualToConstant:3.0]
        ]];

        self.pmOrientationSweepLayer = [CAGradientLayer layer];
        UIColor *accent = PMAccentColor();
        self.pmOrientationSweepLayer.colors = @[
            (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor,
            (id)[accent colorWithAlphaComponent:0.92].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor
        ];
        self.pmOrientationSweepLayer.locations = @[@0.0, @0.5, @1.0];
        self.pmOrientationSweepLayer.startPoint = CGPointMake(0.0, 0.5);
        self.pmOrientationSweepLayer.endPoint = CGPointMake(1.0, 0.5);
        self.pmOrientationSweepLayer.bounds = CGRectMake(0.0, 0.0, 160.0, 3.0);
        self.pmOrientationSweepLayer.position = CGPointMake(-80.0, 1.5);
        [self.pmOrientationSweepContainer.layer addSublayer:self.pmOrientationSweepLayer];

        CABasicAnimation *sweep = [CABasicAnimation animationWithKeyPath:@"position.x"];
        sweep.fromValue = @(-80.0);
        sweep.toValue = @(MAX(160.0, size.width + 80.0));
        sweep.duration = MIN(0.42, MAX(0.24, coordinator.transitionDuration * 0.82));
        sweep.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        sweep.removedOnCompletion = YES;
        [self.pmOrientationSweepLayer addAnimation:sweep forKey:@"pm.orientation.lightSweep"];
    }

    __weak typeof(self) weakSelf = self;
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        (void)context;
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (!reduceMotion) {
            content.transform = CGAffineTransformIdentity;
            content.alpha = 1.0;
        }
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
    } completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        (void)context;
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        content.transform = CGAffineTransformIdentity;
        content.alpha = 1.0;
        [self.pmOrientationSweepLayer removeAllAnimations];
        [self.pmOrientationSweepLayer removeFromSuperlayer];
        self.pmOrientationSweepLayer = nil;
        [self.pmOrientationSweepContainer removeFromSuperview];
        self.pmOrientationSweepContainer = nil;
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
    }];
}

- (BOOL)pm_isAdminServerActive
{
    // Base pages do not own the ADMIN session; only the root controller does.
    return NO;
}

- (void)pm_refreshActiveServerRuntime
{
    // Server switches can live on a subpage. Route the change to the root
    // controller immediately so the selected tier's engine follows the same
    // master/tier switches without starting a second engine in the subpage.
    UIViewController *root = self.navigationController.viewControllers.firstObject;
    if (![root isKindOfClass:[PMBaseViewController class]]) root = self.tabBarController.selectedViewController;
    SEL refreshSelector = NSSelectorFromString(@"refreshActiveServerRuntime");
    if ([root respondsToSelector:refreshSelector]) {
        IMP implementation = [root methodForSelector:refreshSelector];
        if (implementation) ((void (*)(id, SEL))implementation)(root, refreshSelector);
    }
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = PMBackgroundColor();
    self.modeChips = [NSMutableArray array];
    self.customChips = [NSMutableArray array];
    [self setupContent];
}

- (void)setupContent
{
    if (self.scrollView) return;
    self.scrollView = [UIScrollView new];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:self.scrollView];
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    self.contentStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    self.contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentStack.axis = UILayoutConstraintAxisVertical;
    self.contentStack.spacing = 16.0;
    [self.scrollView addSubview:self.contentStack];
    [NSLayoutConstraint activateConstraints:@[
        [self.contentStack.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor constant:18.0],
        [self.contentStack.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor constant:18.0],
        [self.contentStack.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor constant:-18.0],
        [self.contentStack.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor constant:-26.0],
        [self.contentStack.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor constant:-36.0]
    ]];
}

- (void)clearContent
{
    for (UIView *view in [self.contentStack.arrangedSubviews copy]) {
        [self.contentStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    [self.modeChips removeAllObjects];
    [self.customChips removeAllObjects];
}

- (UIStackView *)newCardWithTitle:(NSString *)title subtitle:(NSString *)subtitle
{
    UIView *card = [UIView new];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = PMCardColor();
    PMApplyNeonSurface(card, 22.0);

    UIStackView *inside = [[UIStackView alloc] initWithFrame:CGRectZero];
    inside.translatesAutoresizingMaskIntoConstraints = NO;
    inside.axis = UILayoutConstraintAxisVertical;
    inside.spacing = 11.0;
    [card addSubview:inside];
    [NSLayoutConstraint activateConstraints:@[
        [inside.topAnchor constraintEqualToAnchor:card.topAnchor constant:16.0],
        [inside.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16.0],
        [inside.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16.0],
        [inside.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16.0]
    ]];
    if (title.length) [inside addArrangedSubview:PMLabel(title, 16, UIFontWeightBold, PMPrimaryTextColor())];
    if (subtitle.length) [inside addArrangedSubview:PMLabel(subtitle, 12, UIFontWeightRegular, PMMutedColor())];
    [self.contentStack addArrangedSubview:card];
    return inside;
}

- (void)addHeaderWithEyebrow:(NSString *)eyebrow title:(NSString *)title subtitle:(NSString *)subtitle
{
    UIStackView *header = [[UIStackView alloc] initWithFrame:CGRectZero];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.axis = UILayoutConstraintAxisVertical;
    header.spacing = 6.0;
    UILabel *top = PMLabel(eyebrow.uppercaseString, 10, UIFontWeightBold, PMAccentColor());
    UILabel *main = PMLabel(title, 31, UIFontWeightBold, PMPrimaryTextColor());
    UILabel *detail = PMLabel(subtitle, 13, UIFontWeightRegular, PMMutedColor());
    [header addArrangedSubview:top];
    [header addArrangedSubview:main];
    [header addArrangedSubview:detail];
    [self.contentStack addArrangedSubview:header];
}

- (void)addNote:(NSString *)note toStack:(UIStackView *)stack
{
    UILabel *label = PMLabel(note, 12, UIFontWeightRegular, PMMutedColor());
    [stack addArrangedSubview:label];
}

- (void)addSwitchRows:(NSArray<NSDictionary *> *)rows title:(NSString *)title toStack:(UIStackView *)stack
{
    UIView *card = [UIView new];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = PMCardColor();
    PMApplyNeonSurface(card, 21.0);

    UIStackView *inside = [[UIStackView alloc] initWithFrame:CGRectZero];
    inside.translatesAutoresizingMaskIntoConstraints = NO;
    inside.axis = UILayoutConstraintAxisVertical;
    inside.spacing = 10;
    [card addSubview:inside];
    [NSLayoutConstraint activateConstraints:@[
        [inside.topAnchor constraintEqualToAnchor:card.topAnchor constant:15],
        [inside.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:15],
        [inside.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-15],
        [inside.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-15]
    ]];
    if (title.length) [inside addArrangedSubview:PMLabel(title, 16, UIFontWeightBold, PMPrimaryTextColor())];

    // Read preferences once per card, not once per row. CFPreferences synchronization
    // on the main thread for every switch can stall launch on some jailbreak setups.
    NSDictionary *domainSnapshot = PMReadDomain();
    for (NSUInteger idx = 0; idx < rows.count; idx++) {
        NSDictionary *rowData = rows[idx];
        UIStackView *row = [[UIStackView alloc] initWithFrame:CGRectZero];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        row.axis = UILayoutConstraintAxisHorizontal;
        row.alignment = UIStackViewAlignmentCenter;
        row.spacing = 14;
        NSString *symbolName = [rowData[@"symbol"] isKindOfClass:[NSString class]] ? rowData[@"symbol"] : nil;
        if (symbolName.length) {
            UIImageView *symbolView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbolName]];
            symbolView.translatesAutoresizingMaskIntoConstraints = NO;
            symbolView.tintColor = PMAccentColor();
            symbolView.contentMode = UIViewContentModeScaleAspectFit;
            symbolView.layer.shadowColor = PMAccentColor().CGColor;
            symbolView.layer.shadowOpacity = PMLightThemeSelected ? 0.0f : 0.35f;
            symbolView.layer.shadowRadius = 7.0f;
            symbolView.layer.shadowOffset = CGSizeZero;
            [NSLayoutConstraint activateConstraints:@[
                [symbolView.widthAnchor constraintEqualToConstant:25.0],
                [symbolView.heightAnchor constraintEqualToConstant:25.0]
            ]];
            [row addArrangedSubview:symbolView];
        }
        UIStackView *texts = [[UIStackView alloc] initWithFrame:CGRectZero];
        texts.translatesAutoresizingMaskIntoConstraints = NO;
        texts.axis = UILayoutConstraintAxisVertical;
        texts.spacing = 3;
        [texts addArrangedSubview:PMLabel(rowData[@"title"] ?: @"", 14, UIFontWeightSemibold, PMPrimaryTextColor())];
        if ([rowData[@"subtitle"] isKindOfClass:[NSString class]])
            [texts addArrangedSubview:PMLabel(rowData[@"subtitle"], 11, UIFontWeightRegular, PMMutedColor())];
        [row addArrangedSubview:texts];
        [texts setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        NSString *key = rowData[@"key"];
        id value = rowData[@"value"] ?: (key.length ? domainSnapshot[key] : nil);
        BOOL on = value ? [value boolValue] : [rowData[@"default"] boolValue];
        UISwitch *toggle = [UISwitch new];
        toggle.on = on;
        toggle.onTintColor = PMAccentColor();
        toggle.accessibilityIdentifier = [key hasPrefix:@"profile|"] ? key : [NSString stringWithFormat:@"global|%@", key ?: @""];
        [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        [row addArrangedSubview:toggle];
        [inside addArrangedSubview:row];
        if (idx + 1 < rows.count) [inside addArrangedSubview:PMSeparator()];
    }
    [stack addArrangedSubview:card];
}

- (void)addModePickerForKey:(NSString *)key title:(NSString *)title subtitle:(NSString *)subtitle bundleID:(NSString *)bundleID
{
    UIStackView *inside = [self newCardWithTitle:title subtitle:subtitle];
    NSArray<NSNumber *> *values = bundleID.length ? @[@(-2), @0, @30, @60, @90, @120, @144, @244] : @[@0, @30, @60, @90, @120, @144, @244];
    NSArray<NSString *> *labels = bundleID.length ? @[@"Dùng chung", @"Auto", @"30", @"60", @"90", @"120", @"144", @"244"] : @[@"Auto", @"30", @"60", @"90", @"120", @"144", @"244"];
    NSUInteger firstRowCount = values.count >= 7 ? 4 : 3;
    for (NSUInteger start = 0; start < values.count; start += firstRowCount) {
        NSUInteger end = MIN(start + firstRowCount, values.count);
        UIStackView *row = [[UIStackView alloc] initWithFrame:CGRectZero];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        row.axis = UILayoutConstraintAxisHorizontal;
        row.spacing = 7;
        row.distribution = UIStackViewDistributionFillEqually;
        for (NSUInteger idx = start; idx < end; idx++) {
            PMModeChip *chip = [PMModeChip buttonWithType:UIButtonTypeSystem];
            PMStyleButton(chip, labels[idx]);
            chip.prefKey = key;
            chip.modeValue = values[idx].integerValue;
            chip.bundleID = bundleID;
            chip.accessibilityIdentifier = [NSString stringWithFormat:@"%@|%@|%ld", bundleID.length ? @"profile" : @"global", bundleID.length ? bundleID : @"", (long)chip.modeValue];
            if (!bundleID.length) chip.accessibilityIdentifier = [NSString stringWithFormat:@"global|%@|%ld", key, (long)chip.modeValue];
            else chip.accessibilityIdentifier = [NSString stringWithFormat:@"profile|%@|%@|%ld", bundleID, key, (long)chip.modeValue];
            [chip.heightAnchor constraintEqualToConstant:42].active = YES;
            [chip addTarget:self action:@selector(modeTapped:) forControlEvents:UIControlEventTouchUpInside];
            [row addArrangedSubview:chip];
            [self.modeChips addObject:chip];
        }
        while (row.arrangedSubviews.count < firstRowCount) {
            UIView *spacer = [UIView new];
            [row addArrangedSubview:spacer];
        }
        [inside addArrangedSubview:row];
    }

    PMCustomChip *custom = [PMCustomChip buttonWithType:UIButtonTypeSystem];
    PMStyleButton(custom, @"Tùy chỉnh…");
    custom.customKey = [key isEqualToString:@"RefreshMode"] ? @"CustomRefreshRate" : @"CustomFPS";
    custom.modeKey = key;
    custom.bundleID = bundleID;
    [custom addTarget:self action:@selector(customTapped:) forControlEvents:UIControlEventTouchUpInside];
    [custom.heightAnchor constraintEqualToConstant:42].active = YES;
    [inside addArrangedSubview:custom];
    [self.customChips addObject:custom];
    [self refreshModeChips];
}

- (void)refreshModeChips
{
    NSDictionary *domain = PMReadDomain();
    NSDictionary *profiles = [domain[@"AppProfiles"] isKindOfClass:[NSDictionary class]] ? domain[@"AppProfiles"] : @{};
    for (PMModeChip *chip in self.modeChips) {
        NSInteger selected = 0;
        if (chip.bundleID.length) {
            NSDictionary *profile = [profiles[chip.bundleID] isKindOfClass:[NSDictionary class]] ? profiles[chip.bundleID] : @{};
            selected = profile[chip.prefKey] ? [profile[chip.prefKey] integerValue] : -2;
        } else {
            selected = domain[chip.prefKey] ? [domain[chip.prefKey] integerValue] : 0;
        }
        BOOL on = selected == chip.modeValue;
        chip.backgroundColor = on ? (PMLightThemeSelected ? PMRGB(199, 224, 252) : PMRGB(64, 35, 105)) : PMCardAltColor();
        chip.layer.borderColor = (on ? PMAccentColor() : PMBorderColor()).CGColor;
        [chip setTitleColor:(on ? PMPrimaryTextColor() : PMMutedColor()) forState:UIControlStateNormal];
    }
    for (PMCustomChip *chip in self.customChips) {
        NSInteger selected = 0;
        NSDictionary *source = domain;
        if (chip.bundleID.length) {
            source = PMReadProfile(chip.bundleID);
            selected = [source[chip.modeKey] integerValue];
        } else {
            selected = [domain[chip.modeKey] integerValue];
        }
        NSInteger custom = [source[chip.customKey] respondsToSelector:@selector(integerValue)]
            ? [source[chip.customKey] integerValue] : 60;
        custom = MIN(MAX(custom, 10), 244);
        NSString *unit = [chip.customKey isEqualToString:@"CustomRefreshRate"] ? @"Hz" : @"FPS";
        [chip setTitle:[NSString stringWithFormat:@"Tùy chỉnh %@: %ld %@", unit, (long)custom, unit]
              forState:UIControlStateNormal];
        BOOL on = selected == -1;
        chip.backgroundColor = on ? (PMLightThemeSelected ? PMRGB(199, 224, 252) : PMRGB(64, 35, 105)) : PMCardAltColor();
        chip.layer.borderColor = (on ? PMAccentColor() : PMBorderColor()).CGColor;
        [chip setTitleColor:(on ? PMPrimaryTextColor() : PMMutedColor()) forState:UIControlStateNormal];
    }
}

- (void)showWriteFailure
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Chưa xác nhận được lưu cấu hình"
                                                                   message:@"Ứng dụng đã thử ghi domain com.dell.promotioncontrol bằng API Preferences công khai nhưng không đọc lại được giá trị vừa lưu. Giao diện vẫn mở, nhưng runtime có thể chưa nhận cài đặt. Bản thử không sử dụng entitlement để vượt sandbox."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Đã hiểu" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)modeTapped:(PMModeChip *)sender
{
    BOOL ok = NO;
    if (sender.bundleID.length) {
        ok = PMWriteProfile(sender.bundleID, @{sender.prefKey: @(sender.modeValue)});
    } else {
        NSString *enableKey = [sender.prefKey isEqualToString:@"RefreshMode"] ? @"RefreshRateEnabled" : @"FPSOverrideEnabled";
        ok = PMWriteDomainChanges(@{
            sender.prefKey: @(sender.modeValue),
            enableKey: @(sender.modeValue != 0),
            @"Enabled": @YES,
            @"FramePacing": @YES,
            @"AdvancedDisplayEnforcement": @YES,
            @"ExactRateEnforcement": @YES
        });
    }
    [self refreshModeChips];
    if (!ok) [self showWriteFailure];
    [self pm_refreshActiveServerRuntime];
}

- (void)customTapped:(PMCustomChip *)sender
{
    NSString *unit = [sender.customKey isEqualToString:@"CustomRefreshRate"] ? @"Hz" : @"FPS";
    NSDictionary *profile = sender.bundleID.length ? PMReadProfile(sender.bundleID) : @{};
    id old = sender.bundleID.length ? profile[sender.customKey] : PMReadDomain()[sender.customKey];
    NSInteger current = old ? [old integerValue] : 60;
    current = MIN(MAX(current, 10), 244);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Tùy chỉnh %@", unit]
                                                                   message:@"Nhập đúng mục tiêu từ 10 đến 244. Runtime sẽ khai báo và khóa đúng giá trị này; tần số hiển thị vật lý vẫn do panel quyết định."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = UIKeyboardTypeNumberPad;
        field.text = [NSString stringWithFormat:@"%ld", (long)current];
        field.placeholder = [NSString stringWithFormat:@"10–244 %@", unit];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Lưu" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        NSInteger value = MIN(MAX(alert.textFields.firstObject.text.integerValue, 10), 244);
        BOOL ok = NO;
        if (sender.bundleID.length) {
            ok = PMWriteProfile(sender.bundleID, @{
                sender.customKey: @(value), sender.modeKey: @(-1),
                @"ExactRateEnforcement": @YES
            });
        } else {
            NSString *enableKey = [sender.modeKey isEqualToString:@"RefreshMode"] ? @"RefreshRateEnabled" : @"FPSOverrideEnabled";
            ok = PMWriteDomainChanges(@{
                sender.customKey: @(value), sender.modeKey: @(-1), enableKey: @YES,
                @"Enabled": @YES, @"FramePacing": @YES, @"AdvancedDisplayEnforcement": @YES,
                @"ExactRateEnforcement": @YES
            });
        }
        [self refreshModeChips];
        if (!ok) [self showWriteFailure];
        [self pm_refreshActiveServerRuntime];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)switchChanged:(UISwitch *)sender
{
    NSArray<NSString *> *parts = [sender.accessibilityIdentifier componentsSeparatedByString:@"|"];
    BOOL ok = NO;
    if (parts.count >= 3 && [parts[0] isEqualToString:@"profile"]) {
        NSString *bundleID = parts[1];
        NSString *key = parts[2];
        if ([key isEqualToString:@"Enabled"] && !sender.isOn) {
            // Make an intentional per-app OFF distinguishable from a profile row
            // that was only seeded with inheritance defaults. This avoids legacy
            // seed profiles suppressing global enforcement for otherwise eligible apps.
            ok = PMWriteProfile(bundleID, @{@"Enabled": @NO, @"InterventionPolicy": @2});
        } else {
            ok = PMWriteProfile(bundleID, @{key: @(sender.isOn)});
        }
    } else if (parts.count >= 2) {
        NSString *key = parts.lastObject;
        NSMutableDictionary *updates = [@{key: @(sender.isOn)} mutableCopy];
        if ([key isEqualToString:@"Enabled"]) updates[@"RuntimeState"] = sender.isOn ? @"Đã bật từ ứng dụng ProMotion Control" : @"Đã tắt từ ứng dụng ProMotion Control";
        if ([key isEqualToString:@"AdvancedDisplayEnforcement"] && sender.isOn) {
            updates[@"Enabled"] = @YES;
            updates[@"FramePacing"] = @YES;
            updates[@"RuntimeState"] = @"Đã bật runtime toàn cục cho app UIKit tương thích";
        }
        if ([key isEqualToString:@"OverrideBlockedApps"] && sender.isOn) {
            // One explicit opt-in enables the master and global switches too.
            updates[@"AdvancedDisplayEnforcement"] = @YES;
            updates[@"Enabled"] = @YES;
            updates[@"FramePacing"] = @YES;
            updates[@"RuntimeState"] = @"Áp dụng Hz/FPS cho app tương thích, kể cả hồ sơ bị chặn";
        }
        ok = PMWriteDomainChanges(updates);
    }
    if (!ok) {
        sender.on = !sender.isOn;
        [self showWriteFailure];
        return;
    }
    NSString *changedKey = parts.count >= 2 ? parts.lastObject : @"";
    if (!(parts.count >= 3 && [parts[0] isEqualToString:@"profile"])) {
        // All global switches and active-tier switches are immediately reflected
        // in the corresponding server engine; inactive tier snapshots are untouched.
        [self pm_refreshActiveServerRuntime];
    }
}

- (BOOL)pm_selectRootTabAtIndex:(NSUInteger)index
{
    UITabBarController *tabs = self.tabBarController;
    if (!tabs && self.navigationController) tabs = self.navigationController.tabBarController;
    if (!tabs || index >= tabs.viewControllers.count) return NO;

    UIViewController *candidate = tabs.viewControllers[index];
    if ([candidate isKindOfClass:[UINavigationController class]]) {
        UINavigationController *navigation = (UINavigationController *)candidate;
        if (navigation.viewControllers.count > 1) [navigation popToRootViewControllerAnimated:NO];
    }
    tabs.selectedIndex = index;
    return YES;
}

- (void)routeTapped:(PMRouteButton *)sender
{
    NSString *route = sender.route ?: @"";

    // External HTTPS links use the system URL handler: universal links may open
    // their app (e.g. Discord); otherwise iOS opens the user's default browser.
    if ([route hasPrefix:@"external:"]) {
        NSString *rawURL = [route substringFromIndex:[@"external:" length]];
        NSURL *url = [NSURL URLWithString:rawURL];
        if (!url || ![[url.scheme lowercaseString] isEqualToString:@"https"]) {
            NSLog(@"[ProMotionControl] Rejected invalid external URL: %@", rawURL);
            return;
        }
        __weak typeof(self) weakSelf = self;
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL success) {
            if (!success) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) self = weakSelf;
                    if (!self || !self.view.window) return;
                    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Không mở được liên kết"
                                                                                   message:@"iOS không thể mở liên kết này. Hãy thử lại hoặc kiểm tra kết nối mạng."
                                                                            preferredStyle:UIAlertControllerStyleAlert];
                    [alert addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleDefault handler:nil]];
                    [self presentViewController:alert animated:YES completion:nil];
                });
            }
        }];
        return;
    }

    if ([route isEqualToString:@"apps"]) {
        if ([self pm_selectRootTabAtIndex:1]) return;
        PMAppsViewController *apps = [PMAppsViewController new];
        if (self.navigationController) {
            [self.navigationController pushViewController:apps animated:YES];
        } else {
            UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:apps];
            navigation.modalPresentationStyle = UIModalPresentationFullScreen;
            [self presentViewController:navigation animated:YES completion:nil];
        }
    } else if ([route isEqualToString:@"hzfps"]) {
        [self.navigationController pushViewController:[PMRateSettingsViewController new] animated:YES];
    } else if ([route isEqualToString:@"advanced"]) {
        [self.navigationController pushViewController:[PMAdvancedViewController new] animated:YES];
    } else if ([route isEqualToString:@"settings"]) {
        [self.navigationController pushViewController:[PMSettingsViewController new] animated:YES];
    } else if ([route isEqualToString:@"diagnostics"]) {
        [self.navigationController pushViewController:[PMDiagnosticsViewController new] animated:YES];
    } else if ([route hasPrefix:@"premium:"]) {
        SEL selector = NSSelectorFromString(@"applyPremiumPreset:");
        if ([self respondsToSelector:selector]) {
            NSString *preset = [route substringFromIndex:[@"premium:" length]];
            ((void (*)(id, SEL, id))objc_msgSend)(self, selector, preset);
        }
    } else if ([route hasPrefix:@"admin:"]) {
        SEL selector = NSSelectorFromString(@"applyAdminPreset:");
        if ([self respondsToSelector:selector]) {
            NSString *preset = [route substringFromIndex:[@"admin:" length]];
            ((void (*)(id, SEL, id))objc_msgSend)(self, selector, preset);
        }
    } else if ([route isEqualToString:@"clean-cache"]) {
        SEL selector = NSSelectorFromString(@"confirmSafeClean");
        if ([self respondsToSelector:selector]) ((void (*)(id, SEL))objc_msgSend)(self, selector);
    } else if ([route isEqualToString:@"chip"]) {
        [self.navigationController pushViewController:[PMChipInfoViewController new] animated:YES];
    } else if ([route isEqualToString:@"info"]) {
        if ([self pm_selectRootTabAtIndex:2]) return;
        [self.navigationController pushViewController:[PMInfoViewController new] animated:YES];
    } else if ([route isEqualToString:@"profile"] && sender.bundleID.length) {
        NSDictionary *existingProfile = PMReadProfile(sender.bundleID);
        if (existingProfile.count == 0) {
            NSDictionary *seed = @{ @"AppName": sender.appName.length ? sender.appName : sender.bundleID,
                                    @"Enabled": @NO, @"RefreshMode": @(-2), @"FPSMode": @(-2),
                                    @"CustomRefreshRate": @60, @"CustomFPS": @60 };
            if (!PMWriteProfile(sender.bundleID, seed)) {
                [self showWriteFailure];
                return;
            }
        }
        [self.navigationController pushViewController:[[PMAppProfileViewController alloc] initWithBundleID:sender.bundleID] animated:YES];
    }
}

- (void)addRouteRowWithTitle:(NSString *)title subtitle:(NSString *)subtitle route:(NSString *)route symbol:(NSString *)symbol toStack:(UIStackView *)stack
{
    PMRouteButton *button = [PMRouteButton buttonWithType:UIButtonTypeSystem];
    PMStyleButton(button, @"");
    button.route = route;
    button.accessibilityLabel = title;
    button.accessibilityHint = [NSString stringWithFormat:@"Mở %@", title];
    button.isAccessibilityElement = YES;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.backgroundColor = UIColor.clearColor;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentFill;
    UIStackView *row = [[UIStackView alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 12;
    // Decorative row content must not intercept touches intended for the card button.
    row.userInteractionEnabled = NO;
    UIImageView *image = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
    image.translatesAutoresizingMaskIntoConstraints = NO;
    image.tintColor = PMAccentColor();
    image.contentMode = UIViewContentModeScaleAspectFit;
    [image.widthAnchor constraintEqualToConstant:27].active = YES;
    [image.heightAnchor constraintEqualToConstant:27].active = YES;
    [row addArrangedSubview:image];
    UIStackView *texts = [[UIStackView alloc] initWithFrame:CGRectZero];
    texts.axis = UILayoutConstraintAxisVertical;
    texts.spacing = 3;
    [texts addArrangedSubview:PMLabel(title, 14, UIFontWeightSemibold, PMPrimaryTextColor())];
    [texts addArrangedSubview:PMLabel(subtitle, 11, UIFontWeightRegular, PMMutedColor())];
    [row addArrangedSubview:texts];
    [texts setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    UILabel *arrow = PMLabel(@"›", 26, UIFontWeightRegular, PMMutedColor());
    [row addArrangedSubview:arrow];
    [button addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.topAnchor constraintEqualToAnchor:button.topAnchor constant:8],
        [row.bottomAnchor constraintEqualToAnchor:button.bottomAnchor constant:-8],
        [row.leadingAnchor constraintEqualToAnchor:button.leadingAnchor constant:14],
        [row.trailingAnchor constraintEqualToAnchor:button.trailingAnchor constant:-14]
    ]];
    [button addTarget:self action:@selector(routeTapped:) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:button];
    // Full-width cards with a generous hit target work across the whole row.
    [button.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:82].active = YES;
}

@end

@interface PMControlViewController () <UIScrollViewDelegate>
@property (nonatomic) BOOL dashboardBuilt;
@property (nonatomic) BOOL dashboardRecoveryMode;
@property (nonatomic) BOOL dashboardBuildScheduled;
@property (nonatomic) BOOL dashboardScrollActive;
@property (nonatomic) BOOL serverRelaunchGateScheduled;
@property (nonatomic) BOOL serverRelaunchGateHandled;
@property (nonatomic, strong) UIStackView *dashboardColumns;
@property (nonatomic, strong) NSLayoutConstraint *dashboardTelemetryWidthConstraint;
@property (nonatomic, strong) UILabel *dashboardClockLabel;
@property (nonatomic, strong) UILabel *dashboardFPSValueLabel;
@property (nonatomic, strong) UILabel *dashboardHzValueLabel;
@property (nonatomic, strong) UILabel *dashboardCPUValueLabel;
@property (nonatomic, strong) UILabel *dashboardThermalLabel;
@property (nonatomic, strong) UILabel *dashboardProtectionLabel;
@property (nonatomic, strong) PMTelemetryWaveformView *dashboardWaveform;
@property (nonatomic, strong) NSTimer *dashboardMetricsTimer;
@property (nonatomic) BOOL dashboardCPUSamplePending;
@property (nonatomic) CGFloat dashboardLastCPUValue;
@property (nonatomic) BOOL dashboardChangedBatteryMonitoring;
@property (nonatomic) BOOL serverPremiumActive;
@property (nonatomic) BOOL serverAdminActive;
@property (nonatomic, copy) NSArray<UIButton *> *serverModeButtons;
- (void)serverModeButtonTapped:(UIButton *)sender;
- (void)handleServerModeSelection:(NSInteger)requestedMode;
- (void)updateServerModeButtonsForMode:(NSInteger)mode;
- (void)applyPremiumPreset:(NSString *)preset;
- (void)applyAdminPreset:(NSString *)preset;
- (void)premiumApplicationDidEnterBackground:(NSNotification *)note;
- (void)premiumApplicationDidBecomeActive:(NSNotification *)note;
- (NSTimeInterval)dashboardTelemetryInterval;
- (void)prepareServerProfilesForLaunch;
- (void)refreshActiveServerRuntime;
- (void)scheduleServerRelaunchPasswordGate;
- (void)presentServerRelaunchPasswordGate;
- (BOOL)applyServerRelaunchMode:(NSInteger)mode;
- (void)downgradeProtectedServersFromRelaunchGate;
- (void)pm_presentAlertTitle:(NSString *)title message:(NSString *)message;
- (void)pm_setDashboardScrolling:(BOOL)scrolling;
- (void)pm_updateNeonShadowPaths;
- (void)pm_applyShadowPathsInView:(UIView *)view depth:(NSInteger)depth;
@end

void PMInstallAppLocalization(void)
{
    PMRefreshUIOptions();
    PMInstallLocalizationHooks();
}

@implementation PMControlViewController

// Keep authenticated state across UI-root rebuilds. Auto-restore applies only
// while the saved authorization matches the current tweak/process identity.
- (BOOL)serverPremiumActive
{
    if (!PMPremiumAuthorizationMatchesCurrentInstall()) return NO;
    return PMServerPremiumSessionActive || PMShouldAutoActivatePremium();
}

- (void)setServerPremiumActive:(BOOL)active
{
    PMServerPremiumSessionActive = active;
}

- (BOOL)serverAdminActive
{
    if (!PMAdminAuthorizationMatchesCurrentInstall()) return NO;
    return PMServerAdminSessionActive || PMShouldAutoActivateAdmin();
}

- (void)setServerAdminActive:(BOOL)active
{
    PMServerAdminSessionActive = active;
    if (active) PMServerPremiumSessionActive = YES;
}

- (BOOL)pm_isAdminServerActive
{
    return self.serverAdminActive;
}

- (UIView *)metricTileWithTitle:(NSString *)title valueLabel:(UILabel * __strong *)valueLabel
{
    UIView *tile = [UIView new];
    tile.translatesAutoresizingMaskIntoConstraints = NO;
    tile.backgroundColor = PMCardAltColor();
    tile.layer.cornerRadius = 18.0;
    tile.layer.borderWidth = 1.0;
    tile.layer.borderColor = PMBorderColor().CGColor;

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentLeading;
    stack.spacing = 6.0;
    UILabel *caption = PMLabel(title, 11, UIFontWeightMedium, PMMutedColor());
    caption.numberOfLines = 2;
    UILabel *value = PMLabel(@"Đang đo…", 19, UIFontWeightBold, PMPrimaryTextColor());
    value.numberOfLines = 1;
    value.adjustsFontSizeToFitWidth = YES;
    value.minimumScaleFactor = 0.65;
    [stack addArrangedSubview:caption];
    [stack addArrangedSubview:value];
    [tile addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:tile.topAnchor constant:11.0],
        [stack.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor constant:11.0],
        [stack.trailingAnchor constraintEqualToAnchor:tile.trailingAnchor constant:-11.0],
        [stack.bottomAnchor constraintEqualToAnchor:tile.bottomAnchor constant:-11.0],
        [tile.heightAnchor constraintGreaterThanOrEqualToConstant:70.0]
    ]];
    if (valueLabel) *valueLabel = value;
    return tile;
}

- (PMRouteButton *)dashboardNavigationCardWithTitle:(NSString *)title
                                              subtitle:(NSString *)subtitle
                                                  route:(NSString *)route
                                                 symbol:(NSString *)symbol
{
    PMRouteButton *button = [PMRouteButton buttonWithType:UIButtonTypeCustom];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.route = route;
    button.backgroundColor = PMCardColor();
    button.layer.cornerRadius = 20.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = PMBorderColor().CGColor;
    button.accessibilityLabel = title;
    button.accessibilityHint = [NSString stringWithFormat:@"Mở %@", title];
    [button addTarget:self action:@selector(routeTapped:) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *row = [[UIStackView alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 13.0;
    row.userInteractionEnabled = NO;

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = PMAccentColor();
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [icon.widthAnchor constraintEqualToConstant:27.0].active = YES;
    [icon.heightAnchor constraintEqualToConstant:27.0].active = YES;
    [row addArrangedSubview:icon];

    UIStackView *textStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 3.0;
    textStack.userInteractionEnabled = NO;
    UILabel *heading = PMLabel(title, 14, UIFontWeightSemibold, PMPrimaryTextColor());
    heading.numberOfLines = 2;
    UILabel *detail = PMLabel(subtitle ?: @"", 11, UIFontWeightRegular, PMMutedColor());
    detail.numberOfLines = 2;
    [textStack addArrangedSubview:heading];
    [textStack addArrangedSubview:detail];
    [row addArrangedSubview:textStack];
    [textStack setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    UILabel *chevron = PMLabel(@"›", 27, UIFontWeightRegular, PMMutedColor());
    [row addArrangedSubview:chevron];
    [button addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.topAnchor constraintEqualToAnchor:button.topAnchor constant:11.0],
        [row.bottomAnchor constraintEqualToAnchor:button.bottomAnchor constant:-11.0],
        [row.leadingAnchor constraintEqualToAnchor:button.leadingAnchor constant:13.0],
        [row.trailingAnchor constraintEqualToAnchor:button.trailingAnchor constant:-12.0],
        [button.heightAnchor constraintGreaterThanOrEqualToConstant:76.0]
    ]];
    return button;
}

- (PMRouteButton *)dashboardMetricTileWithTitle:(NSString *)title
                                           symbol:(NSString *)symbol
                                            route:(NSString *)route
                                      primaryText:(NSString *)primaryText
                                    secondaryText:(NSString *)secondaryText
                                      primaryLabel:(UILabel * __strong *)primaryLabel
                                    secondaryLabel:(UILabel * __strong *)secondaryLabel
{
    PMRouteButton *button = [PMRouteButton buttonWithType:UIButtonTypeCustom];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.route = route;
    button.backgroundColor = PMCardColor();
    button.layer.cornerRadius = 20.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = PMBorderColor().CGColor;
    button.accessibilityLabel = title;
    button.accessibilityHint = [NSString stringWithFormat:@"Mở %@", title];
    [button addTarget:self action:@selector(routeTapped:) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *row = [[UIStackView alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 10.0;
    row.userInteractionEnabled = NO;

    UIImageView *image = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
    image.translatesAutoresizingMaskIntoConstraints = NO;
    image.tintColor = PMAccentColor();
    image.contentMode = UIViewContentModeScaleAspectFit;
    [image.widthAnchor constraintEqualToConstant:25.0].active = YES;
    [image.heightAnchor constraintEqualToConstant:25.0].active = YES;
    [row addArrangedSubview:image];

    UIStackView *textStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.alignment = UIStackViewAlignmentLeading;
    textStack.spacing = 4.0;
    textStack.userInteractionEnabled = NO;

    UILabel *heading = PMLabel(title, 12, UIFontWeightSemibold, PMPrimaryTextColor());
    heading.numberOfLines = 2;
    UILabel *primary = PMLabel(primaryText ?: @"—", 15, UIFontWeightBold, PMPrimaryTextColor());
    primary.numberOfLines = 1;
    primary.adjustsFontSizeToFitWidth = YES;
    primary.minimumScaleFactor = 0.72;
    UILabel *secondary = PMLabel(secondaryText ?: @"", 10, UIFontWeightRegular, PMMutedColor());
    secondary.numberOfLines = 2;

    [textStack addArrangedSubview:heading];
    [textStack addArrangedSubview:primary];
    [textStack addArrangedSubview:secondary];
    [row addArrangedSubview:textStack];
    [textStack setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [textStack setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [button addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.topAnchor constraintEqualToAnchor:button.topAnchor constant:10.0],
        [row.bottomAnchor constraintEqualToAnchor:button.bottomAnchor constant:-10.0],
        [row.leadingAnchor constraintEqualToAnchor:button.leadingAnchor constant:11.0],
        [row.trailingAnchor constraintEqualToAnchor:button.trailingAnchor constant:-10.0],
        [button.heightAnchor constraintGreaterThanOrEqualToConstant:106.0]
    ]];

    if (primaryLabel) *primaryLabel = primary;
    if (secondaryLabel) *secondaryLabel = secondary;
    return button;
}

- (PMRouteButton *)dashboardSettingRowWithTitle:(NSString *)title
                                            subtitle:(NSString *)subtitle
                                               value:(NSString *)value
                                              symbol:(NSString *)symbol
                                               route:(NSString *)route
{
    PMRouteButton *button = [PMRouteButton buttonWithType:UIButtonTypeCustom];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.route = route;
    button.backgroundColor = PMCardAltColor();
    PMApplyNeonSurface(button, 17.0);
    button.accessibilityLabel = title;
    button.accessibilityHint = [NSString stringWithFormat:@"Mở %@", title];

    UIStackView *row = [[UIStackView alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 10.0;
    row.userInteractionEnabled = NO;

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = PMAccentColor();
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.layer.shadowColor = PMAccentColor().CGColor;
    icon.layer.shadowOpacity = PMLightThemeSelected ? 0.0f : 0.45f;
    icon.layer.shadowRadius = 8.0f;
    icon.layer.shadowOffset = CGSizeZero;
    [NSLayoutConstraint activateConstraints:@[
        [icon.widthAnchor constraintEqualToConstant:27.0],
        [icon.heightAnchor constraintEqualToConstant:27.0]
    ]];
    [row addArrangedSubview:icon];

    UIStackView *textStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 3.0;
    textStack.userInteractionEnabled = NO;
    UILabel *heading = PMLabel(title, 14.0, UIFontWeightSemibold, PMPrimaryTextColor());
    heading.numberOfLines = 2;
    UILabel *detail = PMLabel(subtitle ?: @"", 10.5, UIFontWeightRegular, PMMutedColor());
    detail.numberOfLines = 2;
    [textStack addArrangedSubview:heading];
    [textStack addArrangedSubview:detail];
    [row addArrangedSubview:textStack];
    [textStack setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [textStack setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    UILabel *valuePill = PMLabel(value ?: @"Auto", 11.0, UIFontWeightSemibold, PMPrimaryTextColor());
    valuePill.textAlignment = NSTextAlignmentCenter;
    valuePill.backgroundColor = PMCardColor();
    valuePill.layer.cornerRadius = 13.0;
    valuePill.clipsToBounds = YES;
    [NSLayoutConstraint activateConstraints:@[
        [valuePill.widthAnchor constraintGreaterThanOrEqualToConstant:68.0],
        [valuePill.heightAnchor constraintEqualToConstant:34.0]
    ]];
    [row addArrangedSubview:valuePill];
    UILabel *chevron = PMLabel(@"›", 25.0, UIFontWeightRegular, PMMutedColor());
    [row addArrangedSubview:chevron];

    [button addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.topAnchor constraintEqualToAnchor:button.topAnchor constant:10.0],
        [row.bottomAnchor constraintEqualToAnchor:button.bottomAnchor constant:-10.0],
        [row.leadingAnchor constraintEqualToAnchor:button.leadingAnchor constant:12.0],
        [row.trailingAnchor constraintEqualToAnchor:button.trailingAnchor constant:-10.0],
        [button.heightAnchor constraintGreaterThanOrEqualToConstant:72.0]
    ]];
    [button addTarget:self action:@selector(routeTapped:) forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIView *)dashboardTelemetryPanelWithDomain:(NSDictionary *)domain
{
    UIView *card = [UIView new];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = PMCardColor();
    PMApplyNeonSurface(card, 18.0);

    UIStackView *inside = [[UIStackView alloc] initWithFrame:CGRectZero];
    inside.translatesAutoresizingMaskIntoConstraints = NO;
    inside.axis = UILayoutConstraintAxisVertical;
    inside.spacing = 10.0;
    [card addSubview:inside];
    [NSLayoutConstraint activateConstraints:@[
        [inside.topAnchor constraintEqualToAnchor:card.topAnchor constant:13.0],
        [inside.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12.0],
        [inside.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12.0],
        [inside.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-13.0]
    ]];

    UIStackView *clockRow = [[UIStackView alloc] initWithFrame:CGRectZero];
    clockRow.axis = UILayoutConstraintAxisHorizontal;
    clockRow.alignment = UIStackViewAlignmentCenter;
    clockRow.spacing = 5.0;
    [clockRow addArrangedSubview:PMLabel(@"GIỜ HỆ THỐNG", 9.0, UIFontWeightBold, PMAccentColor())];
    UILabel *clock = PMLabel(@"--:--:--", 11.0, UIFontWeightBold, PMRGB(64, 224, 190));
    clock.textAlignment = NSTextAlignmentRight;
    clock.font = [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightBold];
    self.dashboardClockLabel = clock;
    [clockRow addArrangedSubview:[[UIView alloc] initWithFrame:CGRectZero]];
    [clockRow addArrangedSubview:clock];
    [inside addArrangedSubview:clockRow];

    [inside addArrangedSubview:PMLabel(@"// THEO DÕI PHẦN CỨNG THỰC TẾ", 9.0, UIFontWeightBold, PMAccentColor())];
    PMTelemetryWaveformView *waveform = [[PMTelemetryWaveformView alloc] initWithFrame:CGRectZero];
    waveform.translatesAutoresizingMaskIntoConstraints = NO;
    waveform.layer.cornerRadius = 8.0;
    waveform.layer.borderWidth = 1.0;
    waveform.layer.borderColor = PMBorderColor().CGColor;
    waveform.clipsToBounds = YES;
    [waveform.heightAnchor constraintEqualToConstant:112.0].active = YES;
    self.dashboardWaveform = waveform;
    [inside addArrangedSubview:waveform];

    UIStackView *metrics = [[UIStackView alloc] initWithFrame:CGRectZero];
    metrics.axis = UILayoutConstraintAxisHorizontal;
    metrics.alignment = UIStackViewAlignmentFill;
    metrics.distribution = UIStackViewDistributionFillEqually;
    metrics.spacing = 7.0;
    NSArray<NSString *> *titles = @[@"FPS CHỌN", @"HZ CHỌN", @"CPU LOAD"];
    NSMutableArray<UILabel *> *valueLabels = [NSMutableArray arrayWithCapacity:3];
    NSInteger selectedFPS = PMDashboardRateValue(domain, @"FPSMode", @"CustomFPS");
    NSInteger selectedHz = PMDashboardRateValue(domain, @"RefreshMode", @"CustomRefreshRate");
    NSArray<NSString *> *values = @[
        (selectedFPS > 0 ? [NSString stringWithFormat:@"%ld", (long)selectedFPS] : @"AUTO"),
        (selectedHz > 0 ? [NSString stringWithFormat:@"%ld", (long)selectedHz] : @"AUTO"),
        @"Đo…"
    ];
    for (NSUInteger index = 0; index < titles.count; index++) {
        // Three visually separate metric cards, arranged in one horizontal row.
        UIView *metricCard = [UIView new];
        metricCard.translatesAutoresizingMaskIntoConstraints = NO;
        metricCard.backgroundColor = PMCardAltColor();
        metricCard.layer.cornerRadius = 10.0;
        metricCard.layer.borderWidth = 1.0;
        metricCard.layer.borderColor = PMBorderColor().CGColor;
        metricCard.clipsToBounds = YES;

        UIStackView *cell = [[UIStackView alloc] initWithFrame:CGRectZero];
        cell.translatesAutoresizingMaskIntoConstraints = NO;
        cell.axis = UILayoutConstraintAxisVertical;
        cell.alignment = UIStackViewAlignmentCenter;
        cell.spacing = 4.0;
        UILabel *caption = PMLabel(titles[index], 8.0, UIFontWeightBold, PMMutedColor());
        caption.textAlignment = NSTextAlignmentCenter;
        caption.adjustsFontSizeToFitWidth = YES;
        caption.minimumScaleFactor = 0.62;
        UILabel *value = PMLabel(values[index], 15.0, UIFontWeightBold, PMRGB(64, 224, 190));
        value.textAlignment = NSTextAlignmentCenter;
        value.adjustsFontSizeToFitWidth = YES;
        value.minimumScaleFactor = 0.65;
        [cell addArrangedSubview:caption];
        [cell addArrangedSubview:value];
        [metricCard addSubview:cell];
        [NSLayoutConstraint activateConstraints:@[
            [cell.topAnchor constraintEqualToAnchor:metricCard.topAnchor constant:9.0],
            [cell.bottomAnchor constraintEqualToAnchor:metricCard.bottomAnchor constant:-9.0],
            [cell.leadingAnchor constraintEqualToAnchor:metricCard.leadingAnchor constant:4.0],
            [cell.trailingAnchor constraintEqualToAnchor:metricCard.trailingAnchor constant:-4.0]
        ]];
        [metrics addArrangedSubview:metricCard];
        [valueLabels addObject:value];
    }
    self.dashboardFPSValueLabel = valueLabels.count > 0 ? valueLabels[0] : nil;
    self.dashboardHzValueLabel = valueLabels.count > 1 ? valueLabels[1] : nil;
    self.dashboardCPUValueLabel = valueLabels.count > 2 ? valueLabels[2] : nil;
    [inside addArrangedSubview:metrics];

    [inside addArrangedSubview:PMSeparator()];

    // Refresh-rate target slider (10–244 Hz).
    UIStackView *hzSliderRow = [[UIStackView alloc] initWithFrame:CGRectZero];
    hzSliderRow.axis = UILayoutConstraintAxisVertical;
    hzSliderRow.spacing = 6.0;
    UIStackView *hzTitleRow = [[UIStackView alloc] initWithFrame:CGRectZero];
    hzTitleRow.axis = UILayoutConstraintAxisHorizontal;
    UILabel *hzHeading = PMLabel(@"Tần số quét mục tiêu", 12.0, UIFontWeightSemibold, PMPrimaryTextColor());
    UILabel *hzValue = PMLabel(PMSelectedRateText(domain, @"RefreshMode", @"CustomRefreshRate", @"Hz"), 12.0, UIFontWeightBold, PMAccentColor());
    hzValue.tag = 7282;
    hzValue.textAlignment = NSTextAlignmentRight;
    [hzTitleRow addArrangedSubview:hzHeading];
    [hzTitleRow addArrangedSubview:[[UIView alloc] initWithFrame:CGRectZero]];
    [hzTitleRow addArrangedSubview:hzValue];
    UISlider *hzSlider = [UISlider new];
    hzSlider.tag = 7284;
    hzSlider.minimumValue = 10.0f;
    hzSlider.maximumValue = 244.0f;
    NSInteger initialHz = PMDashboardRateValue(domain, @"RefreshMode", @"CustomRefreshRate");
    hzSlider.value = initialHz > 0 ? (float)initialHz : 60.0f;
    hzSlider.minimumTrackTintColor = PMAccentColor();
    [hzSlider addTarget:self action:@selector(dashboardRateSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [hzSlider addTarget:self action:@selector(dashboardRateSliderCommitted:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [hzSliderRow addArrangedSubview:hzTitleRow];
    [hzSliderRow addArrangedSubview:hzSlider];
    [inside addArrangedSubview:hzSliderRow];

    UIStackView *fpsSliderRow = [[UIStackView alloc] initWithFrame:CGRectZero];
    fpsSliderRow.axis = UILayoutConstraintAxisVertical;
    fpsSliderRow.spacing = 6.0;
    UIStackView *fpsTitleRow = [[UIStackView alloc] initWithFrame:CGRectZero];
    fpsTitleRow.axis = UILayoutConstraintAxisHorizontal;
    UILabel *fpsHeading = PMLabel(@"FPS mục tiêu", 12.0, UIFontWeightSemibold, PMPrimaryTextColor());
    UILabel *fpsValue = PMLabel(PMSelectedRateText(domain, @"FPSMode", @"CustomFPS", @"FPS"), 12.0, UIFontWeightBold, PMAccentColor());
    fpsValue.tag = 7283;
    fpsValue.textAlignment = NSTextAlignmentRight;
    [fpsTitleRow addArrangedSubview:fpsHeading];
    [fpsTitleRow addArrangedSubview:[[UIView alloc] initWithFrame:CGRectZero]];
    [fpsTitleRow addArrangedSubview:fpsValue];
    UISlider *fpsSlider = [UISlider new];
    fpsSlider.tag = 7285;
    fpsSlider.minimumValue = 10.0f;
    fpsSlider.maximumValue = 244.0f;
    NSInteger initialFPS = PMDashboardRateValue(domain, @"FPSMode", @"CustomFPS");
    fpsSlider.value = initialFPS > 0 ? (float)initialFPS : 60.0f;
    fpsSlider.minimumTrackTintColor = PMAccentColor();
    [fpsSlider addTarget:self action:@selector(dashboardRateSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [fpsSlider addTarget:self action:@selector(dashboardRateSliderCommitted:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [fpsSliderRow addArrangedSubview:fpsTitleRow];
    [fpsSliderRow addArrangedSubview:fpsSlider];
    [inside addArrangedSubview:fpsSliderRow];

    UILabel *thermal = PMLabel([NSString stringWithFormat:@"NHIỆT ĐỘ HỆ THỐNG: %@", PMThermalStateLabel()], 9.0, UIFontWeightSemibold, PMMutedColor());
    thermal.numberOfLines = 2;
    self.dashboardThermalLabel = thermal;
    [inside addArrangedSubview:thermal];
    UILabel *protection = PMLabel(@"BẢO VỆ TỔNG QUAN: ĐANG ĐỌC…", 9.0, UIFontWeightBold, PMRGB(49, 221, 151));
    protection.numberOfLines = 2;
    self.dashboardProtectionLabel = protection;
    [inside addArrangedSubview:protection];
    return card;
}

- (void)refreshDashboardTelemetry:(NSTimer *)timer
{
    (void)timer;
    if (!self.isViewLoaded || !self.view.window || !self.dashboardWaveform) return;
    // A live drag must never wait behind CPU sampling, date formatting or a
    // waveform redraw. The timer is slowed while scrolling and the heavy work is
    // skipped, then resumes at the tier interval after deceleration ends.
    if (self.dashboardScrollActive) return;

    static NSDateFormatter *clockFormatter;
    static dispatch_once_t clockOnceToken;
    dispatch_once(&clockOnceToken, ^{
        clockFormatter = [NSDateFormatter new];
        clockFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        clockFormatter.dateFormat = @"HH:mm:ss.SS";
    });
    self.dashboardClockLabel.text = [clockFormatter stringFromDate:[NSDate date]];

    // ADMIN backs off its own telemetry work as thermal pressure rises. The
    // dashboard remains visible, but CPU sampling is skipped at Serious/Critical.
    NSProcessInfo *telemetryProcessInfo = NSProcessInfo.processInfo;
    NSProcessInfoThermalState telemetryThermal = NSProcessInfoThermalStateNominal;
    if (@available(iOS 11.0, *)) telemetryThermal = telemetryProcessInfo.thermalState;
    NSTimeInterval desiredTelemetryInterval = [self dashboardTelemetryInterval];
    if (self.dashboardMetricsTimer && fabs(self.dashboardMetricsTimer.timeInterval - desiredTelemetryInterval) > 0.05) {
        [self.dashboardMetricsTimer invalidate];
        self.dashboardMetricsTimer = [NSTimer timerWithTimeInterval:desiredTelemetryInterval target:self
            selector:@selector(refreshDashboardTelemetry:) userInfo:nil repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:self.dashboardMetricsTimer forMode:NSRunLoopCommonModes];
    }
    BOOL skipCPUSampleForHeat = telemetryProcessInfo.isLowPowerModeEnabled ||
        telemetryThermal == NSProcessInfoThermalStateSerious ||
        telemetryThermal == NSProcessInfoThermalStateCritical;

    // Mach CPU statistics can take longer than a frame on older devices. Keep
    // that query on a serial utility queue and update all UIKit objects on main.
    if (skipCPUSampleForHeat) {
        if (self.dashboardCPUValueLabel) self.dashboardCPUValueLabel.text = @"GIẢM TẢI";
    } else if (!self.dashboardCPUSamplePending) {
        self.dashboardCPUSamplePending = YES;
        __weak typeof(self) weakSelf = self;
        dispatch_async(PMSystemCPUStatsQueue(), ^{
            double sampledCPU = PMSystemCPUUsagePercent();
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (!self) return;
                self.dashboardCPUSamplePending = NO;
                if (!self.isViewLoaded || !self.view.window || !self.dashboardWaveform) return;
                NSProcessInfo *currentProcessInfo = NSProcessInfo.processInfo;
                BOOL mustBackOff = currentProcessInfo.isLowPowerModeEnabled;
                if (@available(iOS 11.0, *)) {
                    NSProcessInfoThermalState currentThermal = currentProcessInfo.thermalState;
                    mustBackOff = mustBackOff || currentThermal == NSProcessInfoThermalStateSerious ||
                        currentThermal == NSProcessInfoThermalStateCritical;
                }
                if (mustBackOff) {
                    if (self.dashboardCPUValueLabel) self.dashboardCPUValueLabel.text = @"GIẢM TẢI";
                    return;
                }
                if (sampledCPU >= 0.0) self.dashboardLastCPUValue = (CGFloat)sampledCPU;
                if (self.dashboardCPUValueLabel) {
                    self.dashboardCPUValueLabel.text = sampledCPU >= 0.0 ? [NSString stringWithFormat:@"%.0f%%", sampledCPU] :
                        (sampledCPU <= -2.0 ? @"N/A" : @"Đo…");
                }
                if (self.dashboardWaveform) [self.dashboardWaveform appendValue:self.dashboardLastCPUValue];
            });
        });
    }
    if (self.dashboardThermalLabel)
        self.dashboardThermalLabel.text = [NSString stringWithFormat:@"NHIỆT ĐỘ HỆ THỐNG: %@", PMThermalStateLabel()];

    NSDictionary *domain = PMReadDomain() ?: @{};
    BOOL protectionEnabled = [domain[@"AppStabilityFix"] respondsToSelector:@selector(boolValue)]
        ? [domain[@"AppStabilityFix"] boolValue] : YES;
    if (self.dashboardProtectionLabel) {
        self.dashboardProtectionLabel.text = protectionEnabled
            ? @"BẢO VỆ TỔNG QUAN: ĐÃ KÍCH HOẠT"
            : @"BẢO VỆ TỔNG QUAN: CHƯA KÍCH HOẠT";
        self.dashboardProtectionLabel.textColor = protectionEnabled ? PMRGB(49, 221, 151) : PMMutedColor();
    }
    NSInteger selectedFPS = PMDashboardRateValue(domain, @"FPSMode", @"CustomFPS");
    NSInteger selectedHz = PMDashboardRateValue(domain, @"RefreshMode", @"CustomRefreshRate");
    if (self.dashboardFPSValueLabel)
        self.dashboardFPSValueLabel.text = selectedFPS > 0 ? [NSString stringWithFormat:@"%ld", (long)selectedFPS] : @"AUTO";
    if (self.dashboardHzValueLabel)
        self.dashboardHzValueLabel.text = selectedHz > 0 ? [NSString stringWithFormat:@"%ld", (long)selectedHz] : @"AUTO";
}

- (void)prepareServerProfilesForLaunch
{
    // Restore only a tier whose authorization still matches this tweak install.
    // An absent/rotated install ID always falls back to FREE without losing the
    // other stored profile snapshots.
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults boolForKey:PMAdminSelectedModeKey] && !PMAdminAuthorizationMatchesCurrentInstall())
        [defaults setBool:NO forKey:PMAdminSelectedModeKey];
    if ([defaults boolForKey:PMPremiumSelectedModeKey] && !PMPremiumAuthorizationMatchesCurrentInstall())
        [defaults setBool:NO forKey:PMPremiumSelectedModeKey];
    [defaults synchronize];

    NSDictionary *domain = PMReadDomain() ?: @{};
    NSInteger storedMode = [domain[@"ActiveServerMode"] respondsToSelector:@selector(integerValue)]
        ? MIN(MAX([domain[@"ActiveServerMode"] integerValue], 0), 2) : 0;

    // Resume the tier that was running when the process ended, but only while the
    // saved authorization still matches this install. The tweak keeps reading the
    // shared ActiveServerMode, so the selected server continues operating across a
    // relaunch instead of silently dropping to FREE.
    NSInteger restoredMode = 0;
    if (PMAdminAuthorizationMatchesCurrentInstall() &&
        (storedMode == 2 || (storedMode == 0 && [defaults boolForKey:PMAdminSelectedModeKey]))) {
        restoredMode = 2;
    } else if (PMPremiumAuthorizationMatchesCurrentInstall() &&
               (storedMode >= 1 || [defaults boolForKey:PMPremiumSelectedModeKey] ||
                [defaults boolForKey:PMAdminSelectedModeKey])) {
        restoredMode = 1;
    }

    self.serverPremiumActive = (restoredMode >= 1);
    self.serverAdminActive = (restoredMode == 2);
    if (restoredMode >= 1) {
        PMSetPremiumSelectedMode(YES);
        PMSetAdminSelectedMode(restoredMode == 2);
        PMRememberLastActiveServerMode(restoredMode);
    } else {
        PMServerPremiumSessionActive = NO;
        PMServerAdminSessionActive = NO;
    }

    NSDictionary *profiles = [domain[@"ServerProfiles"] isKindOfClass:[NSDictionary class]] ? domain[@"ServerProfiles"] : @{};
    if (storedMode != restoredMode || profiles.count != 3) {
        if (!PMWriteDomainChanges(@{@"ActiveServerMode": @(restoredMode)})) {
            NSLog(@"[ProMotionControl] Could not restore server profile; retaining safe FREE runtime.");
            self.serverPremiumActive = NO;
            self.serverAdminActive = NO;
            PMSetPremiumSelectedMode(NO);
            PMSetAdminSelectedMode(NO);
            PMWriteDomainChanges(@{@"ActiveServerMode": @0});
        }
    }
}

- (void)pm_refreshActiveServerRuntime
{
    [self refreshActiveServerRuntime];
}

// The relaunch gate runs once per process launch. It names the server that was
// used last, asks for that tier's own password and only then keeps that server
// running. A cancel, a wrong password or a failed write downgrades to FREE.
- (void)scheduleServerRelaunchPasswordGate
{
    if (![NSThread isMainThread]) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf scheduleServerRelaunchPasswordGate]; });
        return;
    }
    if (self.serverRelaunchGateScheduled || self.serverRelaunchGateHandled || !self.isViewLoaded) return;

    NSInteger gateMode = self.serverAdminActive ? 2 :
        (self.serverPremiumActive ? 1 : PMLastActiveProtectedServerMode());
    if (gateMode == 0) {
        self.serverRelaunchGateHandled = YES;
        return;
    }
    self.serverRelaunchGateScheduled = YES;
    __weak typeof(self) weakSelf = self;
    // The typing intro covers the window for three seconds on launch. Ask right
    // after it fades so the two screens never compete for the same touch surface.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.serverRelaunchGateScheduled = NO;
        [self presentServerRelaunchPasswordGate];
    });
}

- (void)presentServerRelaunchPasswordGate
{
    if (![NSThread isMainThread]) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf presentServerRelaunchPasswordGate]; });
        return;
    }
    if (self.serverRelaunchGateHandled) return;
    if (!self.isViewLoaded || !self.view.window) {
        [self scheduleServerRelaunchPasswordGate];
        return;
    }
    // Wait for a real foreground window and an unobstructed presenter.
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
        self.presentedViewController) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [weakSelf presentServerRelaunchPasswordGate]; });
        return;
    }

    NSInteger gateMode = self.serverAdminActive ? 2 :
        (self.serverPremiumActive ? 1 : PMLastActiveProtectedServerMode());
    if (gateMode == 0) {
        self.serverRelaunchGateHandled = YES;
        return;
    }

    NSString *lockoutMessage = nil;
    if (!PMProtectedAuthAttemptAllowed(gateMode, &lockoutMessage)) {
        self.serverRelaunchGateHandled = YES;
        UIAlertController *locked = [UIAlertController alertControllerWithTitle:@"Tạm khóa xác thực"
            message:lockoutMessage ?: @"Quá nhiều lần nhập sai. Vui lòng thử lại sau."
            preferredStyle:UIAlertControllerStyleAlert];
        [locked addAction:[UIAlertAction actionWithTitle:@"Đã hiểu" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:locked animated:YES completion:nil];
        return;
    }

    self.serverRelaunchGateHandled = YES;
    BOOL adminRequested = gateMode == 2;
    NSString *passwordName = adminRequested ? @"ADMIN" : @"PREMIUM";
    NSString *serverName = PMServerDisplayNameForMode(gateMode);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:
        [NSString stringWithFormat:@"Lần cuối bạn sử dụng %@", serverName]
        message:[NSString stringWithFormat:@"Vui lòng nhập mật khẩu %@ để tiếp tục chạy %@. Bỏ qua hoặc nhập sai sẽ quay về SERVER FREE; mật khẩu không được lưu lại.", passwordName, serverName]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = [NSString stringWithFormat:@"Mật khẩu %@", passwordName];
        field.secureTextEntry = YES;
        field.keyboardType = UIKeyboardTypeNumberPad;
        field.textContentType = UITextContentTypePassword;
    }];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Bỏ qua" style:UIAlertActionStyleCancel
                                            handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        if (self) [self downgradeProtectedServersFromRelaunchGate];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Xác nhận" style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        NSString *provided = alert.textFields.firstObject.text ?: @"";
        if (PMProtectedPasswordMatches(provided, adminRequested)) {
            PMClearProtectedAuthFailures(gateMode);
            if (adminRequested ? PMRememberAdminActivation() : PMRememberPremiumActivation()) {
                if ([self applyServerRelaunchMode:gateMode]) return;
            }
            [self downgradeProtectedServersFromRelaunchGate];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self pm_presentAlertTitle:@"Không thể khôi phục máy chủ"
                                   message:@"Thiết bị không lưu được trạng thái xác thực. SERVER FREE vẫn hoạt động."];
            });
            return;
        }
        PMRecordProtectedAuthFailure(gateMode);
        [self downgradeProtectedServersFromRelaunchGate];
        NSString *failureMessage = adminRequested
            ? @"Mật khẩu ADMIN không đúng. SERVER ADMIN chưa được khôi phục; SERVER FREE đang hoạt động."
            : @"Mật khẩu PREMIUM không đúng. SERVER PREMIUM chưa được khôi phục; SERVER FREE đang hoạt động.";
        dispatch_async(dispatch_get_main_queue(), ^{
            [self pm_presentAlertTitle:@"Không thể tiếp tục máy chủ" message:failureMessage];
        });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (BOOL)applyServerRelaunchMode:(NSInteger)mode
{
    if (mode != 1 && mode != 2) return NO;
    if (!PMWriteDomainChanges(@{@"ActiveServerMode": @(mode)})) return NO;
    PMSetPremiumSelectedMode(YES);
    PMSetAdminSelectedMode(mode == 2);
    self.serverPremiumActive = YES;
    self.serverAdminActive = (mode == 2);
    PMRememberLastActiveServerMode(mode);
    [self refreshActiveServerRuntime];
    [self updateServerModeButtonsForMode:mode];
    // The dashboard was built before the unlock, so refresh it once after the
    // alert closes instead of rebuilding synchronously under the alert.
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.dashboardBuilt = NO;
        [self buildDashboardSafely];
    });
    return YES;
}

- (void)downgradeProtectedServersFromRelaunchGate
{
    PMWriteDomainChanges(@{@"ActiveServerMode": @0});
    PMServerPremiumSessionActive = NO;
    PMServerAdminSessionActive = NO;
    PMSetPremiumSelectedMode(NO);
    PMSetAdminSelectedMode(NO);
    self.serverPremiumActive = NO;
    self.serverAdminActive = NO;
    [[PMInputAndDisplayBooster sharedBooster] deactivatePremiumOptimization];
    [self refreshActiveServerRuntime];
    [self updateServerModeButtonsForMode:0];
    self.dashboardBuilt = NO;
    [self buildDashboardSafely];
}

- (void)pm_presentAlertTitle:(NSString *)title message:(NSString *)message
{
    if (!self.view.window || self.presentedViewController) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)refreshActiveServerRuntime
{
    NSDictionary *options = PMReadDomain() ?: @{};
    // The master switch is authoritative for every tier. A selected server can
    // remain saved while OFF, but no auxiliary engine/render loop stays active.
    BOOL masterEnabled = [options[@"Enabled"] respondsToSelector:@selector(boolValue)] && [options[@"Enabled"] boolValue];
    if (!masterEnabled || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        [[PMInputAndDisplayBooster sharedBooster] deactivatePremiumOptimization];
        return;
    }
    if (self.serverAdminActive) {
        [[PMInputAndDisplayBooster sharedBooster] activateAdminOptimizationWithOptions:options];
    } else if (self.serverPremiumActive) {
        [[PMInputAndDisplayBooster sharedBooster] activatePremiumOptimizationWithOptions:options];
    } else {
        [[PMInputAndDisplayBooster sharedBooster] activateFreeOptimizationWithOptions:options];
    }
}

- (NSTimeInterval)dashboardTelemetryInterval
{
    NSProcessInfo *processInfo = NSProcessInfo.processInfo;
    NSProcessInfoThermalState thermal = NSProcessInfoThermalStateNominal;
    if (@available(iOS 11.0, *)) thermal = processInfo.thermalState;
    UIDeviceBatteryState batteryState = UIDevice.currentDevice.batteryState;
    BOOL charging = (batteryState == UIDeviceBatteryStateCharging || batteryState == UIDeviceBatteryStateFull);

    NSTimeInterval interval = 0.2; // FREE default telemetry cadence.
    NSDictionary *activeOptions = PMReadDomain() ?: @{};
    BOOL adminLoadShed = ![activeOptions[@"AdminDashboardLoadShedEnabled"] respondsToSelector:@selector(boolValue)] ||
        [activeOptions[@"AdminDashboardLoadShedEnabled"] boolValue];
    BOOL freeChargingGuard = [activeOptions[@"FreeChargingGuardEnabled"] respondsToSelector:@selector(boolValue)]
        ? [activeOptions[@"FreeChargingGuardEnabled"] boolValue]
        : ([activeOptions[@"ChargingOptimization"] respondsToSelector:@selector(boolValue)]
            ? [activeOptions[@"ChargingOptimization"] boolValue] : YES);
    BOOL premiumChargingGuard = ![activeOptions[@"PremiumChargingGuardEnabled"] respondsToSelector:@selector(boolValue)] ||
        [activeOptions[@"PremiumChargingGuardEnabled"] boolValue];
    BOOL adminChargingGuard = ![activeOptions[@"AdminChargingCooldownEnabled"] respondsToSelector:@selector(boolValue)] ||
        [activeOptions[@"AdminChargingCooldownEnabled"] boolValue];

    // Charger guards only slow down diagnostic/dashboard sampling. They never
    // lower the selected display Hz/FPS request sent to the runtime hooks.
    if (self.serverAdminActive && adminLoadShed) interval = (charging && adminChargingGuard) ? 1.0 : 0.8;
    else if (self.serverPremiumActive) interval = (charging && premiumChargingGuard) ? 0.4 : 0.31;
    else if (charging && freeChargingGuard) interval = 0.25;

    if (processInfo.isLowPowerModeEnabled || thermal == NSProcessInfoThermalStateSerious ||
        thermal == NSProcessInfoThermalStateCritical) return 1.5;
    if (thermal == NSProcessInfoThermalStateFair) {
        if (self.serverAdminActive) return 1.2;
        if (self.serverPremiumActive) return 0.6;
        return 0.4;
    }
    return interval;
}

- (void)startMetricsSampling
{
    [self stopMetricsSampling];
    if (!self.isViewLoaded || !self.view.window || !self.dashboardWaveform) return;
    UIDevice *device = UIDevice.currentDevice;
    if (!device.batteryMonitoringEnabled) {
        device.batteryMonitoringEnabled = YES;
        self.dashboardChangedBatteryMonitoring = YES;
    }
    NSTimeInterval telemetryInterval = [self dashboardTelemetryInterval];
    self.dashboardMetricsTimer = [NSTimer timerWithTimeInterval:telemetryInterval target:self
        selector:@selector(refreshDashboardTelemetry:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.dashboardMetricsTimer forMode:NSRunLoopCommonModes];
    [self refreshDashboardTelemetry:nil];
}

- (void)stopMetricsSampling
{
    [self.dashboardMetricsTimer invalidate];
    self.dashboardMetricsTimer = nil;
    if (self.dashboardChangedBatteryMonitoring) {
        UIDevice.currentDevice.batteryMonitoringEnabled = NO;
        self.dashboardChangedBatteryMonitoring = NO;
    }
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView
{
    (void)scrollView;
    [self pm_setDashboardScrolling:YES];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate
{
    (void)scrollView;
    if (!decelerate) [self pm_setDashboardScrolling:NO];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView
{
    (void)scrollView;
    [self pm_setDashboardScrolling:NO];
}

- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView
{
    (void)scrollView;
    [self pm_setDashboardScrolling:NO];
}

- (void)pm_setDashboardScrolling:(BOOL)scrolling
{
    if (self.dashboardScrollActive == scrolling) return;
    self.dashboardScrollActive = scrolling;
    if (!self.dashboardMetricsTimer) return;
    NSTimeInterval interval = scrolling ? 1.0 : [self dashboardTelemetryInterval];
    if (fabs(self.dashboardMetricsTimer.timeInterval - interval) <= 0.05) return;
    [self.dashboardMetricsTimer invalidate];
    self.dashboardMetricsTimer = [NSTimer timerWithTimeInterval:interval target:self
        selector:@selector(refreshDashboardTelemetry:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.dashboardMetricsTimer forMode:NSRunLoopCommonModes];
}

- (void)pm_updateNeonShadowPaths
{
    [self pm_applyShadowPathsInView:self.contentStack depth:3];
}

- (void)pm_applyShadowPathsInView:(UIView *)view depth:(NSInteger)depth
{
    if (!view || depth < 0) return;
    CALayer *layer = view.layer;
    if (layer.shadowOpacity > 0.0f && layer.cornerRadius > 0.0 && !CGRectIsEmpty(view.bounds)) {
        // An explicit rounded path lets Core Animation draw the neon glow without
        // rasterising each card's whole contents on every scroll frame.
        layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:view.bounds
                                                          cornerRadius:layer.cornerRadius].CGPath;
    }
    for (UIView *subview in view.subviews) {
        [self pm_applyShadowPathsInView:subview depth:depth - 1];
    }
}

- (void)dashboardRateSliderChanged:(UISlider *)sender
{
    NSInteger value = MIN(MAX((NSInteger)lrintf(sender.value), 10), 244);
    NSInteger labelTag = (sender.tag == 7284) ? 7282 : 7283;
    UILabel *label = (UILabel *)[self.view viewWithTag:labelTag];
    if ([label isKindOfClass:[UILabel class]]) {
        label.text = [NSString stringWithFormat:@"%ld %@", (long)value, sender.tag == 7284 ? @"Hz" : @"FPS"];
    }
}

- (void)dashboardRateSliderCommitted:(UISlider *)sender
{
    NSInteger value = MIN(MAX((NSInteger)lrintf(sender.value), 10), 244);
    NSDictionary *changes = nil;
    if (sender.tag == 7284) {
        // Store the slider position as the custom Hz value so the custom chips
        // and the Hz label always read back the exact integer that was chosen.
        changes = @{
            @"RefreshMode": @(-1), @"CustomRefreshRate": @(value),
            @"RefreshRateEnabled": @YES, @"Enabled": @YES,
            @"FramePacing": @YES, @"AdvancedDisplayEnforcement": @YES,
            @"ExactRateEnforcement": @YES
        };
    } else {
        changes = @{
            @"FPSMode": @(-1), @"CustomFPS": @(value),
            @"FPSOverrideEnabled": @YES, @"Enabled": @YES,
            @"FramePacing": @YES, @"AdvancedDisplayEnforcement": @YES,
            @"ExactRateEnforcement": @YES
        };
    }
    if (!PMWriteDomainChanges(changes)) {
        [self showWriteFailure];
        return;
    }
    [self refreshActiveServerRuntime];
    self.dashboardBuilt = NO;
    [self buildDashboardSafely];
}

- (void)serverModeButtonTapped:(UIButton *)sender
{
    if (![NSThread isMainThread]) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (self) [self handleServerModeSelection:sender.tag];
        });
        return;
    }
    [self handleServerModeSelection:sender.tag];
}

- (void)updateServerModeButtonsForMode:(NSInteger)mode
{
    NSInteger selectedMode = MIN(MAX(mode, 0), 2);
    NSArray<UIButton *> *buttons = self.serverModeButtons;
    [buttons enumerateObjectsUsingBlock:^(UIButton *button, NSUInteger index, __unused BOOL *stop) {
        BOOL selected = ((NSInteger)index == selectedMode);
        button.selected = selected;
        button.backgroundColor = selected ? PMAccentColor() : PMCardAltColor();
        [button setTitleColor:PMPrimaryTextColor() forState:UIControlStateNormal];
        [button setTitleColor:PMPrimaryTextColor() forState:UIControlStateSelected];
        button.layer.borderColor = (selected ? PMAccentColor() : PMBorderColor()).CGColor;
        button.layer.borderWidth = selected ? 1.5 : 1.0;
        button.accessibilityTraits = selected ? UIAccessibilityTraitSelected : UIAccessibilityTraitButton;
        button.alpha = selected ? 1.0 : 0.92;
    }];
}

- (void)handleServerModeSelection:(NSInteger)requestedMode
{
    if (![NSThread isMainThread]) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (self) [self handleServerModeSelection:requestedMode];
        });
        return;
    }

    requestedMode = MIN(MAX(requestedMode, 0), 2); // 0 FREE, 1 PREMIUM, 2 ADMIN
    if (requestedMode == 0) {
        if (!PMWriteDomainChanges(@{@"ActiveServerMode": @0})) {
            [self showWriteFailure];
            return;
        }
        self.serverPremiumActive = NO;
        self.serverAdminActive = NO;
        PMSetPremiumSelectedMode(NO);
        PMSetAdminSelectedMode(NO);
        PMRememberLastActiveServerMode(0);
        [[PMInputAndDisplayBooster sharedBooster] deactivatePremiumOptimization];
        [self refreshActiveServerRuntime];
        [self updateServerModeButtonsForMode:0];
        self.dashboardBuilt = NO;
        [self stopMetricsSampling];
        [self buildDashboardSafely];
        return;
    }

    // Every explicit tap on PREMIUM or ADMIN requires the corresponding password.
    // The tweak runtime marker is not a prerequisite for showing the password
    // dialog or enabling app-local controls in the standalone control app.
    if (!PMWriteDomainChanges(@{@"ActiveServerMode": @0})) {
        [self showWriteFailure];
        return;
    }
    self.serverPremiumActive = NO;
    self.serverAdminActive = NO;
    PMSetPremiumSelectedMode(NO);
    PMSetAdminSelectedMode(NO);
    [[PMInputAndDisplayBooster sharedBooster] deactivatePremiumOptimization];
    [self refreshActiveServerRuntime];
    [self updateServerModeButtonsForMode:0];

    NSString *lockoutMessage = nil;
    if (!PMProtectedAuthAttemptAllowed(requestedMode, &lockoutMessage)) {
        UIAlertController *locked = [UIAlertController alertControllerWithTitle:@"Tạm khóa xác thực"
            message:lockoutMessage preferredStyle:UIAlertControllerStyleAlert];
        [locked addAction:[UIAlertAction actionWithTitle:@"Đã hiểu" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:locked animated:YES completion:nil];
        return;
    }

    NSString *unlockTitle = requestedMode == 2 ? @"Mở khóa SERVER ADMIN" : @"Mở khóa SERVER PREMIUM";
    NSString *unlockMessage = requestedMode == 2
        ? @"Nhập mật khẩu ADMIN riêng. Chỉ mật khẩu ADMIN đúng mới mở SERVER ADMIN; quyền PREMIUM không tự cấp quyền ADMIN."
        : @"Nhập mật khẩu PREMIUM. Chỉ mật khẩu PREMIUM đúng mới mở SERVER PREMIUM.";
    UIAlertController *passwordAlert = [UIAlertController alertControllerWithTitle:unlockTitle
        message:unlockMessage preferredStyle:UIAlertControllerStyleAlert];
    [passwordAlert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = requestedMode == 2 ? @"Mật khẩu ADMIN" : @"Mật khẩu Premium";
        field.secureTextEntry = YES;
        field.keyboardType = UIKeyboardTypeNumberPad;
        field.textContentType = UITextContentTypePassword;
    }];

    __weak typeof(self) weakSelf = self;
    [passwordAlert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.serverPremiumActive = NO;
        self.serverAdminActive = NO;
        PMSetPremiumSelectedMode(NO);
        PMSetAdminSelectedMode(NO);
        [[PMInputAndDisplayBooster sharedBooster] deactivatePremiumOptimization];
        [self refreshActiveServerRuntime];
        [self updateServerModeButtonsForMode:0];
    }]];

    [passwordAlert addAction:[UIAlertAction actionWithTitle:@"Xác nhận" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        NSString *provided = passwordAlert.textFields.firstObject.text ?: @"";
        BOOL adminRequested = requestedMode == 2;
        BOOL passwordMatches = PMProtectedPasswordMatches(provided, adminRequested);
        BOOL authorizationSaved = passwordMatches &&
            (adminRequested ? PMRememberAdminActivation() : PMRememberPremiumActivation());
        if (authorizationSaved) {
            authorizationSaved = PMWriteDomainChanges(@{@"ActiveServerMode": @(adminRequested ? 2 : 1)});
        }

        if (authorizationSaved) {
            PMClearProtectedAuthFailures(requestedMode);
            PMSetPremiumSelectedMode(YES);
            PMSetAdminSelectedMode(adminRequested);
            self.serverPremiumActive = YES;
            self.serverAdminActive = adminRequested;
            PMRememberLastActiveServerMode(adminRequested ? 2 : 1);
            [self refreshActiveServerRuntime];
            [self updateServerModeButtonsForMode:(adminRequested ? 2 : 1)];
            dispatch_async(dispatch_get_main_queue(), ^{
                void (^finishActivation)(void) = ^{
                    self.dashboardBuilt = NO;
                    [self stopMetricsSampling];
                    [self buildDashboardSafely];
                };
                if (self.presentedViewController == passwordAlert) {
                    [self dismissViewControllerAnimated:YES completion:finishActivation];
                } else {
                    finishActivation();
                }
            });
            return;
        }

        if (!passwordMatches) PMRecordProtectedAuthFailure(requestedMode);
        self.serverPremiumActive = NO;
        self.serverAdminActive = NO;
        PMSetPremiumSelectedMode(NO);
        PMSetAdminSelectedMode(NO);
        [[PMInputAndDisplayBooster sharedBooster] deactivatePremiumOptimization];
        [self refreshActiveServerRuntime];
        [self updateServerModeButtonsForMode:0];
        NSString *failureMessage = passwordMatches
            ? @"Không thể lưu trạng thái xác thực trong phiên này. SERVER FREE vẫn hoạt động."
            : (adminRequested
                ? @"Mật khẩu ADMIN không đúng. SERVER ADMIN vẫn khóa; SERVER FREE và quyền PREMIUM đã có không bị xóa."
                : @"Mật khẩu PREMIUM không đúng. SERVER PREMIUM vẫn khóa; SERVER FREE tiếp tục hoạt động.");
        dispatch_async(dispatch_get_main_queue(), ^{
            void (^showFailure)(void) = ^{
                if (!self.view.window || self.presentedViewController) return;
                UIAlertController *wrong = [UIAlertController alertControllerWithTitle:@"Không thể mở khóa"
                    message:failureMessage preferredStyle:UIAlertControllerStyleAlert];
                [wrong addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:wrong animated:YES completion:nil];
            };
            if (self.presentedViewController == passwordAlert) {
                [self dismissViewControllerAnimated:YES completion:showFailure];
            } else {
                showFailure();
            }
        });
    }]];
    [self presentViewController:passwordAlert animated:YES completion:nil];
}

- (void)premiumApplicationDidEnterBackground:(NSNotification *)note
{
    (void)note;
    // Pause transient work only. Persistent Premium authorization and selected
    // mode are deliberately not cleared when the app enters the background.
    [[PMInputAndDisplayBooster sharedBooster] suspendOptimizations];
    [self stopMetricsSampling];
}

- (void)premiumApplicationDidBecomeActive:(NSNotification *)note
{
    (void)note;
    // UIApplication can post DidBecomeActive before the active UIWindowScene
    // has completed attaching its window. Defer one main-queue turn, then
    // re-check every condition before touching UIKit or restarting timers.
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
            !self.isViewLoaded) return;

        // Restore the persisted server even when the user was on Music/Network/Apps
        // when the app went inactive. The server selection is global to this app
        // process; dashboard sampling itself is only restarted while Home is visible.
        [self prepareServerProfilesForLaunch];
        [self refreshActiveServerRuntime];

        BOOL selectedHome = self.tabBarController.selectedViewController == self.navigationController;
        BOOL topHome = self.navigationController.topViewController == self;
        if (selectedHome && topHome && self.view.window) [self startMetricsSampling];
        else [self stopMetricsSampling];
    });
}

- (void)applyPremiumPreset:(NSString *)preset
{
    if (!self.serverPremiumActive) return;
    NSDictionary *changes = nil;
    NSString *title = @"Cấu hình Premium";
    if ([preset isEqualToString:@"balanced"]) {
        title = @"Đã áp dụng cân bằng nâng cao";
        changes = @{
            @"Enabled": @YES, @"RefreshRateEnabled": @YES, @"FPSOverrideEnabled": @YES,
            @"FramePacing": @YES, @"AdvancedDisplayEnforcement": @YES,
            @"AdaptiveFPS": @YES, @"ThermalGuard": @YES, @"BackgroundReduction": @YES,
            @"ConflictGuard": @YES, @"StutterFix": @YES, @"MetalLayerCompatibility": @YES,
            @"MetalFramebufferOnlyOptimization": @NO, @"AppStabilityFix": @YES,
            @"ScreenRecordingFix": @YES, @"BatterySaver": @NO, @"ChargingOptimization": @NO,
            @"PerformancePreset": @0
        };
    } else if ([preset isEqualToString:@"latency"]) {
        title = @"Đã áp dụng ưu tiên độ trễ thấp";
        changes = @{
            @"Enabled": @YES, @"RefreshRateEnabled": @YES, @"FPSOverrideEnabled": @YES,
            @"FramePacing": @YES, @"AdvancedDisplayEnforcement": @YES,
            @"AdaptiveFPS": @YES, @"ThermalGuard": @YES, @"BackgroundReduction": @YES,
            @"ConflictGuard": @YES, @"StutterFix": @YES, @"MetalLayerCompatibility": @YES,
            @"MetalFramebufferOnlyOptimization": @NO, @"AppStabilityFix": @YES,
            @"ScreenRecordingFix": @YES, @"BatterySaver": @NO, @"ChargingOptimization": @NO,
            @"PerformancePreset": @1
        };
    } else if ([preset isEqualToString:@"battery"]) {
        title = @"Đã áp dụng tiết kiệm pin nâng cao";
        changes = @{
            @"Enabled": @YES, @"FramePacing": @YES, @"AdaptiveFPS": @YES,
            @"ThermalGuard": @YES, @"BackgroundReduction": @YES,
            @"ConflictGuard": @YES, @"StutterFix": @YES, @"AppStabilityFix": @YES,
            @"BatterySaver": @YES, @"ChargingOptimization": @YES,
            @"MetalFramebufferOnlyOptimization": @NO, @"PerformancePreset": @2
        };
    }
    if (!changes || !PMWriteDomainChanges(changes)) {
        [self showWriteFailure];
        return;
    }
    self.dashboardBuilt = NO;
    [self refreshActiveServerRuntime];
    [self stopMetricsSampling];
    [self buildDashboardSafely];
    UIAlertController *done = [UIAlertController alertControllerWithTitle:title
        message:@"Preset đã được lưu. Hiệu lực trong ứng dụng khác còn phụ thuộc runtime hook, ứng dụng, iOS và giới hạn phần cứng. Không có ép xung CPU/GPU hoặc tăng tốc gấp 5 lần được đảm bảo."
        preferredStyle:UIAlertControllerStyleAlert];
    [done addAction:[UIAlertAction actionWithTitle:@"Đã hiểu" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:done animated:YES completion:nil];
}


- (void)applyAdminPreset:(NSString *)preset
{
    if (!self.serverAdminActive || !PMAdminAuthorizationMatchesCurrentInstall()) return;
    NSDictionary *changes = nil;
    NSString *title = @"Cấu hình ADMIN";
    if ([preset isEqualToString:@"maximum-safe"]) {
        title = @"ADMIN · Hiệu năng thích ứng";
        changes = @{
            @"Enabled": @YES, @"RefreshRateEnabled": @YES, @"FPSOverrideEnabled": @YES,
            @"FramePacing": @YES, @"AdaptiveFPS": @YES, @"ThermalGuard": @YES,
            @"BackgroundReduction": @YES, @"ConflictGuard": @YES, @"StutterFix": @YES,
            @"AppStabilityFix": @YES, @"ScreenRecordingFix": @YES,
            @"AdminRenderSchedulerEnabled": @YES, @"AdminTouchTuningEnabled": @YES,
            @"AdminFastScrollEnabled": @YES, @"AdminHideScrollIndicatorsEnabled": @NO,
            @"AdminStaticSurfaceCacheEnabled": @YES, @"AdminThermalCooldownEnabled": @YES,
            @"AdminLocalDaemonBridgeEnabled": @NO, @"AdminChargingCooldownEnabled": @YES, @"PerformancePreset": @3
        };
    } else if ([preset isEqualToString:@"input-display"]) {
        title = @"ADMIN · Phản hồi & hiển thị";
        changes = @{
            @"Enabled": @YES, @"FramePacing": @YES, @"AdaptiveFPS": @YES,
            @"ThermalGuard": @YES, @"ConflictGuard": @YES, @"AppStabilityFix": @YES,
            @"AdminRenderSchedulerEnabled": @YES, @"AdminTouchTuningEnabled": @YES,
            @"AdminFastScrollEnabled": @YES, @"AdminHideScrollIndicatorsEnabled": @YES,
            @"AdminStaticSurfaceCacheEnabled": @NO, @"AdminThermalCooldownEnabled": @YES,
            @"AdminLocalDaemonBridgeEnabled": @NO, @"AdminChargingCooldownEnabled": @YES, @"PerformancePreset": @4
        };
    }
    if (!changes || !PMWriteDomainChanges(changes)) {
        [self showWriteFailure];
        return;
    }
    [self refreshActiveServerRuntime];
    self.dashboardBuilt = NO;
    [self stopMetricsSampling];
    [self buildDashboardSafely];
    UIAlertController *done = [UIAlertController alertControllerWithTitle:title
        message:@"Đã lưu profile ADMIN. Engine chỉ tối ưu giao diện và thao tác bên trong ProMotion Control; không có hook vào ứng dụng khác, không nâng quyền root, không ép xung hoặc vượt giới hạn nhiệt của iOS."
        preferredStyle:UIAlertControllerStyleAlert];
    [done addAction:[UIAlertAction actionWithTitle:@"Đã hiểu" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:done animated:YES completion:nil];
}

- (void)dashboardConfirmResetConfiguration
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Khôi phục mặc định?"
                                                                   message:@"Các tùy chọn toàn cục sẽ trở về cấu hình an toàn. Hồ sơ từng ứng dụng được giữ nguyên."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Khôi phục" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        BOOL ok = PMWriteDomainChanges(@{
            @"Enabled": @NO, @"RefreshRateEnabled": @NO, @"FPSOverrideEnabled": @NO,
            @"RefreshMode": @0, @"FPSMode": @0, @"CustomRefreshRate": @60, @"CustomFPS": @60,
            @"FramePacing": @NO, @"AdaptiveFPS": @YES, @"ThermalGuard": @YES,
            @"ConflictGuard": @YES, @"StutterFix": @YES, @"AppStabilityFix": @YES,
            @"BackgroundReduction": @YES, @"AppCompatibility": @NO,
            @"ScreenRecordingFix": @YES, @"BatterySaver": @NO, @"ChargingOptimization": @NO,
            @"AdvancedDisplayEnforcement": @NO
        });
        if (!ok) { [self showWriteFailure]; return; }
        self.dashboardBuilt = NO;
        [self buildDashboardSafely];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self prepareServerProfilesForLaunch];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(premiumApplicationDidEnterBackground:) name:UIApplicationWillResignActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(premiumApplicationDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(premiumApplicationDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    self.title = @"ProMotionControl";
    // Let UIApplication finish installing/displaying its root window before the
    // dashboard builds its large Auto Layout hierarchy. This avoids doing all UI
    // construction on the launch stack on older/jailbroken devices.
    self.dashboardBuildScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.dashboardBuildScheduled = NO;
        if (!self.isViewLoaded || self.dashboardBuilt || self.dashboardRecoveryMode) return;
        [self buildDashboardSafely];
    });
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self prepareServerProfilesForLaunch];
    [self startMetricsSampling];
    // Fresh installs and users without a valid Premium grant start silently in FREE.
    // All three modes pass through one router so the master and tier switches apply.
    [self refreshActiveServerRuntime];
    [self scheduleServerRelaunchPasswordGate];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    [self pm_updateNeonShadowPaths];
    if (!self.dashboardColumns) return;
    BOOL landscapeLayout = CGRectGetWidth(self.dashboardColumns.bounds) >= 520.0;
    UILayoutConstraintAxis desiredAxis = landscapeLayout ? UILayoutConstraintAxisHorizontal : UILayoutConstraintAxisVertical;
    if (self.dashboardColumns.axis != desiredAxis) self.dashboardColumns.axis = desiredAxis;
    self.dashboardColumns.alignment = UIStackViewAlignmentFill;
    self.dashboardColumns.distribution = UIStackViewDistributionFill;
    if (landscapeLayout) {
        if (!self.dashboardTelemetryWidthConstraint.active) self.dashboardTelemetryWidthConstraint.active = YES;
    } else if (self.dashboardTelemetryWidthConstraint.active) {
        self.dashboardTelemetryWidthConstraint.active = NO;
    }
}

- (void)viewWillDisappear:(BOOL)animated
{
    // Switching to Apps, Music, Network or About is not an application-background
    // event. Keep the selected FREE/PREMIUM/ADMIN engine active while the app is
    // foregrounded; UIApplication lifecycle notifications suspend transient
    // render/timer work only when iOS actually deactivates the process.
    [self stopMetricsSampling];
    [super viewWillDisappear:animated];
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillResignActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    // If the deferred launch build is scheduled, don't re-enter it synchronously.
    if (!self.dashboardBuilt && !self.dashboardRecoveryMode && !self.dashboardBuildScheduled) {
        [self buildDashboardSafely];
    } else if (self.dashboardBuilt && !self.dashboardRecoveryMode) {
        [self refreshModeChips];
    }
}

- (void)buildDashboardSafely
{
    if (![NSThread isMainThread]) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf buildDashboardSafely]; });
        return;
    }
    if (self.dashboardRecoveryMode || self.dashboardBuilt || !self.isViewLoaded) return;
    @try {
        [self buildDashboard];
        self.dashboardBuilt = YES;
        if (self.view.window) [self startMetricsSampling];
        if (self.serverAdminActive) {
            __weak typeof(self) weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (self && self.serverAdminActive && UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
                    [[PMInputAndDisplayBooster sharedBooster] refreshAdminOptimizationWithOptions:PMReadDomain() ?: @{}];
                }
            });
        }
    } @catch (NSException *exception) {
        self.dashboardRecoveryMode = YES;
        NSLog(@"[ProMotionControl] Dashboard initialization exception: %@: %@\n%@",
              exception.name, exception.reason, exception.callStackSymbols);
        @try {
            [self clearContent];
            [self addHeaderWithEyebrow:@"SAFE MODE" title:@"ProMotion Control" subtitle:@"Giao diện chính gặp lỗi khi khởi tạo."];
            NSString *detail = [NSString stringWithFormat:@"Đã giữ ứng dụng mở ở chế độ an toàn. Lỗi: %@ — %@. Hãy lấy crash log để xác định nguyên nhân gốc.", exception.name ?: @"NSException", exception.reason ?: @"không có mô tả"];
            [self addNote:detail toStack:self.contentStack];
        } @catch (NSException *recoveryException) {
            NSLog(@"[ProMotionControl] Recovery UI exception: %@: %@", recoveryException.name, recoveryException.reason);
            UILabel *fallback = [[UILabel alloc] initWithFrame:CGRectMake(20, 100, MAX(240, self.view.bounds.size.width - 40), 180)];
            fallback.numberOfLines = 0;
            fallback.textColor = PMPrimaryTextColor();
            fallback.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
            fallback.text = @"ProMotion Control đã mở ở chế độ an toàn. Hãy kiểm tra crash log.";
            [self.view addSubview:fallback];
        }
    }
}

- (void)buildDashboard
{
    [self clearContent];
    // The dashboard owns the scroll delegate only to slow telemetry during a drag.
    if (self.scrollView.delegate != self) self.scrollView.delegate = self;
    NSDictionary *domain = PMReadDomain() ?: @{};

    // FREE is always available. PREMIUM and ADMIN require their respective
    // passwords whenever the user explicitly selects those server buttons.
    UIStackView *serverCard = [self newCardWithTitle:@"SERVER" subtitle:@"FREE mặc định · Chọn PREMIUM hoặc ADMIN sẽ yêu cầu mật khẩu tương ứng"];
    // Use explicit UIButton hit targets instead of UISegmentedControl. This avoids
    // missed valueChanged events in nested UIStackViews and makes each server
    // independently tappable across the full card width.
    UIStackView *serverButtonRow = [[UIStackView alloc] initWithFrame:CGRectZero];
    serverButtonRow.translatesAutoresizingMaskIntoConstraints = NO;
    serverButtonRow.axis = UILayoutConstraintAxisHorizontal;
    serverButtonRow.alignment = UIStackViewAlignmentFill;
    serverButtonRow.distribution = UIStackViewDistributionFillEqually;
    serverButtonRow.spacing = 8.0;
    serverButtonRow.userInteractionEnabled = YES;
    NSArray<NSString *> *serverTitles = @[@"FREE", @"PREMIUM", @"ADMIN"];
    NSMutableArray<UIButton *> *serverButtons = [NSMutableArray arrayWithCapacity:serverTitles.count];
    for (NSInteger mode = 0; mode < (NSInteger)serverTitles.count; mode++) {
        UIButton *serverButton = [UIButton buttonWithType:UIButtonTypeSystem];
        serverButton.translatesAutoresizingMaskIntoConstraints = NO;
        serverButton.tag = mode;
        serverButton.enabled = YES;
        serverButton.userInteractionEnabled = YES;
        serverButton.exclusiveTouch = YES;
        serverButton.titleLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightBold];
        serverButton.titleLabel.adjustsFontSizeToFitWidth = YES;
        serverButton.titleLabel.minimumScaleFactor = 0.75;
        serverButton.layer.cornerRadius = 12.0;
        serverButton.layer.borderWidth = 1.0;
        serverButton.clipsToBounds = YES;
        [serverButton setTitle:serverTitles[(NSUInteger)mode] forState:UIControlStateNormal];
        [serverButton setTitle:serverTitles[(NSUInteger)mode] forState:UIControlStateSelected];
        [serverButton addTarget:self action:@selector(serverModeButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        [serverButton.heightAnchor constraintGreaterThanOrEqualToConstant:46.0].active = YES;
        [serverButtonRow addArrangedSubview:serverButton];
        [serverButtons addObject:serverButton];
    }
    self.serverModeButtons = [serverButtons copy];
    [serverCard addArrangedSubview:serverButtonRow];
    [self updateServerModeButtonsForMode:(self.serverAdminActive ? 2 : (self.serverPremiumActive ? 1 : 0))];
    NSString *serverStatusNote = nil;
    if (self.serverAdminActive) {
        serverStatusNote = @"SERVER ADMIN đang hoạt động. Mật khẩu ADMIN được kiểm tra độc lập; nhấn ADMIN lần nữa sẽ yêu cầu nhập lại mật khẩu.";
    } else if (self.serverPremiumActive) {
        serverStatusNote = @"SERVER PREMIUM đang hoạt động. Nhấn PREMIUM lần nữa sẽ yêu cầu nhập mật khẩu PREMIUM.";
    } else if (PMPremiumWasEverActivated()) {
        serverStatusNote = @"SERVER FREE đang hoạt động. Chọn PREMIUM hoặc ADMIN và nhập đúng mật khẩu tương ứng để mở khóa.";
    } else {
        serverStatusNote = @"Bạn đang sử dụng SERVER FREE. PREMIUM và ADMIN chỉ được kích hoạt sau khi nhập đúng mật khẩu riêng.";
    }
    [self addNote:serverStatusNote toStack:serverCard];

    // Brand header: compact speedometer badge, version pill and neon-purple title.
    UIView *hero = [UIView new];
    hero.translatesAutoresizingMaskIntoConstraints = NO;
    hero.backgroundColor = PMCardColor();
    hero.accessibilityIdentifier = @"pm.admin.static.brand-header";
    PMApplyNeonSurface(hero, 25.0);

    UIStackView *brandRow = [[UIStackView alloc] initWithFrame:CGRectZero];
    brandRow.translatesAutoresizingMaskIntoConstraints = NO;
    brandRow.axis = UILayoutConstraintAxisHorizontal;
    brandRow.alignment = UIStackViewAlignmentCenter;
    brandRow.spacing = 13.0;

    PMNeonGradientView *iconPlate = [[PMNeonGradientView alloc] initWithFrame:CGRectZero];
    iconPlate.translatesAutoresizingMaskIntoConstraints = NO;
    iconPlate.layer.cornerRadius = 20.0;
    UIImageView *brandIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"speedometer"]];
    brandIcon.translatesAutoresizingMaskIntoConstraints = NO;
    brandIcon.tintColor = UIColor.whiteColor;
    brandIcon.contentMode = UIViewContentModeScaleAspectFit;
    brandIcon.layer.shadowColor = UIColor.whiteColor.CGColor;
    brandIcon.layer.shadowOpacity = 0.28f;
    brandIcon.layer.shadowRadius = 7.0f;
    brandIcon.layer.shadowOffset = CGSizeZero;
    [iconPlate addSubview:brandIcon];
    [NSLayoutConstraint activateConstraints:@[
        [iconPlate.widthAnchor constraintEqualToConstant:66.0],
        [iconPlate.heightAnchor constraintEqualToConstant:66.0],
        [brandIcon.centerXAnchor constraintEqualToAnchor:iconPlate.centerXAnchor],
        [brandIcon.centerYAnchor constraintEqualToAnchor:iconPlate.centerYAnchor],
        [brandIcon.widthAnchor constraintEqualToConstant:38.0],
        [brandIcon.heightAnchor constraintEqualToConstant:38.0]
    ]];
    [brandRow addArrangedSubview:iconPlate];

    UIStackView *brandText = [[UIStackView alloc] initWithFrame:CGRectZero];
    brandText.translatesAutoresizingMaskIntoConstraints = NO;
    brandText.axis = UILayoutConstraintAxisVertical;
    brandText.alignment = UIStackViewAlignmentLeading;
    brandText.spacing = 4.0;
    UIStackView *titleRow = [[UIStackView alloc] initWithFrame:CGRectZero];
    titleRow.translatesAutoresizingMaskIntoConstraints = NO;
    titleRow.axis = UILayoutConstraintAxisHorizontal;
    titleRow.alignment = UIStackViewAlignmentCenter;
    titleRow.spacing = 7.0;
    UILabel *appName = PMLabel(@"ProMotionControl", 19.0, UIFontWeightBold, PMPrimaryTextColor());
    appName.numberOfLines = 1;
    appName.adjustsFontSizeToFitWidth = YES;
    appName.minimumScaleFactor = 0.68;
    [appName setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    UILabel *version = PMLabel([@"v" stringByAppendingString:PMAppVersionString()], 10.0, UIFontWeightBold, PMAccentColor());
    version.textAlignment = NSTextAlignmentCenter;
    version.backgroundColor = PMCardAltColor();
    version.layer.cornerRadius = 11.0;
    version.clipsToBounds = YES;
    [NSLayoutConstraint activateConstraints:@[
        [version.widthAnchor constraintGreaterThanOrEqualToConstant:62.0],
        [version.heightAnchor constraintEqualToConstant:25.0]
    ]];
    [titleRow addArrangedSubview:appName];
    [titleRow addArrangedSubview:version];
    [brandText addArrangedSubview:titleRow];
    [brandText addArrangedSubview:PMLabel(@"Tối ưu ProMotion · Hiệu năng · Độ ổn định", 10.5, UIFontWeightMedium, PMMutedColor())];
    [brandRow addArrangedSubview:brandText];
    [brandText setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [hero addSubview:brandRow];
    [NSLayoutConstraint activateConstraints:@[
        [brandRow.topAnchor constraintEqualToAnchor:hero.topAnchor constant:14.0],
        [brandRow.bottomAnchor constraintEqualToAnchor:hero.bottomAnchor constant:-14.0],
        [brandRow.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor constant:14.0],
        [brandRow.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor constant:-14.0]
    ]];
    [self.contentStack addArrangedSubview:hero];

    // The live monitor and the consolidated switch board share a responsive
    // two-column layout in landscape; in portrait the same panels stack safely.
    UIStackView *dashboardColumns = [[UIStackView alloc] initWithFrame:CGRectZero];
    dashboardColumns.translatesAutoresizingMaskIntoConstraints = NO;
    dashboardColumns.axis = UILayoutConstraintAxisVertical;
    dashboardColumns.alignment = UIStackViewAlignmentFill;
    dashboardColumns.distribution = UIStackViewDistributionFill;
    dashboardColumns.spacing = 12.0;
    self.dashboardColumns = dashboardColumns;

    UIStackView *statsColumn = [[UIStackView alloc] initWithFrame:CGRectZero];
    statsColumn.translatesAutoresizingMaskIntoConstraints = NO;
    statsColumn.axis = UILayoutConstraintAxisVertical;
    statsColumn.spacing = 8.0;
    [statsColumn addArrangedSubview:PMNeonSectionHeader(@"THÔNG SỐ", @"waveform.path.ecg")];
    UIView *telemetryPanel = [self dashboardTelemetryPanelWithDomain:domain];
    [statsColumn addArrangedSubview:telemetryPanel];

    UIStackView *switchColumn = [[UIStackView alloc] initWithFrame:CGRectZero];
    switchColumn.translatesAutoresizingMaskIntoConstraints = NO;
    switchColumn.axis = UILayoutConstraintAxisVertical;
    switchColumn.spacing = 8.0;
    [switchColumn addArrangedSubview:PMNeonSectionHeader(@"CÔNG TẮC", @"slider.horizontal.3")];
    NSArray<NSDictionary *> *allSwitchRows = @[
        @{ @"title": @"Bật ProMotion Control", @"subtitle": @"Cho phép runtime xử lý cấu hình đã lưu", @"key": @"Enabled", @"default": @NO, @"symbol": @"power" },
        @{ @"title": @"Áp dụng cho app tương thích", @"subtitle": @"Chỉ có tác dụng trong phạm vi runtime được hỗ trợ", @"key": @"AdvancedDisplayEnforcement", @"default": @YES, @"symbol": @"apps.iphone" },
        @{ @"title": @"Frame Pacing", @"subtitle": @"Yêu cầu khoảng khung hình tương thích", @"key": @"FramePacing", @"default": @YES, @"symbol": @"waveform.path" },
        @{ @"title": @"Adaptive FPS", @"subtitle": @"Tôn trọng nguồn điện và trạng thái nhiệt", @"key": @"AdaptiveFPS", @"default": @YES, @"symbol": @"speedometer" },
        @{ @"title": @"Thermal Guard", @"subtitle": @"Giảm mục tiêu khi iOS báo áp lực nhiệt", @"key": @"ThermalGuard", @"default": @YES, @"symbol": @"thermometer.medium" },
        @{ @"title": @"Giảm tải ứng dụng nền", @"subtitle": @"Khôi phục cấu hình gốc khi app ở nền", @"key": @"BackgroundReduction", @"default": @YES, @"symbol": @"moon.zzz" },
        @{ @"title": @"Conflict Guard", @"subtitle": @"Hạn chế ghi đè khi phát hiện xung đột", @"key": @"ConflictGuard", @"default": @YES, @"symbol": @"shield.lefthalf.filled" },
        @{ @"title": @"Stutter Fix", @"subtitle": @"Cho phép khoảng khung hình thích ứng", @"key": @"StutterFix", @"default": @YES, @"symbol": @"waveform.path.ecg" },
        @{ @"title": @"App Stability", @"subtitle": @"Ưu tiên đường xử lý tương thích an toàn", @"key": @"AppStabilityFix", @"default": @YES, @"symbol": @"checkmark.shield" },
        @{ @"title": @"Tối ưu khi quay màn hình", @"subtitle": @"Giảm tác vụ chẩn đoán phụ khi ghi hình", @"key": @"ScreenRecordingFix", @"default": @YES, @"symbol": @"record.circle" },
        @{ @"title": @"Ghi đè hồ sơ bị chặn", @"subtitle": @"Áp dụng theo chính sách tương thích đã chọn", @"key": @"OverrideBlockedApps", @"default": @YES, @"symbol": @"lock.open" },
        @{ @"title": @"Tiết kiệm pin", @"subtitle": @"Ưu tiên mục tiêu thấp hơn để tiết kiệm năng lượng", @"key": @"BatterySaver", @"default": @NO, @"symbol": @"battery.75percent" },
        @{ @"title": @"Giảm tải dashboard khi sạc", @"subtitle": @"Giảm tần suất lấy mẫu/chẩn đoán phụ; không hạ Hz/FPS đã chọn", @"key": @"ChargingOptimization", @"default": @NO, @"symbol": @"battery.100percent" }
    ];
    [switchColumn addArrangedSubview:PMLabel(@"13 CÔNG TẮC · TRẠNG THÁI ĐỌC TỪ CẤU HÌNH ĐÃ LƯU", 9.0, UIFontWeightBold, PMMutedColor())];
    [self addSwitchRows:allSwitchRows title:nil toStack:switchColumn];
    [dashboardColumns addArrangedSubview:statsColumn];
    [dashboardColumns addArrangedSubview:switchColumn];
    self.dashboardTelemetryWidthConstraint = [statsColumn.widthAnchor constraintEqualToAnchor:dashboardColumns.widthAnchor multiplier:0.43];
    [self.contentStack addArrangedSubview:dashboardColumns];
    [self addNote:@"Các công tắc và CADisplayLink hook được lưu riêng trong hồ sơ từng SERVER. Hook hiện áp dụng trong tiến trình ProMotion Control; không tuyên bố đã hook game hoặc ứng dụng khác khi bộ lọc injection chưa bật cho bundle đó. Chuyển SERVER sẽ lưu hồ sơ cũ và nạp hồ sơ mới." toStack:self.contentStack];

    if (!self.serverPremiumActive && !self.serverAdminActive) {
        [self.contentStack addArrangedSubview:PMNeonSectionHeader(@"FREE · TỐI ƯU CƠ BẢN", @"leaf.fill")];
        NSArray<NSDictionary *> *freeSwitchRows = @[
            @{ @"title": @"FREE Render Scheduler", @"subtitle": @"Vòng nhịp phụ nhẹ, chỉ chạy khi trang chủ hoạt động", @"key": @"FreeRenderSchedulerEnabled", @"default": @YES, @"symbol": @"waveform.path" },
            @{ @"title": @"FREE Smooth Engine", @"subtitle": @"PMSmoothEngine dùng chung một CADisplayLink, không tạo vòng render trùng", @"key": @"FreeSmoothEngineEnabled", @"default": @YES, @"symbol": @"waveform.path.ecg" },
            @{ @"title": @"FREE Touch Tuning", @"subtitle": @"Tối ưu trì hoãn nội dung cuộn trong app điều khiển", @"key": @"FreeTouchTuningEnabled", @"default": @YES, @"symbol": @"hand.tap" },
            @{ @"title": @"FREE Adaptive Cadence", @"subtitle": @"Giữ mục tiêu đã chọn khi sạc; chỉ bảo vệ khi LPM hoặc nhiệt thực tăng", @"key": @"FreeAdaptiveCadenceEnabled", @"default": @YES, @"symbol": @"speedometer" },
            @{ @"title": @"FREE Thermal Guard", @"subtitle": @"Dừng tác vụ phụ khi iOS báo nhiệt nghiêm trọng", @"key": @"FreeThermalGuardEnabled", @"default": @YES, @"symbol": @"thermometer.medium" },
            @{ @"title": @"FREE CADisplayLink Hook", @"subtitle": @"Điều chỉnh nhịp CADisplayLink trong ứng dụng ProMotion Control", @"key": @"FreeCADisplayLinkHookEnabled", @"default": @YES, @"symbol": @"waveform.path.ecg" },
            @{ @"title": @"FREE Background Audio Guard", @"subtitle": @"Giữ nhạc nền của app khác khi ProMotion Control tắt phiên âm thanh", @"key": @"FreeBackgroundAudioGuardEnabled", @"default": @YES, @"symbol": @"music.note" },
            @{ @"title": @"FREE Activity Boost", @"subtitle": @"Xin ưu tiên khi sạc; chỉ giữ wake-lock nếu máy chưa nóng", @"key": @"FreeActivityBoostEnabled", @"default": @YES, @"symbol": @"bolt.badge.clock" },
            @{ @"title": @"FREE Background Keep-Alive", @"subtitle": @"Tweak tiếp tục chạy nền tối đa 5 phút khi còn nhạc nền", @"key": @"FreeBackgroundKeepAliveEnabled", @"default": @YES, @"symbol": @"clock.arrow.circlepath" },
            @{ @"title": @"FREE Background Continuity", @"subtitle": @"Phát im lặng trong chế độ audio nền để server đã chọn chạy liên tục khi app xuống nền; không cắt nhạc app khác", @"key": @"FreeBackgroundContinuityEnabled", @"default": @YES, @"symbol": @"infinity" },
            @{ @"title": @"FREE Memory Guard", @"subtitle": @"Trả trang malloc trống khi RAM tăng quá 96 MB; không purge cache hệ thống", @"key": @"FreeMemoryGuardEnabled", @"default": @YES, @"symbol": @"memorychip" },
            @{ @"title": @"FREE Rate Sentinel", @"subtitle": @"Kiểm tra lại yêu cầu Hz/FPS mỗi 1 giây trong phiên hoạt động", @"key": @"FreeRateSentinelEnabled", @"default": @YES, @"symbol": @"scope" }
        ];
        [self addSwitchRows:freeSwitchRows title:@"CÔNG TẮC RIÊNG CHO FREE" toStack:self.contentStack];
    }

    // Premium adds carefully bounded configuration presets; no CPU/GPU overclock
    // or privilege escalation is attempted. The Free panel above remains unchanged.
    if (self.serverPremiumActive) {
        [self.contentStack addArrangedSubview:PMNeonSectionHeader(@"PREMIUM · PROFILE NÂNG CAO", @"sparkles")];
        UIStackView *premiumCard = [self newCardWithTitle:@"Bộ cấu hình Premium" subtitle:@"Render cadence, phản hồi cuộn trong ứng dụng điều khiển và thích ứng nhiệt/nguồn. Không ép xung CPU/GPU."];
        [self addRouteRowWithTitle:@"Cân bằng nâng cao" subtitle:@"Frame pacing, thermal guard, conflict guard và ổn định ứng dụng" route:@"premium:balanced" symbol:@"slider.horizontal.3" toStack:premiumCard];
        [premiumCard addArrangedSubview:PMSeparator()];
        [self addRouteRowWithTitle:@"Ưu tiên độ trễ thấp" subtitle:@"Ưu tiên nhịp khung ổn định, không tắt bảo vệ nhiệt" route:@"premium:latency" symbol:@"bolt.fill" toStack:premiumCard];
        [premiumCard addArrangedSubview:PMSeparator()];
        [self addRouteRowWithTitle:@"Tiết kiệm pin nâng cao" subtitle:@"Tăng ưu tiên thích ứng và giảm tác vụ nền" route:@"premium:battery" symbol:@"battery.100percent" toStack:premiumCard];
        NSArray<NSDictionary *> *premiumSwitchRows = @[
            @{ @"title": @"Premium Render Scheduler", @"subtitle": @"Điều khiển vòng CADisplayLink Premium", @"key": @"PremiumRenderSchedulerEnabled", @"default": @YES, @"symbol": @"waveform.path" },
            @{ @"title": @"Premium Touch Tuning", @"subtitle": @"Tối ưu cuộn và phản hồi chạm trong app điều khiển", @"key": @"PremiumTouchTuningEnabled", @"default": @YES, @"symbol": @"hand.tap" },
            @{ @"title": @"Premium Low Latency", @"subtitle": @"Ưu tiên cadence thấp độ trễ trong giới hạn hệ thống", @"key": @"PremiumLowLatencyModeEnabled", @"default": @YES, @"symbol": @"bolt.fill" },
            @{ @"title": @"Premium Thermal Guard", @"subtitle": @"Giảm nhịp phụ khi thiết bị ấm", @"key": @"PremiumThermalGuardEnabled", @"default": @YES, @"symbol": @"thermometer.medium" },
            @{ @"title": @"Premium Charging Guard", @"subtitle": @"Giảm lấy mẫu dashboard khi sạc; không hạ mục tiêu Hz/FPS", @"key": @"PremiumChargingGuardEnabled", @"default": @YES, @"symbol": @"battery.100percent" },
            @{ @"title": @"Titanium Tier-4 Display Policy", @"subtitle": @"Phân giải FPS/Hz theo hồ sơ PREMIUM và khả năng màn hình qua CADisplayLink công khai", @"key": @"PremiumTier4DisplayPolicyEnabled", @"default": @YES, @"symbol": @"display.2" },
            @{ @"title": @"Premium CADisplayLink Hook", @"subtitle": @"Áp dụng mục tiêu FPS/Hz đã chọn cho DisplayLink trong ControlApp", @"key": @"PremiumCADisplayLinkHookEnabled", @"default": @YES, @"symbol": @"waveform.path.ecg" },
            @{ @"title": @"Premium Network Low Latency", @"subtitle": @"QoS ResponsiveData của Apple, timeout ngắn, nhiều kết nối song song", @"key": @"PremiumNetworkLowLatencyEnabled", @"default": @YES, @"symbol": @"antenna.radiowaves.left.and.right" },
            @{ @"title": @"Premium Background Audio Guard", @"subtitle": @"MixWithOthers và nhả phiên êm để nhạc nền không bị cắt", @"key": @"PremiumBackgroundAudioGuardEnabled", @"default": @YES, @"symbol": @"music.note" },
            @{ @"title": @"Premium Activity Boost", @"subtitle": @"Giữ ưu tiên cao khi sạc hoặc chạy nền, nhả khi máy nóng", @"key": @"PremiumActivityBoostEnabled", @"default": @YES, @"symbol": @"bolt.badge.clock" },
            @{ @"title": @"Premium Background Keep-Alive", @"subtitle": @"Tweak tiếp tục chạy nền tối đa 30 phút khi sạc hoặc còn nhạc nền", @"key": @"PremiumBackgroundKeepAliveEnabled", @"default": @YES, @"symbol": @"clock.arrow.circlepath" },
            @{ @"title": @"Premium Background Continuity", @"subtitle": @"Giữ PREMIUM chạy liên tục khi app ở nền bằng phiên audio im lặng mixWithOthers", @"key": @"PremiumBackgroundContinuityEnabled", @"default": @YES, @"symbol": @"infinity" },
            @{ @"title": @"Premium Memory Guard", @"subtitle": @"Ngưỡng 64 MB, cooldown 3 phút; trả trang malloc và xoá cache URL của app", @"key": @"PremiumMemoryGuardEnabled", @"default": @YES, @"symbol": @"memorychip" },
            @{ @"title": @"Premium Rate Sentinel", @"subtitle": @"Kiểm tra lại yêu cầu Hz/FPS mỗi 0,5 giây — gấp 2 lần FREE", @"key": @"PremiumRateSentinelEnabled", @"default": @YES, @"symbol": @"scope" }
        ];
        [self addSwitchRows:premiumSwitchRows title:@"CÔNG TẮC RIÊNG CHO PREMIUM" toStack:self.contentStack];
        [self addNote:@"PREMIUM Guard: xác thực gắn với mã cài đặt tweak, tối đa 5 lần nhập sai trước khi khóa thử lại 60 giây, chỉ chạy một engine. Khi sạc, công tắc Charging Guard chỉ giảm tần suất lấy mẫu dashboard (0,4 giây thay vì 0,31 giây), không hạ Hz/FPS đã chọn. Khi app điều khiển xuống nền, tác vụ phụ dừng. iOS vẫn quản lý nhiệt; hook game/app ngoài vẫn bị cách ly." toStack:self.contentStack];
    }

    if (self.serverAdminActive) {
        [self.contentStack addArrangedSubview:PMNeonSectionHeader(@"ADMIN · QUẢN TRỊ NÂNG CAO", @"shield.lefthalf.filled")];
        UIStackView *adminCard = [self newCardWithTitle:@"Admin Control Engine"
            subtitle:@"Điều khiển sâu các tối ưu app-local, có lưu trạng thái và tự khôi phục khi tắt ADMIN."];
        [self addRouteRowWithTitle:@"Hiệu năng thích ứng tối đa an toàn"
            subtitle:@"Yêu cầu nhịp vẽ cao nhất trong giới hạn màn hình, pin và nhiệt"
            route:@"admin:maximum-safe" symbol:@"bolt.fill" toStack:adminCard];
        [adminCard addArrangedSubview:PMSeparator()];
        [self addRouteRowWithTitle:@"Phản hồi cảm ứng & hiển thị"
            subtitle:@"Tối ưu thao tác cuộn và thanh chỉ báo trong app điều khiển"
            route:@"admin:input-display" symbol:@"hand.tap.fill" toStack:adminCard];
        [self.contentStack addArrangedSubview:adminCard];

        NSArray<NSDictionary *> *adminSwitchRows = @[
            @{ @"title": @"Admin Render Scheduler", @"subtitle": @"Bật CADisplayLink yêu cầu nhịp theo cấu hình và khả năng màn hình thực tế", @"key": @"AdminRenderSchedulerEnabled", @"default": @YES, @"symbol": @"waveform.path" },
            @{ @"title": @"Admin Touch Tuning", @"subtitle": @"Giảm trì hoãn chạm trong UIScrollView của ProMotion Control", @"key": @"AdminTouchTuningEnabled", @"default": @YES, @"symbol": @"hand.tap" },
            @{ @"title": @"Admin Fast Scroll", @"subtitle": @"Tăng decelerationRate trong các vùng cuộn của app điều khiển", @"key": @"AdminFastScrollEnabled", @"default": @NO, @"symbol": @"arrow.up.and.down" },
            @{ @"title": @"Ẩn thanh cuộn", @"subtitle": @"Ẩn chỉ báo cuộn trong app điều khiển; trạng thái gốc được khôi phục", @"key": @"AdminHideScrollIndicatorsEnabled", @"default": @NO, @"symbol": @"rectangle.compress.vertical" },
            @{ @"title": @"Cache bề mặt tĩnh", @"subtitle": @"Chỉ rasterize view tĩnh được đánh dấu và có nền đục", @"key": @"AdminStaticSurfaceCacheEnabled", @"default": @NO, @"symbol": @"square.stack.3d.up" },
            @{ @"title": @"Admin Thermal Cooldown", @"subtitle": @"Khi máy ấm, giảm nhịp phụ còn tối đa 60; khi nóng sẽ dừng vòng render phụ", @"key": @"AdminThermalCooldownEnabled", @"default": @YES, @"symbol": @"thermometer.medium" },
            @{ @"title": @"Admin Charging Guard · 75%", @"subtitle": @"Giảm tần suất lấy mẫu dashboard khi sạc; không hạ Hz/FPS đã chọn", @"key": @"AdminChargingCooldownEnabled", @"default": @YES, @"symbol": @"battery.100percent" },
            @{ @"title": @"Local Admin Daemon Bridge", @"subtitle": @"Kết nối daemon root-owned qua Unix socket, chỉ gửi status/thermal_reduce/thermal_resume", @"key": @"AdminLocalDaemonBridgeEnabled", @"default": @NO, @"symbol": @"cable.connector" },
            @{ @"title": @"Admin Adaptive Frame Pacing", @"subtitle": @"Chọn nhịp thích ứng theo giới hạn màn hình và điều kiện máy", @"key": @"AdminAdaptiveFramePacingEnabled", @"default": @YES, @"symbol": @"slider.horizontal.3" },
            @{ @"title": @"Titanium Hardware Rate Adapter", @"subtitle": @"Áp dụng mục tiêu Hz/FPS ADMIN lên CADisplayLink; không giả mode hoặc ghi trực tiếp driver", @"key": @"AdminTitaniumHardwareRateAdapterEnabled", @"default": @YES, @"symbol": @"cpu" },
            @{ @"title": @"Admin Foreground Transition Assist", @"subtitle": @"Khôi phục engine ADMIN nhanh khi quay lại ProMotion Control; không hook SpringBoard hay app khác", @"key": @"AdminHomeTransitionShieldEnabled", @"default": @YES, @"symbol": @"arrow.uturn.backward.circle" },
            @{ @"title": @"Admin Dashboard Load Shed", @"subtitle": @"Giảm số lần lấy mẫu dashboard để hạ tải phụ", @"key": @"AdminDashboardLoadShedEnabled", @"default": @YES, @"symbol": @"gauge.with.dots.needle.50percent" },
            @{ @"title": @"ADMIN CADisplayLink Hook", @"subtitle": @"Áp dụng mục tiêu FPS/Hz theo chính sách ADMIN trong ControlApp", @"key": @"AdminCADisplayLinkHookEnabled", @"default": @YES, @"symbol": @"waveform.path.ecg" },
            @{ @"title": @"Admin Network Low Latency", @"subtitle": @"QoS phản hồi nhanh và tối đa 10 kết nối mỗi host", @"key": @"AdminNetworkLowLatencyEnabled", @"default": @YES, @"symbol": @"antenna.radiowaves.left.and.right" },
            @{ @"title": @"Admin Background Audio Guard", @"subtitle": @"Giữ phiên âm thanh và nhạc nền liên tục khi chuyển nền", @"key": @"AdminBackgroundAudioGuardEnabled", @"default": @YES, @"symbol": @"music.note" },
            @{ @"title": @"Admin Background Keep-Alive", @"subtitle": @"Xin thời gian chạy nền tối đa 30 phút; iOS vẫn quyết định thời điểm kết thúc", @"key": @"AdminBackgroundKeepAliveEnabled", @"default": @YES, @"symbol": @"clock.arrow.circlepath" },
            @{ @"title": @"Admin Background Continuity", @"subtitle": @"ADMIN chạy liên tục khi app ở nền; tự dừng khi chọn FREE hoặc tắt công tắc tổng", @"key": @"AdminBackgroundContinuityEnabled", @"default": @YES, @"symbol": @"infinity" },
            @{ @"title": @"Admin Memory Guard", @"subtitle": @"Ngưỡng 48 MB, cooldown 2 phút, relief ngay khi có memory warning", @"key": @"AdminMemoryGuardEnabled", @"default": @YES, @"symbol": @"memorychip" },
            @{ @"title": @"Admin Rate Sentinel", @"subtitle": @"Kiểm tra lại nhịp đã chọn mỗi 0,1 giây — tần suất cao nhất của ADMIN", @"key": @"AdminRateSentinelEnabled", @"default": @YES, @"symbol": @"scope" }
        ];
        [self addSwitchRows:adminSwitchRows title:@"CÔNG TẮC RIÊNG CHO ADMIN" toStack:self.contentStack];
        [self addNote:@"ADMIN Guard: xác thực riêng bằng mật khẩu ADMIN, gắn với mã cài đặt tweak và có giới hạn thử sai. Admin Dashboard Load Shed giảm tần suất đo phụ (0,8 giây thay vì 0,2 giây); khi Admin Charging Guard bật, lấy mẫu dashboard là 1,0 giây. Các công tắc này không hạ Hz/FPS đã chọn. Bảo vệ nhiệt thực tế của iOS vẫn được tôn trọng; tweak không điều khiển dòng/điện áp sạc. ADMIN không phải root; daemon bridge là tùy chọn và hook app ngoài tiếp tục bị cách ly." toStack:self.contentStack];
    }

    // Master status is already represented by the first switch in the Công tắc section.
    PMNeonGradientView *restoreSurface = [[PMNeonGradientView alloc] initWithFrame:CGRectZero];
    restoreSurface.translatesAutoresizingMaskIntoConstraints = NO;
    restoreSurface.layer.cornerRadius = 19.0;
    UIButton *restore = [UIButton buttonWithType:UIButtonTypeSystem];
    restore.translatesAutoresizingMaskIntoConstraints = NO;
    restore.backgroundColor = UIColor.clearColor;
    [restore setTitle:@"↻   Khôi phục mặc định" forState:UIControlStateNormal];
    [restore setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    restore.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightBold];
    [restore addTarget:self action:@selector(dashboardConfirmResetConfiguration) forControlEvents:UIControlEventTouchUpInside];
    [restoreSurface addSubview:restore];
    [NSLayoutConstraint activateConstraints:@[
        [restoreSurface.heightAnchor constraintEqualToConstant:58.0],
        [restore.topAnchor constraintEqualToAnchor:restoreSurface.topAnchor],
        [restore.bottomAnchor constraintEqualToAnchor:restoreSurface.bottomAnchor],
        [restore.leadingAnchor constraintEqualToAnchor:restoreSurface.leadingAnchor],
        [restore.trailingAnchor constraintEqualToAnchor:restoreSurface.trailingAnchor]
    ]];
    [self.contentStack addArrangedSubview:restoreSurface];

    UILabel *footer = PMLabel(@"ProMotionControl · Hiệu năng · Ổn định · An toàn", 10.5, UIFontWeightMedium, PMMutedColor());
    footer.textAlignment = NSTextAlignmentCenter;
    [self.contentStack addArrangedSubview:footer];
    [self addNote:@"Chế độ cách ly an toàn vẫn bật: FREE, PREMIUM và ADMIN không cài hook vào ứng dụng bên ngoài trong bản phát hành này. Cấu hình app khác chỉ được lưu cho tới khi có runtime riêng được kiểm thử." toStack:self.contentStack];
}

+ (UIViewController *)makeAppRootController
{
    PMRefreshUIOptions();
    PMInstallLocalizationHooks();
    if (@available(iOS 13.0, *)) {
        UIApplication *app = UIApplication.sharedApplication;
        for (UIWindow *window in app.windows) {
            window.overrideUserInterfaceStyle = PMLightThemeSelected ? UIUserInterfaceStyleLight : UIUserInterfaceStyleDark;
        }
    }
    // Configure appearance through UIKit proxies. Do not read navigation.view,
    // navigation.navigationBar, or tabs.tabBar here: accessing those properties
    // can trigger eager view loading while UIApplication is still launching.
    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *navAppearance = [UINavigationBarAppearance new];
        [navAppearance configureWithOpaqueBackground];
        navAppearance.backgroundColor = PMBackgroundColor();
        navAppearance.titleTextAttributes = @{NSForegroundColorAttributeName: PMPrimaryTextColor()};
        navAppearance.largeTitleTextAttributes = @{NSForegroundColorAttributeName: PMPrimaryTextColor()};

        UINavigationBar *navProxy = [UINavigationBar appearance];
        navProxy.tintColor = PMAccentColor();
        navProxy.translucent = NO;
        navProxy.standardAppearance = navAppearance;
        navProxy.scrollEdgeAppearance = navAppearance;
        navProxy.compactAppearance = navAppearance;

        UITabBarAppearance *tabAppearance = [UITabBarAppearance new];
        [tabAppearance configureWithOpaqueBackground];
        tabAppearance.backgroundColor = PMCardColor();
        tabAppearance.shadowColor = PMBorderColor();
        tabAppearance.stackedLayoutAppearance.normal.iconColor = PMMutedColor();
        tabAppearance.stackedLayoutAppearance.normal.titleTextAttributes = @{
            NSForegroundColorAttributeName: PMMutedColor(),
            NSFontAttributeName: [UIFont systemFontOfSize:9 weight:UIFontWeightMedium]
        };
        tabAppearance.stackedLayoutAppearance.selected.iconColor = PMAccentColor();
        tabAppearance.stackedLayoutAppearance.selected.titleTextAttributes = @{
            NSForegroundColorAttributeName: PMAccentColor(),
            NSFontAttributeName: [UIFont systemFontOfSize:9 weight:UIFontWeightSemibold]
        };
        UITabBar *tabProxy = [UITabBar appearance];
        tabProxy.standardAppearance = tabAppearance;
        if (@available(iOS 15.0, *)) tabProxy.scrollEdgeAppearance = tabAppearance;
        tabProxy.tintColor = PMAccentColor();
        tabProxy.unselectedItemTintColor = PMMutedColor();
    }

    NSArray<UIViewController *> *pages = @[
        [PMControlViewController new],
        [PMAppsViewController new],
        [PMInfoViewController new],
        [PMEarthViewController new],
        [PMNetworkViewController new]
    ];
    NSArray<NSString *> *titles = @[
        PMTranslateString(@"Trang chủ"), PMTranslateString(@"Ứng dụng"),
        PMTranslateString(@"Giới thiệu"), PMTranslateString(@"Trái đất"), PMTranslateString(@"Mạng")
    ];
    NSArray<NSString *> *symbols = @[@"house.fill", @"square.grid.2x2.fill", @"info.circle.fill", @"globe", @"wifi"] ;
    NSMutableArray<UINavigationController *> *navigationControllers = [NSMutableArray arrayWithCapacity:pages.count];
    for (NSUInteger index = 0; index < pages.count; index++) {
        UIViewController *page = pages[index];
        UIImage *image = [UIImage systemImageNamed:symbols[index]];
        page.tabBarItem = [[UITabBarItem alloc] initWithTitle:titles[index] image:image selectedImage:image];
        // Create controllers only. Let UIKit load the selected page when it is
        // actually attached to the visible window; other tabs remain lazy.
        UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:page];
        [navigationControllers addObject:navigation];
    }

    UITabBarController *tabs = [UITabBarController new];
    tabs.viewControllers = navigationControllers;
    tabs.selectedIndex = 0;
    NSLog(@"[ProMotionControl] Lazy root hierarchy created (5 tabs: Home, Apps, About, Earth, Network). Awaiting UIKit view lifecycle.");
    return tabs;
}

@end

static void PMRebuildUIForPreferenceChange(void)
{
    PMRefreshUIOptions();
    PMInstallLocalizationHooks();
    UIWindow *targetWindow = nil;
    UIApplication *application = UIApplication.sharedApplication;
    for (UIWindow *candidate in application.windows) {
        if (candidate.isKeyWindow) { targetWindow = candidate; break; }
    }
    if (!targetWindow) targetWindow = application.keyWindow;
    if (!targetWindow) {
        NSLog(@"[ProMotionControl] Cannot rebuild UI: no key window.");
        return;
    }
    UIViewController *newRoot = [PMControlViewController makeAppRootController];
    if (!newRoot) return;
    targetWindow.rootViewController = newRoot;
    if (@available(iOS 13.0, *)) targetWindow.overrideUserInterfaceStyle = PMLightThemeSelected ? UIUserInterfaceStyleLight : UIUserInterfaceStyleDark;
    [targetWindow makeKeyAndVisible];
    NSLog(@"[ProMotionControl] UI reloaded language=%@ theme=%@", PMEnglishSelected ? @"en" : @"vi", PMLightThemeSelected ? @"light" : @"dark");
}

@implementation PMRateSettingsViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Tần số quét & FPS";
    [self buildRateSettings];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self buildRateSettings];
}

- (NSInteger)quantizedRefreshRate:(UISlider *)slider
{
    // The slider is a continuous integer target from 10 to 244. The runtime
    // separately caps the effective request to the display/iOS capability.
    return MIN(MAX((NSInteger)lrintf(slider.value), 10), 244);
}

- (void)updateCustomRateChipTag:(NSInteger)tag value:(NSInteger)value unit:(NSString *)unit selected:(BOOL)selected
{
    UIButton *chip = (UIButton *)[self.view viewWithTag:tag];
    if (![chip isKindOfClass:[UIButton class]]) return;
    NSInteger clamped = MIN(MAX(value, 10), 244);
    [chip setTitle:[NSString stringWithFormat:@"Tùy chỉnh %@: %ld %@", unit, (long)clamped, unit]
          forState:UIControlStateNormal];
    chip.backgroundColor = selected
        ? (PMLightThemeSelected ? PMRGB(199, 224, 252) : PMRGB(64, 35, 105))
        : PMCardAltColor();
    chip.layer.borderColor = (selected ? PMAccentColor() : PMBorderColor()).CGColor;
    [chip setTitleColor:(selected ? PMPrimaryTextColor() : PMMutedColor()) forState:UIControlStateNormal];
}

- (void)updateCustomRateChipTag:(NSInteger)tag value:(NSInteger)value unit:(NSString *)unit
{
    [self updateCustomRateChipTag:tag value:value unit:unit selected:YES];
}

- (void)refreshSliderPreviewChanged:(UISlider *)slider
{
    NSInteger value = [self quantizedRefreshRate:slider];
    UILabel *valueLabel = (UILabel *)[self.view viewWithTag:7282];
    if ([valueLabel isKindOfClass:[UILabel class]]) {
        valueLabel.text = [NSString stringWithFormat:@"%ld Hz", (long)value];
    }
    [self updateCustomRateChipTag:7286 value:value unit:@"Hz"];
}

- (void)refreshSliderCommitted:(UISlider *)slider
{
    NSInteger value = [self quantizedRefreshRate:slider];
    // Selecting a concrete global Hz target is an explicit request to enable
    // global runtime enforcement, not just persist a UI number. The tweak's
    // runtime checks AdvancedDisplayEnforcement as well as Enabled/FramePacing.
    // Mode -1 marks the value as the custom selection so the custom chip and
    // every label read back exactly the integer chosen on the slider.
    BOOL ok = PMWriteDomainChanges(@{
        @"RefreshMode": @(-1),
        @"CustomRefreshRate": @(value),
        @"RefreshRateEnabled": @YES,
        @"Enabled": @YES,
        @"FramePacing": @YES,
        @"AdvancedDisplayEnforcement": @YES,
        @"ExactRateEnforcement": @YES
    });
    if (!ok) [self showWriteFailure];
    [self pm_refreshActiveServerRuntime];
    [self buildRateSettings];
}

- (void)fpsSliderPreviewChanged:(UISlider *)slider
{
    NSInteger value = MIN(MAX((NSInteger)lrintf(slider.value), 10), 244);
    UILabel *valueLabel = (UILabel *)[self.view viewWithTag:7283];
    if ([valueLabel isKindOfClass:[UILabel class]]) {
        valueLabel.text = [NSString stringWithFormat:@"%ld FPS", (long)value];
    }
    [self updateCustomRateChipTag:7287 value:value unit:@"FPS"];
}

- (void)fpsSliderCommitted:(UISlider *)slider
{
    NSInteger value = MIN(MAX((NSInteger)lrintf(slider.value), 10), 244);
    BOOL ok = PMWriteDomainChanges(@{
        @"FPSMode": @(-1),
        @"CustomFPS": @(value),
        @"FPSOverrideEnabled": @YES,
        @"Enabled": @YES,
        @"FramePacing": @YES,
        @"AdvancedDisplayEnforcement": @YES,
        @"ExactRateEnforcement": @YES
    });
    if (!ok) [self showWriteFailure];
    [self pm_refreshActiveServerRuntime];
    [self buildRateSettings];
}

- (void)fpsOptionTapped:(UIButton *)sender
{
    NSInteger mode = sender.tag;
    if (mode != 0 && mode != 30 && mode != 60 && mode != 90 && mode != 120 && mode != 144 && mode != 244) return;
    // A global FPS choice must activate the global-scope switch too; otherwise
    // a previously disabled AdvancedDisplayEnforcement flag makes the chosen
    // value appear saved in the UI while the runtime correctly refuses to apply it.
    BOOL ok = PMWriteDomainChanges(@{
        @"FPSMode": @(mode),
        @"FPSOverrideEnabled": @(mode != 0),
        @"Enabled": @YES,
        @"FramePacing": @YES,
        @"AdvancedDisplayEnforcement": @YES,
        @"ExactRateEnforcement": @YES
    });
    if (!ok) [self showWriteFailure];
    [self pm_refreshActiveServerRuntime];
    [self buildRateSettings];
}

- (void)addFPSOptionWithMode:(NSInteger)mode title:(NSString *)title subtitle:(NSString *)subtitle selected:(BOOL)selected toStack:(UIStackView *)stack
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.tag = mode;
    button.backgroundColor = UIColor.clearColor;
    button.accessibilityLabel = title;
    button.accessibilityHint = @"Chọn mục tiêu FPS";
    [button addTarget:self action:@selector(fpsOptionTapped:) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *row = [[UIStackView alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 11.0;
    row.userInteractionEnabled = NO;
    UILabel *radio = PMLabel(selected ? @"◉" : @"○", 22, UIFontWeightMedium, selected ? PMAccentColor() : PMMutedColor());
    [radio.widthAnchor constraintEqualToConstant:25.0].active = YES;
    [row addArrangedSubview:radio];
    UIStackView *textStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 2.0;
    textStack.userInteractionEnabled = NO;
    [textStack addArrangedSubview:PMLabel(title, 13, UIFontWeightSemibold, PMPrimaryTextColor())];
    [textStack addArrangedSubview:PMLabel(subtitle ?: @"", 10, UIFontWeightRegular, PMMutedColor())];
    [row addArrangedSubview:textStack];
    [button addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:button.leadingAnchor constant:4.0],
        [row.trailingAnchor constraintEqualToAnchor:button.trailingAnchor constant:-4.0],
        [row.topAnchor constraintEqualToAnchor:button.topAnchor constant:5.0],
        [row.bottomAnchor constraintEqualToAnchor:button.bottomAnchor constant:-5.0],
        [button.heightAnchor constraintGreaterThanOrEqualToConstant:48.0]
    ]];
    [stack addArrangedSubview:button];
}

- (void)buildRateSettings
{
    [self clearContent];
    NSDictionary *domain = PMReadDomain();
    [self addHeaderWithEyebrow:@"DISPLAY CONTROL" title:@"Tần số quét & FPS"
                      subtitle:@"Đặt mục tiêu toàn cục cho ứng dụng tương thích. Giới hạn iOS và màn hình luôn được ưu tiên."];

    [self addSwitchRows:@[
        @{ @"title": @"Bật ProMotion Control", @"subtitle": @"Cho phép runtime xử lý cấu hình tương thích", @"key": @"Enabled", @"default": @YES },
        @{ @"title": @"Áp dụng cho mọi ứng dụng tương thích", @"subtitle": @"Áp dụng lựa chọn chung cho app được tweak nạp", @"key": @"AdvancedDisplayEnforcement", @"default": @YES },
        @{ @"title": @"Giữ mục tiêu Hz/FPS đã chọn", @"subtitle": @"Giữ mục tiêu trong giới hạn panel, nguồn và nhiệt độ thực tế của iOS", @"key": @"ExactRateEnforcement", @"default": @YES },
        @{ @"title": @"Frame Pacing", @"subtitle": @"Yêu cầu khoảng khung hình qua CADisplayLink tương thích", @"key": @"FramePacing", @"default": @YES }
    ] title:@"Thiết lập toàn cục" toStack:self.contentStack];

    UIStackView *hzCard = [self newCardWithTitle:@"Tần số quét (Hz)" subtitle:@"Chọn mục tiêu 10–244 Hz. Runtime ưu tiên giá trị này trong giới hạn tần số panel và chính sách nguồn/nhiệt của iOS."];
    NSInteger savedHzMode = [domain[@"RefreshMode"] respondsToSelector:@selector(integerValue)] ? [domain[@"RefreshMode"] integerValue] : 0;
    NSInteger savedCustomHz = [domain[@"CustomRefreshRate"] respondsToSelector:@selector(integerValue)] ? [domain[@"CustomRefreshRate"] integerValue] : 60;
    NSInteger displayHz = savedHzMode > 0 ? savedHzMode : (savedHzMode == -1 ? savedCustomHz : 60);
    UILabel *hzValue = PMLabel(savedHzMode == 0 ? @"Auto" : [NSString stringWithFormat:@"%ld Hz", (long)displayHz], 14, UIFontWeightSemibold, PMPrimaryTextColor());
    hzValue.tag = 7282;
    [hzCard addArrangedSubview:hzValue];

    UISlider *hzSlider = [UISlider new];
    hzSlider.translatesAutoresizingMaskIntoConstraints = NO;
    hzSlider.minimumValue = 10.0f;
    hzSlider.maximumValue = 244.0f;
    hzSlider.value = (float)MIN(MAX(displayHz, 10), 244);
    hzSlider.minimumTrackTintColor = PMAccentColor();
    hzSlider.maximumTrackTintColor = PMBorderColor();
    hzSlider.continuous = YES;
    [hzSlider addTarget:self action:@selector(refreshSliderPreviewChanged:) forControlEvents:UIControlEventValueChanged];
    [hzSlider addTarget:self action:@selector(refreshSliderCommitted:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [hzCard addArrangedSubview:hzSlider];
    UIStackView *hzScale = [[UIStackView alloc] initWithFrame:CGRectZero];
    hzScale.axis = UILayoutConstraintAxisHorizontal;
    hzScale.distribution = UIStackViewDistributionEqualSpacing;
    [hzScale addArrangedSubview:PMLabel(@"10", 10, UIFontWeightRegular, PMMutedColor())];
    [hzScale addArrangedSubview:PMLabel(@"60", 10, UIFontWeightRegular, PMMutedColor())];
    [hzScale addArrangedSubview:PMLabel(@"120", 10, UIFontWeightRegular, PMMutedColor())];
    [hzScale addArrangedSubview:PMLabel(@"144", 10, UIFontWeightRegular, PMMutedColor())];
    [hzScale addArrangedSubview:PMLabel(@"244 Hz", 10, UIFontWeightRegular, PMMutedColor())];
    [hzCard addArrangedSubview:hzScale];
    PMCustomChip *customHz = [PMCustomChip buttonWithType:UIButtonTypeSystem];
    PMStyleButton(customHz, [NSString stringWithFormat:@"Tùy chỉnh Hz: %ld Hz", (long)MIN(MAX(savedCustomHz, 10), 244)]);
    customHz.tag = 7286;
    customHz.customKey = @"CustomRefreshRate";
    customHz.modeKey = @"RefreshMode";
    [customHz addTarget:self action:@selector(customTapped:) forControlEvents:UIControlEventTouchUpInside];
    [customHz.heightAnchor constraintEqualToConstant:42.0].active = YES;
    [hzCard addArrangedSubview:customHz];
    [self updateCustomRateChipTag:7286 value:(savedHzMode == -1 ? savedCustomHz : displayHz)
                             unit:@"Hz" selected:(savedHzMode == -1)];

    UIStackView *fpsCard = [self newCardWithTitle:@"Giới hạn FPS" subtitle:@"Chọn preset hoặc nhập tay mục tiêu 10–244 FPS. FPS hiệu lực không vượt tần số panel và giới hạn an toàn của iOS."];
    NSInteger fpsMode = [domain[@"FPSMode"] respondsToSelector:@selector(integerValue)] ? [domain[@"FPSMode"] integerValue] : 0;
    NSInteger savedCustomFPS = [domain[@"CustomFPS"] respondsToSelector:@selector(integerValue)] ? [domain[@"CustomFPS"] integerValue] : 60;
    NSArray<NSDictionary *> *fpsOptions = @[
        @{@"mode": @0, @"title": @"Tự động (theo ứng dụng)", @"subtitle": @"Để ứng dụng/iOS tự quyết định"},
        @{@"mode": @60, @"title": @"60 FPS", @"subtitle": @"Cân bằng hiệu năng và pin"},
        @{@"mode": @90, @"title": @"90 FPS", @"subtitle": @"Tăng độ mượt nếu được hỗ trợ"},
        @{@"mode": @120, @"title": @"120 FPS", @"subtitle": @"Mức cao nếu màn hình hỗ trợ"},
        @{@"mode": @144, @"title": @"144 FPS", @"subtitle": @"Yêu cầu 144 FPS; màn hình có thể giới hạn mức thực tế"},
        @{@"mode": @244, @"title": @"244 FPS", @"subtitle": @"Mục tiêu thử nghiệm; chỉ có tác dụng trong giới hạn phần cứng"}
    ];
    for (NSUInteger i = 0; i < fpsOptions.count; i++) {
        NSDictionary *option = fpsOptions[i];
        NSInteger mode = [option[@"mode"] integerValue];
        [self addFPSOptionWithMode:mode title:option[@"title"] subtitle:option[@"subtitle"] selected:(fpsMode == mode) toStack:fpsCard];
        if (i + 1 < fpsOptions.count) [fpsCard addArrangedSubview:PMSeparator()];
    }

    NSInteger fpsSliderValue = fpsMode > 0 ? fpsMode : (fpsMode == -1 ? savedCustomFPS : 60);
    UILabel *fpsSliderValueLabel = PMLabel([NSString stringWithFormat:@"%ld FPS", (long)MIN(MAX(fpsSliderValue, 10), 244)], 14, UIFontWeightSemibold, PMPrimaryTextColor());
    fpsSliderValueLabel.tag = 7283;
    [fpsCard addArrangedSubview:fpsSliderValueLabel];
    [fpsCard addArrangedSubview:PMLabel(@"Trượt hoặc nhập tay để chọn mục tiêu FPS từ 10 đến 244; runtime áp dụng trong giới hạn thiết bị.", 11, UIFontWeightRegular, PMMutedColor())];
    UISlider *fpsSlider = [UISlider new];
    fpsSlider.translatesAutoresizingMaskIntoConstraints = NO;
    fpsSlider.minimumValue = 10.0f;
    fpsSlider.maximumValue = 244.0f;
    fpsSlider.value = (float)MIN(MAX(fpsSliderValue, 10), 244);
    fpsSlider.minimumTrackTintColor = PMAccentColor();
    fpsSlider.maximumTrackTintColor = PMBorderColor();
    fpsSlider.continuous = YES;
    [fpsSlider addTarget:self action:@selector(fpsSliderPreviewChanged:) forControlEvents:UIControlEventValueChanged];
    [fpsSlider addTarget:self action:@selector(fpsSliderCommitted:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [fpsCard addArrangedSubview:fpsSlider];
    UIStackView *fpsScale = [[UIStackView alloc] initWithFrame:CGRectZero];
    fpsScale.axis = UILayoutConstraintAxisHorizontal;
    fpsScale.distribution = UIStackViewDistributionEqualSpacing;
    [fpsScale addArrangedSubview:PMLabel(@"10", 10, UIFontWeightRegular, PMMutedColor())];
    [fpsScale addArrangedSubview:PMLabel(@"60", 10, UIFontWeightRegular, PMMutedColor())];
    [fpsScale addArrangedSubview:PMLabel(@"120", 10, UIFontWeightRegular, PMMutedColor())];
    [fpsScale addArrangedSubview:PMLabel(@"144", 10, UIFontWeightRegular, PMMutedColor())];
    [fpsScale addArrangedSubview:PMLabel(@"244", 10, UIFontWeightRegular, PMMutedColor())];
    [fpsCard addArrangedSubview:fpsScale];

    PMCustomChip *customFPS = [PMCustomChip buttonWithType:UIButtonTypeSystem];
    PMStyleButton(customFPS, [NSString stringWithFormat:@"Tùy chỉnh FPS: %ld FPS", (long)MIN(MAX(savedCustomFPS, 10), 244)]);
    customFPS.tag = 7287;
    customFPS.customKey = @"CustomFPS";
    customFPS.modeKey = @"FPSMode";
    [customFPS addTarget:self action:@selector(customTapped:) forControlEvents:UIControlEventTouchUpInside];
    [customFPS.heightAnchor constraintEqualToConstant:42.0].active = YES;
    [fpsCard addArrangedSubview:customFPS];
    [self updateCustomRateChipTag:7287 value:fpsSliderValue
                             unit:@"FPS" selected:(fpsMode == -1)];

    NSInteger requestedHz = savedHzMode > 0 ? savedHzMode : (savedHzMode == -1 ? savedCustomHz : 0);
    NSInteger requestedFPS = fpsMode > 0 ? fpsMode : (fpsMode == -1 ? savedCustomFPS : 0);
    NSInteger combinedTarget = requestedHz > 0 && requestedFPS > 0 ? MIN(requestedHz, requestedFPS) : MAX(requestedHz, requestedFPS);
    NSInteger screenMaximum = 60;
    if (@available(iOS 10.3, *)) screenMaximum = MAX(1, UIScreen.mainScreen.maximumFramesPerSecond);
    BOOL exactRate = [domain[@"ExactRateEnforcement"] respondsToSelector:@selector(boolValue)]
        ? [domain[@"ExactRateEnforcement"] boolValue] : YES;
    NSInteger physicalRequest = combinedTarget > 0 ? MIN(combinedTarget, screenMaximum) : 0;
    NSString *selectedHzText = requestedHz > 0 ? [NSString stringWithFormat:@"%ld Hz", (long)requestedHz] : @"Auto Hz";
    NSString *selectedFPSText = requestedFPS > 0 ? [NSString stringWithFormat:@"%ld FPS", (long)requestedFPS] : @"Auto FPS";
    NSString *effectiveSummary = combinedTarget > 0
        ? (exactRate
            ? [NSString stringWithFormat:@"Đã chọn: %@ / %@ · yêu cầu hiệu lực tối đa %ld FPS · màn hình báo tối đa %ld Hz", selectedHzText, selectedFPSText, (long)physicalRequest, (long)screenMaximum]
            : [NSString stringWithFormat:@"Đã chọn: %@ / %@ · mục tiêu kết hợp: %ld FPS · yêu cầu hiệu lực tối đa: %ld FPS · màn hình báo tối đa %ld Hz%@", selectedHzText, selectedFPSText, (long)combinedTarget, (long)physicalRequest, (long)screenMaximum, combinedTarget > screenMaximum ? @" (đã giới hạn theo màn hình)" : @""])
        : [NSString stringWithFormat:@"Đã chọn: %@ / %@ · mục tiêu kết hợp: Auto · màn hình báo tối đa %ld Hz", selectedHzText, selectedFPSText, (long)screenMaximum];
    [self addNote:effectiveSummary toStack:self.contentStack];
    [self addNote:(exactRate
        ? @"Mục tiêu Hz/FPS đã chọn được giữ trong giới hạn panel, Low Power Mode và trạng thái nhiệt thực tế. Khi thiết bị quá nóng hoặc đang tiết kiệm pin, iOS có thể giảm nhịp để bảo vệ phần cứng."
        : @"Giá trị Hz/FPS bạn chọn luôn được lưu và hiển thị riêng. Runtime gửi yêu cầu render trong giới hạn native của màn hình. Trên panel 60 Hz, yêu cầu hiệu lực tối đa vẫn 60 FPS; CADisplayLink không thể đổi tần số quét vật lý.")
        toStack:self.contentStack];
    [self addSwitchRows:@[
        @{ @"title": @"Adaptive FPS", @"subtitle": @"Tôn trọng trạng thái nguồn và giới hạn nhiệt", @"key": @"AdaptiveFPS", @"default": @YES },
        @{ @"title": @"Thermal Guard", @"subtitle": @"Giảm yêu cầu FPS khi trạng thái nhiệt tăng; từ 39°C nhiệt pin coi là áp lực ít nhất mức Fair và hồi dần khi nguội. iOS vẫn tự bảo vệ.", @"key": @"ThermalGuard", @"default": @YES }
    ] title:@"Ổn định và tương thích" toStack:self.contentStack];

    [self addNote:@"Bản cô lập an toàn không đọc nhiệt pin qua IOKit và không áp dụng hook FPS cho app khác. Trạng thái nhiệt chỉ hiển thị theo NSProcessInfo của iOS; iOS vẫn toàn quyền quản lý nhiệt và hiệu năng." toStack:self.contentStack];
}

@end

@implementation PMAppsViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Quản lý ứng dụng";
    self.installedApps = @[];
    self.searchText = @"";
    self.filterIndex = 0;
    self.displayLimit = 60;
    [self buildAppsScreen];
    [self loadInstalledApps];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self refreshResults];
}

- (void)buildAppsScreen
{
    [self clearContent];
    [self addHeaderWithEyebrow:@"APP PROFILES" title:@"Quản lý ứng dụng" subtitle:@"Danh sách gồm ứng dụng người dùng và ứng dụng hệ thống mà LaunchServices công bố. Bật hồ sơ sẽ tự đặt chính sách Cho phép."];

    self.appSearchBar = [UISearchBar new];
    self.appSearchBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.appSearchBar.delegate = self;
    self.appSearchBar.placeholder = @"Tìm kiếm ứng dụng…";
    self.appSearchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.appSearchBar.barTintColor = PMBackgroundColor();
    self.appSearchBar.tintColor = PMAccentColor();
    self.appSearchBar.backgroundImage = [UIImage new];
    self.appSearchBar.searchTextField.backgroundColor = PMCardAltColor();
    self.appSearchBar.searchTextField.textColor = PMPrimaryTextColor();
    self.appSearchBar.searchTextField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"Tìm kiếm theo tên hoặc Bundle ID" attributes:@{NSForegroundColorAttributeName: PMMutedColor()}];
    [self.contentStack addArrangedSubview:self.appSearchBar];
    [self.appSearchBar.heightAnchor constraintEqualToConstant:48].active = YES;

    self.filterControl = [[UISegmentedControl alloc] initWithItems:@[@"Tất cả", @"Đang bật", @"Cho phép", @"Bị chặn"]];
    self.filterControl.translatesAutoresizingMaskIntoConstraints = NO;
    self.filterControl.selectedSegmentIndex = self.filterIndex;
    self.filterControl.selectedSegmentTintColor = PMAccentColor();
    [self.filterControl setTitleTextAttributes:@{NSForegroundColorAttributeName: PMMutedColor(), NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold]} forState:UIControlStateNormal];
    [self.filterControl setTitleTextAttributes:@{NSForegroundColorAttributeName: PMPrimaryTextColor(), NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightBold]} forState:UIControlStateSelected];
    [self.filterControl addTarget:self action:@selector(filterChanged:) forControlEvents:UIControlEventValueChanged];
    [self.contentStack addArrangedSubview:self.filterControl];
    [self.filterControl.heightAnchor constraintEqualToConstant:36].active = YES;

    UIStackView *listCard = [self newCardWithTitle:@"Ứng dụng" subtitle:@"Chạm Thiết lập để mở hồ sơ. App chưa có hồ sơ sẽ được tạo ở trạng thái tắt."];
    self.resultsStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    self.resultsStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.resultsStack.axis = UILayoutConstraintAxisVertical;
    self.resultsStack.spacing = 9;
    [listCard addArrangedSubview:self.resultsStack];

    UIStackView *manualCard = [self newCardWithTitle:@"Thêm thủ công" subtitle:@"Dùng khi LaunchServices không trả về một ứng dụng."];
    UIButton *add = PMButton(@"＋  Thêm ứng dụng theo Bundle ID");
    [add.heightAnchor constraintEqualToConstant:48].active = YES;
    [add addTarget:self action:@selector(addProfile) forControlEvents:UIControlEventTouchUpInside];
    [manualCard addArrangedSubview:add];
    [self addNote:@"Danh sách bao gồm app người dùng và app hệ thống được LaunchServices liệt kê. Bật hồ sơ sẽ ưu tiên Cho phép trong chính sách ProMotion Control; hiệu lực vẫn yêu cầu tweak được nạp, app có CADisplayLink tương thích và iOS không chặn bằng cơ chế hệ thống." toStack:self.contentStack];
    [self refreshResults];
}

- (void)loadInstalledApps
{
    if (self.enumerationStarted) return;
    self.enumerationStarted = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray<NSDictionary *> *apps = PMInstalledAppRecords();
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.installedApps = apps ?: @[];
            self.enumerationFinished = YES;
            [self refreshResults];
        });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.enumerationFinished) return;
        self.enumerationTimedOut = YES;
        [self refreshResults];
    });
}

- (void)searchBar:(__unused UISearchBar *)searchBar textDidChange:(NSString *)searchText
{
    self.searchText = searchText ?: @"";
    self.displayLimit = 60;
    [self refreshResults];
}

- (void)filterChanged:(UISegmentedControl *)sender
{
    self.filterIndex = sender.selectedSegmentIndex;
    self.displayLimit = 60;
    [self refreshResults];
}

- (void)refreshResults
{
    if (!self.resultsStack) return;
    for (UIView *view in [self.resultsStack.arrangedSubviews copy]) {
        [self.resultsStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }

    NSDictionary *domain = PMReadDomain();
    NSDictionary *profiles = [domain[@"AppProfiles"] isKindOfClass:[NSDictionary class]] ? domain[@"AppProfiles"] : @{};
    NSMutableDictionary<NSString *, NSDictionary *> *catalog = [NSMutableDictionary dictionary];
    for (NSDictionary *app in self.installedApps) {
        NSString *bundleID = [app[@"id"] isKindOfClass:[NSString class]] ? app[@"id"] : nil;
        if (bundleID.length) catalog[bundleID] = app;
    }
    [profiles enumerateKeysAndObjectsUsingBlock:^(id key, id value, __unused BOOL *stop) {
        if (![key isKindOfClass:[NSString class]]) return;
        NSDictionary *profile = [value isKindOfClass:[NSDictionary class]] ? value : @{};
        if (!catalog[key]) {
            NSString *name = [profile[@"AppName"] isKindOfClass:[NSString class]] ? profile[@"AppName"] : key;
            catalog[key] = @{@"id": key, @"name": name};
        } else if ([profile[@"AppName"] isKindOfClass:[NSString class]]) {
            NSMutableDictionary *merged = [catalog[key] mutableCopy];
            merged[@"name"] = profile[@"AppName"];
            catalog[key] = merged;
        }
    }];

    NSString *query = [self.searchText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
    NSMutableArray<NSDictionary *> *visible = [NSMutableArray array];
    NSArray<NSString *> *orderedIDs = [[catalog allKeys] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSString *nameA = catalog[a][@"name"] ?: a;
        NSString *nameB = catalog[b][@"name"] ?: b;
        return [nameA localizedCaseInsensitiveCompare:nameB];
    }];
    for (NSString *bundleID in orderedIDs) {
        NSDictionary *app = catalog[bundleID];
        NSDictionary *profile = [profiles[bundleID] isKindOfClass:[NSDictionary class]] ? profiles[bundleID] : @{};
        BOOL hasProfile = profile.count > 0;
        NSInteger policy = [profile[@"InterventionPolicy"] respondsToSelector:@selector(integerValue)]
            ? [profile[@"InterventionPolicy"] integerValue] : 0;
        BOOL enabled = [profile[@"Enabled"] boolValue];
        BOOL hasExplicitEnabled = (profile[@"Enabled"] != nil);
        NSInteger profileHzMode = [profile[@"RefreshMode"] respondsToSelector:@selector(integerValue)] ? [profile[@"RefreshMode"] integerValue] : -2;
        NSInteger profileFPSMode = [profile[@"FPSMode"] respondsToSelector:@selector(integerValue)] ? [profile[@"FPSMode"] integerValue] : -2;
        NSInteger profilePerformanceMode = [profile[@"PerformanceMode"] respondsToSelector:@selector(integerValue)] ? [profile[@"PerformanceMode"] integerValue] : 0;
        BOOL hasExplicitTuning = profileHzMode != -2 || profileFPSMode != -2 || profilePerformanceMode != 0;
        // A profile created only as a placeholder has Enabled=NO but no explicit
        // Block policy or rate choice. It inherits global runtime and must not be
        // displayed as effectively disabled while the tweak applies globally.
        BOOL seedOnlyInheritedProfile = hasExplicitEnabled && !enabled && policy == 0 && !hasExplicitTuning;
        BOOL masterActive = [domain[@"Enabled"] respondsToSelector:@selector(boolValue)] ? [domain[@"Enabled"] boolValue] : YES;
        BOOL framePacingActive = [domain[@"FramePacing"] respondsToSelector:@selector(boolValue)] ? [domain[@"FramePacing"] boolValue] : YES;
        BOOL globalScopeActive = [domain[@"AdvancedDisplayEnforcement"] respondsToSelector:@selector(boolValue)] ? [domain[@"AdvancedDisplayEnforcement"] boolValue] : YES;
        BOOL overrideBlocked = [domain[@"OverrideBlockedApps"] respondsToSelector:@selector(boolValue)] ? [domain[@"OverrideBlockedApps"] boolValue] : YES;
        BOOL globalRuntimeActive = masterActive && framePacingActive && globalScopeActive;
        BOOL runtimeExcluded = [bundleID isEqualToString:@"com.apple.Preferences"] ||
            [bundleID isEqualToString:@"com.apple.springboard"];
        BOOL effectiveEnabled = NO;
        if (runtimeExcluded) {
            effectiveEnabled = NO;
        } else if (hasExplicitEnabled && enabled) {
            effectiveEnabled = YES; // explicit per-app ON wins over stale stored policy
        } else if (globalRuntimeActive && policy == 2 && overrideBlocked) {
            effectiveEnabled = YES; // explicitly shows the global override state
        } else if (seedOnlyInheritedProfile) {
            effectiveEnabled = globalRuntimeActive;
        } else if (policy == 2 || (hasExplicitEnabled && !seedOnlyInheritedProfile)) {
            effectiveEnabled = NO;
        } else {
            effectiveEnabled = globalRuntimeActive;
        }
        if (self.filterIndex == 1 && !effectiveEnabled) continue;
        if (self.filterIndex == 2 && policy != 1) continue;
        if (self.filterIndex == 3 && policy != 2) continue;
        NSString *name = [app[@"name"] isKindOfClass:[NSString class]] ? app[@"name"] : bundleID;
        if (query.length && [name.lowercaseString rangeOfString:query].location == NSNotFound && [bundleID.lowercaseString rangeOfString:query].location == NSNotFound) continue;
        BOOL isSystem = [app[@"isSystem"] boolValue] || [bundleID hasPrefix:@"com.apple."];
        [visible addObject:@{@"id": bundleID, @"name": name, @"isSystem": @(isSystem), @"runtimeExcluded": @(runtimeExcluded), @"hasProfile": @(hasProfile), @"enabled": @(enabled), @"effectiveEnabled": @(effectiveEnabled), @"globalOverrideActive": @(globalRuntimeActive && policy == 2 && overrideBlocked && !runtimeExcluded), @"policy": @(policy), @"profile": profile, @"proxy": app[@"proxy"] ?: [NSNull null]}];
    }

    if (visible.count == 0) {
        NSString *message = nil;
        if (!self.enumerationFinished && !self.enumerationTimedOut && self.installedApps.count == 0 && self.filterIndex == 0) {
            message = @"Đang đọc danh sách ứng dụng ở nền… Bạn vẫn có thể thêm Bundle ID thủ công ngay bên dưới.";
        } else if (self.enumerationTimedOut && self.installedApps.count == 0) {
            message = @"Danh sách tự động chưa phản hồi. Hồ sơ đã lưu và mục thêm Bundle ID vẫn dùng được.";
        } else if (self.filterIndex == 1) {
            message = @"Chưa có ứng dụng nào đang được can thiệp. Mở hồ sơ để bật ứng dụng.";
        } else if (self.filterIndex == 2) {
            message = @"Chưa có app nào được đặt chính sách Cho phép.";
        } else if (self.filterIndex == 3) {
            message = @"Chưa có app nào bị chặn bởi chính sách của ProMotion Control.";
        } else {
            message = @"Không có kết quả phù hợp. Thử từ khóa khác hoặc nhập Bundle ID thủ công.";
        }
        [self.resultsStack addArrangedSubview:PMLabel(message, 12, UIFontWeightRegular, PMMutedColor())];
        return;
    }

    NSUInteger requestedLimit = self.displayLimit > 0 ? self.displayLimit : 60;
    NSUInteger displayCount = MIN(visible.count, requestedLimit);
    for (NSUInteger idx = 0; idx < displayCount; idx++) {
        NSDictionary *app = visible[idx];
        NSString *bundleID = app[@"id"];
        NSString *name = app[@"name"];

        UIStackView *row = [[UIStackView alloc] initWithFrame:CGRectZero];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        row.axis = UILayoutConstraintAxisHorizontal;
        row.alignment = UIStackViewAlignmentCenter;
        row.spacing = 10;

        UIView *iconBack = [UIView new];
        iconBack.translatesAutoresizingMaskIntoConstraints = NO;
        iconBack.backgroundColor = PMCardAltColor();
        iconBack.layer.cornerRadius = 12;
        [iconBack.widthAnchor constraintEqualToConstant:42].active = YES;
        [iconBack.heightAnchor constraintEqualToConstant:42].active = YES;
        UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"app.fill"]];
        icon.translatesAutoresizingMaskIntoConstraints = NO;
        icon.tintColor = PMAccentColor();
        icon.contentMode = UIViewContentModeScaleAspectFit;
        [iconBack addSubview:icon];
        id iconProxy = app[@"proxy"];
        if (iconProxy && iconProxy != [NSNull null]) {
            __weak UIImageView *weakIconView = icon;
            dispatch_async(PMAppIconDecodeQueue(), ^{
                UIImage *resolvedIcon = PMInstalledAppIconForProxy(iconProxy);
                if (!resolvedIcon) return;
                dispatch_async(dispatch_get_main_queue(), ^{
                    UIImageView *targetIcon = weakIconView;
                    if (!targetIcon) return;
                    targetIcon.image = resolvedIcon;
                    targetIcon.tintColor = UIColor.clearColor;
                    targetIcon.contentMode = UIViewContentModeScaleAspectFit;
                });
            });
        }
        [NSLayoutConstraint activateConstraints:@[
            [icon.centerXAnchor constraintEqualToAnchor:iconBack.centerXAnchor],
            [icon.centerYAnchor constraintEqualToAnchor:iconBack.centerYAnchor],
            [icon.widthAnchor constraintEqualToConstant:23], [icon.heightAnchor constraintEqualToConstant:23]
        ]];
        [row addArrangedSubview:iconBack];

        UIStackView *textStack = [[UIStackView alloc] initWithFrame:CGRectZero];
        textStack.translatesAutoresizingMaskIntoConstraints = NO;
        textStack.axis = UILayoutConstraintAxisVertical;
        textStack.spacing = 3;
        [textStack addArrangedSubview:PMLabel(name, 13, UIFontWeightSemibold, PMPrimaryTextColor())];
        [textStack addArrangedSubview:PMLabel(bundleID, 9, UIFontWeightRegular, PMMutedColor())];
        NSInteger policy = [app[@"policy"] integerValue];
        BOOL effectiveEnabled = [app[@"effectiveEnabled"] boolValue];
        BOOL globalOverrideActive = [app[@"globalOverrideActive"] boolValue];
        NSString *state = nil;
        if ([app[@"runtimeExcluded"] boolValue]) state = @"Ứng dụng hệ thống quan trọng · không can thiệp";
        else if ([app[@"enabled"] boolValue] && policy == 2) state = @"● Đang bật · công tắc hồ sơ được ưu tiên";
        else if (globalOverrideActive) state = @"● Đang áp dụng toàn cục · ghi đè hồ sơ Chặn";
        else if (policy == 2) state = @"● Bị chặn bởi chính sách ProMotion";
        else if (policy == 1 && [app[@"enabled"] boolValue]) state = @"● Cho phép · đang bật";
        else if (policy == 1) state = @"Cho phép · chưa bật";
        else if (effectiveEnabled) state = @"● Đang áp dụng toàn cục";
        else if ([app[@"hasProfile"] boolValue]) state = @"Hồ sơ đã lưu · Tắt";
        else state = @"Chưa có hồ sơ";
        UIColor *stateColor = [app[@"runtimeExcluded"] boolValue] ? PMMutedColor() :
            ((policy == 2 && !globalOverrideActive) ? PMRGB(255, 119, 119) :
             (effectiveEnabled ? PMRGB(66, 222, 165) : PMMutedColor()));
        BOOL isSystemApp = [app[@"isSystem"] boolValue];
        NSString *kindLabel = isSystemApp ? @"Ứng dụng hệ thống · runtime phụ thuộc iOS" : @"Ứng dụng đã cài";
        [textStack addArrangedSubview:PMLabel(kindLabel, 9, UIFontWeightRegular, isSystemApp ? PMRGB(105, 190, 255) : PMMutedColor())];
        [textStack addArrangedSubview:PMLabel(state, 10, UIFontWeightMedium, stateColor)];
        [row addArrangedSubview:textStack];
        [textStack setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

        PMRouteButton *configure = [PMRouteButton buttonWithType:UIButtonTypeSystem];
        PMStyleButton(configure, @"Thiết lập  ›");
        configure.route = @"profile";
        configure.accessibilityLabel = [NSString stringWithFormat:@"Thiết lập %@", name];
        configure.accessibilityHint = @"Mở hồ sơ Hz/FPS riêng cho ứng dụng này";
        configure.bundleID = bundleID;
        configure.appName = name;
        [configure.widthAnchor constraintEqualToConstant:88].active = YES;
        [configure.heightAnchor constraintEqualToConstant:42].active = YES;
        [configure addTarget:self action:@selector(routeTapped:) forControlEvents:UIControlEventTouchUpInside];
        [row addArrangedSubview:configure];
        [self.resultsStack addArrangedSubview:row];
        if (idx + 1 < displayCount) [self.resultsStack addArrangedSubview:PMSeparator()];
    }
    if (visible.count > displayCount) {
        [self.resultsStack addArrangedSubview:PMLabel([NSString stringWithFormat:@"Đang hiển thị %lu/%lu ứng dụng.", (unsigned long)displayCount, (unsigned long)visible.count], 11, UIFontWeightRegular, PMMutedColor())];
        UIButton *more = PMButton([NSString stringWithFormat:@"Hiển thị thêm %lu ứng dụng", (unsigned long)MIN((NSUInteger)60, visible.count - displayCount)]);
        [more.heightAnchor constraintEqualToConstant:44].active = YES;
        [more addTarget:self action:@selector(showMoreResults:) forControlEvents:UIControlEventTouchUpInside];
        [self.resultsStack addArrangedSubview:more];
    }
}

- (void)showMoreResults:(UIButton *)sender
{
    (void)sender;
    self.displayLimit = (self.displayLimit > NSUIntegerMax - 60) ? NSUIntegerMax : self.displayLimit + 60;
    [self refreshResults];
}

- (void)addProfile
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Thêm hồ sơ ứng dụng"
                                                                   message:@"Hồ sơ mới sẽ ở trạng thái TẮT cho đến khi bạn bật thủ công."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Bundle ID · com.example.app";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.keyboardType = UIKeyboardTypeURL;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Tên hiển thị (không bắt buộc)";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Tạo hồ sơ" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        NSString *bundleID = [alert.textFields[0].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *name = [alert.textFields[1].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
        BOOL valid = bundleID.length >= 3 && [bundleID containsString:@"."] && [bundleID rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
        if (!valid) {
            UIAlertController *bad = [UIAlertController alertControllerWithTitle:@"Bundle ID không hợp lệ" message:@"Ví dụ: com.example.app" preferredStyle:UIAlertControllerStyleAlert];
            [bad addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:bad animated:YES completion:nil];
            return;
        }
        if (PMReadProfile(bundleID).count > 0) {
            UIAlertController *exists = [UIAlertController alertControllerWithTitle:@"Hồ sơ đã tồn tại" message:@"Mở hồ sơ hiện tại để chỉnh sửa." preferredStyle:UIAlertControllerStyleAlert];
            [exists addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:exists animated:YES completion:nil];
            return;
        }
        NSDictionary *newProfile = @{@"AppName": name.length ? name : bundleID,
                                     @"Enabled": @NO, @"InterventionPolicy": @0, @"PerformanceMode": @0,
                                     @"RefreshMode": @(-2), @"FPSMode": @(-2),
                                     @"CustomRefreshRate": @60, @"CustomFPS": @60};
        BOOL ok = PMWriteProfile(bundleID, newProfile);
        [self refreshResults];
        if (!ok) [self showWriteFailure];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

@implementation PMAppProfileViewController

- (instancetype)initWithBundleID:(NSString *)bundleID
{
    self = [super initWithNibName:nil bundle:nil];
    if (self) _bundleID = [bundleID copy];
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    NSDictionary *profile = PMReadProfile(self.bundleID);
    self.title = [profile[@"AppName"] isKindOfClass:[NSString class]] ? profile[@"AppName"] : self.bundleID;
    [self buildProfile];
}

- (void)buildProfile
{
    [self clearContent];
    NSDictionary *profile = PMReadProfile(self.bundleID);
    NSString *name = [profile[@"AppName"] isKindOfClass:[NSString class]] ? profile[@"AppName"] : self.bundleID;
    [self addHeaderWithEyebrow:@"PER-APP PROFILE" title:name subtitle:self.bundleID];

    UIStackView *policyCard = [self newCardWithTitle:@"Chính sách tương thích" subtitle:@"Chặn ưu tiên bình thường; tuỳ chọn toàn cục áp dụng hồ sơ bị chặn có thể ghi đè."];
    UISegmentedControl *policyControl = [[UISegmentedControl alloc] initWithItems:@[@"Tự động", @"Cho phép", @"Chặn"]];
    policyControl.translatesAutoresizingMaskIntoConstraints = NO;
    policyControl.selectedSegmentTintColor = PMAccentColor();
    NSInteger savedPolicy = [profile[@"InterventionPolicy"] respondsToSelector:@selector(integerValue)] ? [profile[@"InterventionPolicy"] integerValue] : 0;
    policyControl.selectedSegmentIndex = (savedPolicy >= 0 && savedPolicy <= 2) ? savedPolicy : 0;
    [policyControl setTitleTextAttributes:@{NSForegroundColorAttributeName: PMMutedColor(), NSFontAttributeName: [UIFont systemFontOfSize:11 weight:UIFontWeightMedium]} forState:UIControlStateNormal];
    [policyControl setTitleTextAttributes:@{NSForegroundColorAttributeName: PMPrimaryTextColor(), NSFontAttributeName: [UIFont systemFontOfSize:11 weight:UIFontWeightBold]} forState:UIControlStateSelected];
    [policyControl addTarget:self action:@selector(interventionPolicyChanged:) forControlEvents:UIControlEventValueChanged];
    [policyCard addArrangedSubview:policyControl];
    [self addNote:@"Tự động dùng công tắc hồ sơ/toàn cục. Cho phép đưa app vào danh sách được phép nhưng vẫn cần tweak được nạp và API tương thích. Chặn ngăn ProMotion Control sửa CADisplayLink của app này; không chặn mở app và không thể bỏ qua quy tắc loader/iOS." toStack:policyCard];

    [self addSwitchRows:@[@{@"title": @"Bật can thiệp riêng cho ứng dụng", @"subtitle": @"Bật để đặt Chính sách = Cho phép. Tắt đặt Chính sách = Chặn; nếu OverrideBlockedApps đang bật, cấu hình toàn cục vẫn có thể áp dụng.", @"key": [NSString stringWithFormat:@"profile|%@|Enabled", self.bundleID], @"value": profile[@"Enabled"] ?: @NO}] title:@"Trạng thái hồ sơ" toStack:self.contentStack];

    UIStackView *modeCard = [self newCardWithTitle:@"Chế độ ưu tiên" subtitle:@"Chỉ thay đổi mục tiêu khung hình tương thích; không ép xung CPU/GPU."];
    UISegmentedControl *performanceControl = [[UISegmentedControl alloc] initWithItems:@[@"Tự động", @"Hiệu năng", @"Cân bằng", @"Tiết kiệm"]];
    performanceControl.translatesAutoresizingMaskIntoConstraints = NO;
    performanceControl.selectedSegmentTintColor = PMAccentColor();
    NSInteger savedPerformance = [profile[@"PerformanceMode"] respondsToSelector:@selector(integerValue)] ? [profile[@"PerformanceMode"] integerValue] : 0;
    performanceControl.selectedSegmentIndex = (savedPerformance >= 0 && savedPerformance <= 3) ? savedPerformance : 0;
    [performanceControl setTitleTextAttributes:@{NSForegroundColorAttributeName: PMMutedColor(), NSFontAttributeName: [UIFont systemFontOfSize:10 weight:UIFontWeightMedium]} forState:UIControlStateNormal];
    [performanceControl setTitleTextAttributes:@{NSForegroundColorAttributeName: PMPrimaryTextColor(), NSFontAttributeName: [UIFont systemFontOfSize:10 weight:UIFontWeightBold]} forState:UIControlStateSelected];
    [performanceControl addTarget:self action:@selector(perAppPerformanceChanged:) forControlEvents:UIControlEventValueChanged];
    [modeCard addArrangedSubview:performanceControl];
    [self addNote:@"Hiệu năng yêu cầu mức cao nhất mà màn hình/API cho phép; Cân bằng giới hạn tối đa 60 FPS; Tiết kiệm giới hạn tối đa 30 FPS. iOS vẫn quản lý nhiệt và giới hạn phần cứng." toStack:modeCard];

    [self addModePickerForKey:@"RefreshMode" title:@"Hz riêng cho ứng dụng" subtitle:@"Dùng chung kế thừa lựa chọn toàn cục · Auto để iOS tự chọn" bundleID:self.bundleID];
    [self addModePickerForKey:@"FPSMode" title:@"FPS riêng cho ứng dụng" subtitle:@"Đây là mục tiêu yêu cầu, không phải FPS đo thực tế" bundleID:self.bundleID];
    [self addNote:@"Hồ sơ chỉ tác động khi app dùng CADisplayLink tương thích và tweak được loader nạp. Không thể đổi số lõi, RAM, băng thông bộ nhớ hoặc giá trị maximumFramesPerSecond mà phần cứng báo cáo." toStack:self.contentStack];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self refreshModeChips];
}

- (void)interventionPolicyChanged:(UISegmentedControl *)sender
{
    NSInteger policy = sender.selectedSegmentIndex;
    NSDictionary *changes = nil;
    if (policy == 1) {
        changes = @{@"InterventionPolicy": @1, @"Enabled": @YES};
    } else if (policy == 2) {
        changes = @{@"InterventionPolicy": @2, @"Enabled": @NO};
    } else {
        changes = @{@"InterventionPolicy": @0, @"Enabled": [NSNull null]};
    }
    if (!PMWriteProfile(self.bundleID, changes)) [self showWriteFailure];
    [self buildProfile];
}

- (void)perAppPerformanceChanged:(UISegmentedControl *)sender
{
    if (!PMWriteProfile(self.bundleID, @{@"PerformanceMode": @(sender.selectedSegmentIndex)})) {
        [self showWriteFailure];
    }
}

- (void)switchChanged:(UISwitch *)sender
{
    NSString *identifier = sender.accessibilityIdentifier;
    NSArray *parts = [identifier componentsSeparatedByString:@"|"];
    if (parts.count >= 3 && [parts[0] isEqualToString:@"profile"]) {
        // Turning the per-app switch on automatically sets policy=Allow and enables
        // the master runtime/frame-pacing switches. No stale Blocked value may defeat it.
        BOOL ok = PMWriteProfile(parts[1], @{parts[2]: @(sender.isOn)});
        if (!ok) {
            [self showWriteFailure];
        } else if ([parts[2] isEqualToString:@"Enabled"]) {
            // Refresh the policy chip after enabling: PMWriteProfile normalizes
            // an explicitly enabled profile to Allow, so the UI must show it.
            __weak typeof(self) weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (self && self.isViewLoaded && self.view.window) [self buildProfile];
            });
        }
    } else {
        [super switchChanged:sender];
    }
}

@end

@implementation PMAdvancedViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Hiệu năng nâng cao";
    [self buildAdvanced];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self buildAdvanced];
}

- (void)performancePresetChanged:(UISegmentedControl *)sender
{
    NSInteger preset = sender.selectedSegmentIndex;
    NSDictionary *changes = nil;
    if (preset == 0) {
        changes = @{@"PerformancePreset": @0, @"Enabled": @YES, @"FramePacing": @YES,
                    @"AdaptiveFPS": @YES, @"ThermalGuard": @YES, @"BatterySaver": @NO,
                    @"AppCompatibility": @NO, @"BackgroundReduction": @YES};
    } else if (preset == 1) {
        changes = @{@"PerformancePreset": @1, @"Enabled": @YES, @"FramePacing": @YES,
                    @"AdaptiveFPS": @NO, @"ThermalGuard": @YES, @"BatterySaver": @NO,
                    @"AppCompatibility": @NO, @"BackgroundReduction": @NO};
    } else {
        changes = @{@"PerformancePreset": @2, @"Enabled": @YES, @"FramePacing": @YES,
                    @"AdaptiveFPS": @YES, @"ThermalGuard": @YES, @"BatterySaver": @YES,
                    @"AppCompatibility": @YES, @"BackgroundReduction": @YES};
    }
    if (!PMWriteDomainChanges(changes)) [self showWriteFailure];
    [self buildAdvanced];
}

- (void)buildAdvanced
{
    [self clearContent];
    NSDictionary *domain = PMReadDomain();
    [self addHeaderWithEyebrow:@"TUNING & SAFETY" title:@"Hiệu năng nâng cao" subtitle:@"Chọn chính sách rồi tinh chỉnh các giới hạn runtime. iOS vẫn quản lý nhiệt và phần cứng."];

    UIStackView *modeCard = [self newCardWithTitle:@"Chế độ hiệu năng" subtitle:@"Các chế độ là preset cho các công tắc runtime bên dưới, không phải ép xung phần cứng."];
    UISegmentedControl *preset = [[UISegmentedControl alloc] initWithItems:@[@"Cân bằng", @"Hiệu năng", @"Tiết kiệm pin"]];
    preset.translatesAutoresizingMaskIntoConstraints = NO;
    preset.selectedSegmentTintColor = PMAccentColor();
    [preset setTitleTextAttributes:@{NSForegroundColorAttributeName: PMMutedColor(), NSFontAttributeName: [UIFont systemFontOfSize:10 weight:UIFontWeightMedium]} forState:UIControlStateNormal];
    [preset setTitleTextAttributes:@{NSForegroundColorAttributeName: PMPrimaryTextColor(), NSFontAttributeName: [UIFont systemFontOfSize:10 weight:UIFontWeightBold]} forState:UIControlStateSelected];
    NSInteger savedPreset = [domain[@"PerformancePreset"] respondsToSelector:@selector(integerValue)] ? [domain[@"PerformancePreset"] integerValue] : ([domain[@"BatterySaver"] boolValue] ? 2 : 0);
    preset.selectedSegmentIndex = MIN(MAX(savedPreset, 0), 2);
    [preset addTarget:self action:@selector(performancePresetChanged:) forControlEvents:UIControlEventValueChanged];
    [modeCard addArrangedSubview:preset];

    [self addSwitchRows:@[
        @{@"title": @"Tự động điều chỉnh FPS", @"subtitle": @"Tôn trọng chế độ nguồn và trạng thái nhiệt", @"key": @"AdaptiveFPS", @"default": @YES},
        @{@"title": @"Thermal Guard", @"subtitle": @"Giảm yêu cầu FPS khi nhiệt tăng; từ 39°C nhiệt pin coi là áp lực ít nhất mức Fair và hồi dần khi nguội. iOS vẫn tự bảo vệ", @"key": @"ThermalGuard", @"default": @YES},
        @{@"title": @"Giảm tải khi chạy nền", @"subtitle": @"Sau 5 phút app ở nền liên tục, khôi phục FPS gốc và dừng ghi đè của tweak; không đóng app. iOS có thể suspend sớm hơn.", @"key": @"BackgroundReduction", @"default": @YES}
    ] title:@"Tự động điều chỉnh" toStack:self.contentStack];

    [self addSwitchRows:@[
        @{@"title": @"Frame Pacing", @"subtitle": @"Yêu cầu khoảng CADisplayLink đã chọn", @"key": @"FramePacing", @"default": @YES},
        @{@"title": @"Conflict Guard", @"subtitle": @"Tránh ghi đè khi phát hiện thay đổi xung đột", @"key": @"ConflictGuard", @"default": @YES},
        @{@"title": @"Stutter Fix", @"subtitle": @"Cho phép khoảng thích ứng khi mục tiêu cao", @"key": @"StutterFix", @"default": @YES},
        @{@"title": @"App Stability", @"subtitle": @"Chế độ tương thích cho CADisplayLink", @"key": @"AppStabilityFix", @"default": @YES},
        @{@"title": @"Tối ưu khi quay màn hình", @"subtitle": @"Giữ mục tiêu FPS đã chọn khi quay; giảm ghi chẩn đoán phụ, iOS vẫn tự điều tiết nhiệt", @"key": @"ScreenRecordingFix", @"default": @YES}
    ] title:@"Tùy chỉnh nâng cao" toStack:self.contentStack];

    [self addSwitchRows:@[
        @{@"title": @"Áp dụng cho mọi app UIKit tương thích", @"subtitle": @"Bao gồm app người dùng và app hệ thống có bundle được hỗ trợ; Settings/SpringBoard vẫn bị loại trừ", @"key": @"AdvancedDisplayEnforcement", @"default": @YES},
        @{@"title": @"Ghi đè hồ sơ bị chặn", @"subtitle": @"Ghi đè trạng thái Chặn do ProMotion Control đặt khi áp dụng toàn cục; không vượt sandbox, loader, DRM hoặc anti-cheat", @"key": @"OverrideBlockedApps", @"default": @YES},
        @{@"title": @"Tiết kiệm pin", @"subtitle": @"Giới hạn mục tiêu khung hình theo chính sách runtime", @"key": @"BatterySaver", @"default": @NO},
        @{@"title": @"Giảm tải dashboard khi sạc", @"subtitle": @"Giảm tần suất lấy mẫu/chẩn đoán phụ; không hạ Hz/FPS đã chọn", @"key": @"ChargingOptimization", @"default": @NO}
    ] title:@"Tương thích & nguồn điện" toStack:self.contentStack];

    [self addNote:@"Khi cắm sạc, ProMotion Control không tự hạ mục tiêu Hz/FPS đã chọn. Giảm tải khi sạc chỉ làm chậm lấy mẫu dashboard/chẩn đoán phụ; mục tiêu vẫn bị giới hạn bởi panel thực tế. iOS vẫn có thể tự điều tiết khi nhiệt độ cao hoặc Low Power Mode bật. Không có cách an toàn để ép xung CPU/GPU hoặc buộc mọi ứng dụng đạt FPS cố định." toStack:self.contentStack];
}
@end


@implementation PMChipInfoViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Thông số";
    self.selectedInfoIndex = 0;
    UIDevice.currentDevice.batteryMonitoringEnabled = YES;
    [self buildChipInfo];
    [self refreshLiveHardwareMetrics:nil];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self refreshLiveHardwareMetrics:nil];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    if (!self.metricsTimer && self.isViewLoaded && self.view.window) {
        self.metricsTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
            selector:@selector(refreshLiveHardwareMetrics:) userInfo:nil repeats:YES];
    }
    [self refreshLiveHardwareMetrics:nil];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [self.metricsTimer invalidate];
    self.metricsTimer = nil;
    [super viewWillDisappear:animated];
}

- (UILabel *)addHardwareRow:(NSString *)title value:(NSString *)value toCard:(UIStackView *)card
{
    UIStackView *row = [[UIStackView alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 10.0;
    UILabel *keyLabel = PMLabel(title, 12, UIFontWeightMedium, PMMutedColor());
    keyLabel.numberOfLines = 2;
    UILabel *valueLabel = PMLabel(value ?: @"Không khả dụng", 12, UIFontWeightSemibold, PMPrimaryTextColor());
    valueLabel.numberOfLines = 0;
    valueLabel.textAlignment = NSTextAlignmentRight;
    [keyLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [valueLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [row addArrangedSubview:keyLabel];
    [row addArrangedSubview:valueLabel];
    [card addArrangedSubview:row];
    [keyLabel.widthAnchor constraintGreaterThanOrEqualToConstant:95.0].active = YES;
    if (card.arrangedSubviews.count > 1) [card insertArrangedSubview:PMSeparator() atIndex:card.arrangedSubviews.count - 1];
    return valueLabel;
}

- (void)chipTabChanged:(UISegmentedControl *)sender
{
    self.selectedInfoIndex = sender.selectedSegmentIndex;
    [self buildChipInfo];
    [self refreshLiveHardwareMetrics:nil];
}

- (void)buildChipInfo
{
    [self clearContent];
    self.cpuLoadValueLabel = nil;
    self.processMemoryValueLabel = nil;
    self.batteryValueLabel = nil;
    self.thermalValueLabel = nil;

    NSString *machine = PMHardwareMachineIdentifier();
    NSString *deviceName = PMFriendlyDeviceName(machine);
    NSString *chipName = PMEstimatedSoCName(machine);
    [self addHeaderWithEyebrow:@"DEVICE HARDWARE" title:@"Thông tin chip & thiết bị"
        subtitle:[NSString stringWithFormat:@"%@ · đọc dữ liệu từ thiết bị hiện tại", deviceName]];

    self.infoSegments = [[UISegmentedControl alloc] initWithItems:@[@"Tổng quan", @"CPU", @"GPU", @"Thông tin khác"]];
    self.infoSegments.translatesAutoresizingMaskIntoConstraints = NO;
    self.infoSegments.selectedSegmentIndex = MIN(MAX(self.selectedInfoIndex, 0), 3);
    self.infoSegments.selectedSegmentTintColor = PMAccentColor();
    self.infoSegments.backgroundColor = PMCardAltColor();
    [self.infoSegments setTitleTextAttributes:@{NSForegroundColorAttributeName: PMPrimaryTextColor(),
        NSFontAttributeName: [UIFont systemFontOfSize:10 weight:UIFontWeightMedium]} forState:UIControlStateNormal];
    [self.infoSegments addTarget:self action:@selector(chipTabChanged:) forControlEvents:UIControlEventValueChanged];
    UIStackView *segmentCard = [self newCardWithTitle:nil subtitle:nil];
    [segmentCard addArrangedSubview:self.infoSegments];

    BOOL coresOK = NO;
    uint64_t coreCount = PMReadSysctlUInt64("hw.ncpu", &coresOK);
    NSString *cores = coresOK ? [NSString stringWithFormat:@"%llu logical cores", (unsigned long long)coreCount] : @"Không khả dụng";
    unsigned long long memoryBytes = (unsigned long long)NSProcessInfo.processInfo.physicalMemory;
    NSString *ramTotal = memoryBytes ? PMHumanBytes(memoryBytes) : @"Không khả dụng";
    id<MTLDevice> metalDevice = MTLCreateSystemDefaultDevice();
    NSString *gpuName = (metalDevice && metalDevice.name.length) ? metalDevice.name : @"Không khả dụng qua Metal";
    NSString *osVersion = UIDevice.currentDevice.systemVersion ?: @"Không rõ";
    NSInteger maxHz = (NSInteger)UIScreen.mainScreen.maximumFramesPerSecond;
    NSString *displayRate = maxHz > 0 ? [NSString stringWithFormat:@"Tối đa danh nghĩa %ld Hz", (long)maxHz] : @"Không khả dụng";

    if (self.selectedInfoIndex == 0) {
        UIStackView *identity = [self newCardWithTitle:@"Thông tin chung" subtitle:@"Tên SoC được suy luận từ mã máy nếu có bản ánh xạ; iOS không công khai tên chip trực tiếp."];
        [self addHardwareRow:@"Thiết bị" value:deviceName toCard:identity];
        [self addHardwareRow:@"Tên chip / SoC" value:chipName toCard:identity];
        [self addHardwareRow:@"Mã thiết bị" value:machine toCard:identity];
        [self addHardwareRow:@"Số lõi CPU" value:cores toCard:identity];
        [self addHardwareRow:@"RAM vật lý tổng" value:ramTotal toCard:identity];
        [self addHardwareRow:@"GPU / Metal" value:gpuName toCard:identity];
        [self addHardwareRow:@"Màn hình" value:displayRate toCard:identity];
        [self addHardwareRow:@"Phiên bản iOS" value:osVersion toCard:identity];

        UIStackView *live = [self newCardWithTitle:@"Trạng thái xử lý trực tiếp" subtitle:@"Cập nhật theo chu kỳ 1 giây khi trang này mở."];
        self.cpuLoadValueLabel = [self addHardwareRow:@"Tải CPU toàn hệ thống" value:@"Đang đo…" toCard:live];
        self.processMemoryValueLabel = [self addHardwareRow:@"RAM của ProMotion Control" value:@"Đang đo…" toCard:live];
        self.batteryValueLabel = [self addHardwareRow:@"Pin" value:@"Đang đọc…" toCard:live];
        self.thermalValueLabel = [self addHardwareRow:@"Trạng thái nhiệt iOS" value:PMThermalStateLabel() toCard:live];
    } else if (self.selectedInfoIndex == 1) {
        UIStackView *cpu = [self newCardWithTitle:@"Bộ xử lý CPU" subtitle:@"Một số chi tiết tần số bị iOS ẩn; số liệu không có quyền đọc sẽ được báo rõ."];
        [self addHardwareRow:@"Kiến trúc ứng dụng" value:(sizeof(void *) == 8 ? @"64-bit" : @"32-bit") toCard:cpu];
        [self addHardwareRow:@"Số lõi logic" value:cores toCard:cpu];
        self.cpuLoadValueLabel = [self addHardwareRow:@"Tải CPU toàn hệ thống" value:@"Đang đo…" toCard:cpu];
        [self addHardwareRow:@"Tần số CPU hiện tại" value:PMFrequencyLabel("hw.cpufrequency") toCard:cpu];
        [self addHardwareRow:@"Tần số CPU tối đa" value:PMFrequencyLabel("hw.cpufrequency_max") toCard:cpu];
        self.processMemoryValueLabel = [self addHardwareRow:@"RAM tiến trình app" value:@"Đang đo…" toCard:cpu];
        [self addNote:@"Tần số CPU không phải API công khai ổn định trên mọi phiên bản iOS; nếu không đọc được, ứng dụng không hiển thị giá trị giả." toStack:self.contentStack];
    } else if (self.selectedInfoIndex == 2) {
        UIStackView *gpu = [self newCardWithTitle:@"Bộ xử lý đồ họa GPU" subtitle:@"Thông tin nhận diện qua Metal trên thiết bị đang dùng."];
        [self addHardwareRow:@"Thiết bị GPU" value:gpuName toCard:gpu];
        [self addHardwareRow:@"Metal" value:(metalDevice ? @"Được hỗ trợ" : @"Không khả dụng") toCard:gpu];
        [self addHardwareRow:@"Số lõi GPU" value:@"Không được iOS công khai ổn định" toCard:gpu];
        [self addHardwareRow:@"Xung GPU hiện tại" value:@"Không có API công khai ổn định" toCard:gpu];
        [self addHardwareRow:@"Tên SoC" value:chipName toCard:gpu];
        [self addNote:@"Tên thiết bị Metal là thông tin hệ thống trả về; số lõi và xung GPU không được suy đoán." toStack:self.contentStack];
    } else {
        UIStackView *other = [self newCardWithTitle:@"Thông tin thiết bị khác" subtitle:nil];
        [self addHardwareRow:@"Model phần cứng" value:machine toCard:other];
        [self addHardwareRow:@"Phiên bản iOS" value:osVersion toCard:other];
        [self addHardwareRow:@"RAM vật lý tổng" value:ramTotal toCard:other];
        [self addHardwareRow:@"Tần số quét tối đa của màn hình" value:displayRate toCard:other];
        self.batteryValueLabel = [self addHardwareRow:@"Pin" value:@"Đang đọc…" toCard:other];
        self.thermalValueLabel = [self addHardwareRow:@"Trạng thái nhiệt" value:PMThermalStateLabel() toCard:other];
        NSDictionary *fs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:NSHomeDirectory() error:nil];
        uint64_t diskTotal = [fs[NSFileSystemSize] respondsToSelector:@selector(unsignedLongLongValue)] ? [fs[NSFileSystemSize] unsignedLongLongValue] : 0;
        uint64_t diskFree = [fs[NSFileSystemFreeSize] respondsToSelector:@selector(unsignedLongLongValue)] ? [fs[NSFileSystemFreeSize] unsignedLongLongValue] : 0;
        [self addHardwareRow:@"Dung lượng lưu trữ" value:PMHumanBytes(diskTotal) toCard:other];
        [self addHardwareRow:@"Dung lượng trống" value:PMHumanBytes(diskFree) toCard:other];
        [self addNote:@"RAM vật lý tổng lấy từ ProcessInfo; dung lượng ổ đĩa phụ thuộc vùng lưu trữ mà tiến trình được quyền nhìn thấy." toStack:self.contentStack];
    }
    [self addNote:@"Mục tiêu Hz/FPS đọc từ cấu hình đã lưu. Tốc độ thực tế phụ thuộc màn hình, nhiệt độ, chế độ nguồn, API của từng ứng dụng và runtime đã được nạp." toStack:self.contentStack];
}

- (void)refreshLiveHardwareMetrics:(NSTimer *)timer
{
    (void)timer;
    if (![NSThread isMainThread]) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf refreshLiveHardwareMetrics:nil]; });
        return;
    }
    if (!self.isViewLoaded || !self.view.window) return;
    if (!self.cpuUsageSamplePending) {
        self.cpuUsageSamplePending = YES;
        __weak typeof(self) weakSelf = self;
        dispatch_async(PMSystemCPUStatsQueue(), ^{
            double sampledCPU = PMSystemCPUUsagePercent();
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (!self) return;
                self.cpuUsageSamplePending = NO;
                if (!self.isViewLoaded || !self.view.window) return;
                NSString *cpuText = sampledCPU >= 0.0 ? [NSString stringWithFormat:@"%.0f%%", sampledCPU] :
                    (sampledCPU <= -2.0 ? @"Không khả dụng" : @"Đang đo mẫu đầu…");
                if (self.cpuLoadValueLabel) self.cpuLoadValueLabel.text = cpuText;
            });
        });
    }
    if (self.processMemoryValueLabel) self.processMemoryValueLabel.text = PMProcessResidentMemoryLabel();
    if (self.batteryValueLabel) {
        float level = UIDevice.currentDevice.batteryLevel;
        NSString *state = @"";
        switch (UIDevice.currentDevice.batteryState) {
            case UIDeviceBatteryStateCharging: state = @" · Đang sạc"; break;
            case UIDeviceBatteryStateFull: state = @" · Đã đầy"; break;
            case UIDeviceBatteryStateUnplugged: state = @" · Đang dùng pin"; break;
            default: break;
        }
        self.batteryValueLabel.text = level >= 0.0f ? [NSString stringWithFormat:@"%.0f%%%@", level * 100.0f, state] : @"Không khả dụng";
    }
    if (self.thermalValueLabel) self.thermalValueLabel.text = PMThermalStateLabel();
}

@end

@implementation PMSettingsViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Cài đặt";
    [self buildSettings];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self buildSettings];
}

- (void)buildSettings
{
    PMRefreshUIOptions();
    [self clearContent];
    [self addHeaderWithEyebrow:@"GENERAL SETTINGS" title:@"Cài đặt chung" subtitle:@"Trang cài đặt trong app · không nằm trong Settings của iOS"];

    UIStackView *appearance = [self newCardWithTitle:@"Giao diện" subtitle:@"Tuỳ chỉnh hiển thị ứng dụng"];
    UIStackView *themeRow = [[UIStackView alloc] initWithFrame:CGRectZero];
    themeRow.axis = UILayoutConstraintAxisHorizontal;
    themeRow.alignment = UIStackViewAlignmentCenter;
    themeRow.spacing = 12;
    UIImageView *themeIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"moon.stars.fill"]];
    themeIcon.translatesAutoresizingMaskIntoConstraints = NO;
    themeIcon.tintColor = PMAccentColor();
    [themeIcon.widthAnchor constraintEqualToConstant:24].active = YES;
    [themeIcon.heightAnchor constraintEqualToConstant:24].active = YES;
    [themeRow addArrangedSubview:themeIcon];
    UIStackView *themeText = [[UIStackView alloc] initWithFrame:CGRectZero];
    themeText.axis = UILayoutConstraintAxisVertical;
    themeText.spacing = 3;
    [themeText addArrangedSubview:PMLabel(@"Chủ đề", 13, UIFontWeightSemibold, PMPrimaryTextColor())];
    [themeText addArrangedSubview:PMLabel(PMLightThemeSelected ? @"Giao diện sáng" : @"Giao diện tối · tím neon", 11, UIFontWeightRegular, PMMutedColor())];
    [themeRow addArrangedSubview:themeText];
    [themeRow addArrangedSubview:PMLabel(PMLightThemeSelected ? @"Sáng" : @"Tối", 11, UIFontWeightSemibold, PMAccentColor())];
    themeRow.userInteractionEnabled = YES;
    themeRow.accessibilityLabel = @"Chủ đề";
    themeRow.accessibilityHint = @"Chạm để đổi giao diện sáng hoặc tối";
    [themeRow addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(chooseTheme:)]];
    [appearance addArrangedSubview:themeRow];
    [appearance addArrangedSubview:PMSeparator()];

    UIStackView *languageRow = [[UIStackView alloc] initWithFrame:CGRectZero];
    languageRow.axis = UILayoutConstraintAxisHorizontal;
    languageRow.alignment = UIStackViewAlignmentCenter;
    languageRow.spacing = 12;
    UIImageView *languageIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"character.bubble"]];
    languageIcon.translatesAutoresizingMaskIntoConstraints = NO;
    languageIcon.tintColor = PMAccentColor();
    [languageIcon.widthAnchor constraintEqualToConstant:24].active = YES;
    [languageIcon.heightAnchor constraintEqualToConstant:24].active = YES;
    [languageRow addArrangedSubview:languageIcon];
    UIStackView *languageText = [[UIStackView alloc] initWithFrame:CGRectZero];
    languageText.axis = UILayoutConstraintAxisVertical;
    languageText.spacing = 3;
    [languageText addArrangedSubview:PMLabel(@"Ngôn ngữ", 13, UIFontWeightSemibold, PMPrimaryTextColor())];
    [languageText addArrangedSubview:PMLabel(@"Ngôn ngữ giao diện hiện có", 11, UIFontWeightRegular, PMMutedColor())];
    [languageRow addArrangedSubview:languageText];
    [languageRow addArrangedSubview:PMLabel(PMEnglishSelected ? @"Tiếng Anh" : @"Tiếng Việt", 11, UIFontWeightSemibold, PMAccentColor())];
    languageRow.userInteractionEnabled = YES;
    languageRow.accessibilityLabel = @"Ngôn ngữ";
    languageRow.accessibilityHint = @"Chạm để chọn Tiếng Việt hoặc English";
    [languageRow addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(chooseLanguage:)]];
    [appearance addArrangedSubview:languageRow];

    [self addSwitchRows:@[
        @{ @"title": @"Bật ProMotion Control", @"subtitle": @"Bật/tắt các điều khiển runtime tương thích", @"key": @"Enabled", @"default": @YES },
        @{ @"title": @"Frame Pacing", @"subtitle": @"Cho phép runtime yêu cầu khoảng khung hình", @"key": @"FramePacing", @"default": @YES }
    ] title:@"Điều khiển" toStack:self.contentStack];

    [self addSwitchRows:@[
        @{ @"title": @"Adaptive FPS", @"subtitle": @"Tôn trọng chế độ nguồn và trạng thái nhiệt", @"key": @"AdaptiveFPS", @"default": @YES },
        @{ @"title": @"Thermal Guard", @"subtitle": @"Giảm yêu cầu FPS khi trạng thái nhiệt tăng; từ 39°C nhiệt pin coi là áp lực ít nhất mức Fair và hồi dần khi nguội. iOS vẫn tự bảo vệ.", @"key": @"ThermalGuard", @"default": @YES },
        @{ @"title": @"Conflict Guard", @"subtitle": @"Ưu tiên tương thích khi có thay đổi xung đột", @"key": @"ConflictGuard", @"default": @YES }
    ] title:@"Tùy chọn hiệu năng" toStack:self.contentStack];

    UIStackView *other = [self newCardWithTitle:@"Tùy chọn khác" subtitle:nil];
    UIStackView *iconRow = [[UIStackView alloc] initWithFrame:CGRectZero];
    iconRow.axis = UILayoutConstraintAxisHorizontal;
    iconRow.alignment = UIStackViewAlignmentCenter;
    iconRow.spacing = 12;
    UIImageView *iconStatus = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"app.badge.checkmark"]];
    iconStatus.translatesAutoresizingMaskIntoConstraints = NO;
    iconStatus.tintColor = PMAccentColor();
    [iconStatus.widthAnchor constraintEqualToConstant:25].active = YES;
    [iconStatus.heightAnchor constraintEqualToConstant:25].active = YES;
    [iconRow addArrangedSubview:iconStatus];
    UIStackView *iconText = [[UIStackView alloc] initWithFrame:CGRectZero];
    iconText.axis = UILayoutConstraintAxisVertical;
    iconText.spacing = 3;
    [iconText addArrangedSubview:PMLabel(@"Hiển thị icon trên màn hình chính", 13, UIFontWeightSemibold, PMPrimaryTextColor())];
    [iconText addArrangedSubview:PMLabel(@"Ứng dụng độc lập · được đăng ký khi cài gói", 11, UIFontWeightRegular, PMMutedColor())];
    [iconRow addArrangedSubview:iconText];
    [iconRow addArrangedSubview:PMLabel(@"Bật", 11, UIFontWeightSemibold, PMAccentColor())];
    [other addArrangedSubview:iconRow];
    [other addArrangedSubview:PMSeparator()];
    [other addArrangedSubview:PMLabel(@"Không cần mở hoặc chỉnh mục Cài đặt của iOS để dùng ứng dụng này.", 11, UIFontWeightRegular, PMMutedColor())];

    UIStackView *tools = [self newCardWithTitle:@"Điều khiển & chẩn đoán" subtitle:@"Các trang nâng cao được mở khi cần"];
    [self addRouteRowWithTitle:@"Tần số quét & FPS" subtitle:@"Chọn mục tiêu Hz và FPS" route:@"hzfps" symbol:@"speedometer" toStack:tools];
    [tools addArrangedSubview:PMSeparator()];
    [self addRouteRowWithTitle:@"Hiệu năng nâng cao" subtitle:@"Điều tiết nhiệt, pin và chính sách runtime" route:@"advanced" symbol:@"slider.horizontal.3" toStack:tools];
    [tools addArrangedSubview:PMSeparator()];
    [self addRouteRowWithTitle:@"Chẩn đoán runtime" subtitle:@"Đối chiếu báo cáo do app đích gửi về" route:@"diagnostics" symbol:@"waveform.path.ecg" toStack:tools];

    UIStackView *about = [self newCardWithTitle:@"Về ứng dụng" subtitle:nil];
    [about addArrangedSubview:PMLabel([@"ProMotion Control · " stringByAppendingString:PMAppVersionString()], 13, UIFontWeightSemibold, PMPrimaryTextColor())];
    [about addArrangedSubview:PMLabel(@"Yêu cầu Hz/FPS phụ thuộc API mà app đích sử dụng, loader, iOS và giới hạn phần cứng. Một số tuỳ chọn chỉ có tác dụng khi runtime hỗ trợ.", 11, UIFontWeightRegular, PMMutedColor())];
    UIButton *reset = PMButton(@"Đặt lại cài đặt");
    [reset.heightAnchor constraintEqualToConstant:46].active = YES;
    [reset addTarget:self action:@selector(confirmResetConfiguration) forControlEvents:UIControlEventTouchUpInside];
    [about addArrangedSubview:reset];
}
- (void)chooseTheme:(UITapGestureRecognizer *)gesture
{
    (void)gesture;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:PMTranslateString(@"Chủ đề")
        message:PMTranslateString(@"Chọn giao diện sáng hoặc tối") preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:PMEnglishSelected ? @"Light" : @"Sáng" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf; if (!self) return;
        if (!PMWriteDomainChanges(@{@"Theme": @"light"})) { [self showWriteFailure]; return; }
        PMRefreshUIOptions();
        dispatch_async(dispatch_get_main_queue(), ^{ PMRebuildUIForPreferenceChange(); });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:PMEnglishSelected ? @"Dark" : @"Tối" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf; if (!self) return;
        if (!PMWriteDomainChanges(@{@"Theme": @"dark"})) { [self showWriteFailure]; return; }
        PMRefreshUIOptions();
        dispatch_async(dispatch_get_main_queue(), ^{ PMRebuildUIForPreferenceChange(); });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:PMEnglishSelected ? @"Cancel" : @"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    if (alert.popoverPresentationController) { alert.popoverPresentationController.sourceView = self.view; alert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1); }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)chooseLanguage:(UITapGestureRecognizer *)gesture
{
    (void)gesture;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:PMEnglishSelected ? @"Language" : @"Ngôn ngữ"
        message:PMEnglishSelected ? @"Choose the app language" : @"Chọn ngôn ngữ cho ProMotion Control"
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Tiếng Việt" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf; if (!self) return;
        if (!PMWriteDomainChanges(@{@"Language": @"vi"})) { [self showWriteFailure]; return; }
        PMRefreshUIOptions();
        dispatch_async(dispatch_get_main_queue(), ^{ PMRebuildUIForPreferenceChange(); });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"English" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf; if (!self) return;
        if (!PMWriteDomainChanges(@{@"Language": @"en"})) { [self showWriteFailure]; return; }
        PMRefreshUIOptions();
        dispatch_async(dispatch_get_main_queue(), ^{ PMRebuildUIForPreferenceChange(); });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:PMEnglishSelected ? @"Cancel" : @"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    if (alert.popoverPresentationController) { alert.popoverPresentationController.sourceView = self.view; alert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1); }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmResetConfiguration
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Đặt lại cấu hình toàn cục?"
                                                                   message:@"Các mục chung sẽ về trạng thái an toàn mặc định. Hồ sơ từng ứng dụng sẽ được giữ nguyên."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Đặt lại" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        BOOL ok = PMWriteDomainChanges(@{
            @"Enabled": @NO, @"RefreshRateEnabled": @NO, @"FPSOverrideEnabled": @NO,
            @"RefreshMode": @0, @"FPSMode": @0, @"CustomRefreshRate": @60, @"CustomFPS": @60,
            @"FramePacing": @NO, @"AdaptiveFPS": @YES, @"ThermalGuard": @YES,
            @"ConflictGuard": @YES, @"StutterFix": @YES, @"AppStabilityFix": @YES,
            @"BackgroundReduction": @YES, @"AppCompatibility": @NO,
            @"ScreenRecordingFix": @YES, @"BatterySaver": @NO, @"ChargingOptimization": @NO,
            @"AdvancedDisplayEnforcement": @NO
        });
        [self buildSettings];
        if (!ok) [self showWriteFailure];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

@implementation PMInfoViewController

- (void)chooseInfoAppearance:(UITapGestureRecognizer *)gesture
{
    (void)gesture;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:PMTranslateString(@"Độ sáng")
        message:PMTranslateString(@"Chọn Sáng hoặc Màu mặc định") preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:PMTranslateString(@"Sáng") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf; if (!self) return;
        if (!PMWriteDomainChanges(@{@"Theme": @"light"})) { [self showWriteFailure]; return; }
        PMRefreshUIOptions();
        dispatch_async(dispatch_get_main_queue(), ^{ PMRebuildUIForPreferenceChange(); });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:PMTranslateString(@"Màu mặc định") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf; if (!self) return;
        if (!PMWriteDomainChanges(@{@"Theme": @"default"})) { [self showWriteFailure]; return; }
        PMRefreshUIOptions();
        dispatch_async(dispatch_get_main_queue(), ^{ PMRebuildUIForPreferenceChange(); });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:PMEnglishSelected ? @"Cancel" : @"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    if (alert.popoverPresentationController) { alert.popoverPresentationController.sourceView = self.view; alert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1); }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)chooseInfoLanguage:(UITapGestureRecognizer *)gesture
{
    (void)gesture;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:PMTranslateString(@"Ngôn ngữ")
        message:PMTranslateString(@"Chọn ngôn ngữ") preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Tiếng Việt" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf; if (!self) return;
        if (!PMWriteDomainChanges(@{@"Language": @"vi"})) { [self showWriteFailure]; return; }
        PMRefreshUIOptions();
        dispatch_async(dispatch_get_main_queue(), ^{ PMRebuildUIForPreferenceChange(); });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"English" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf; if (!self) return;
        if (!PMWriteDomainChanges(@{@"Language": @"en"})) { [self showWriteFailure]; return; }
        PMRefreshUIOptions();
        dispatch_async(dispatch_get_main_queue(), ^{ PMRebuildUIForPreferenceChange(); });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:PMEnglishSelected ? @"Cancel" : @"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    if (alert.popoverPresentationController) { alert.popoverPresentationController.sourceView = self.view; alert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1); }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmSafeClean
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Dọn cache riêng của ProMotion Control?"
        message:@"Chỉ xóa tệp trong thư mục Caches và tmp riêng của ứng dụng này. Không xóa dữ liệu người dùng, cấu hình, cache app khác hay tệp hệ thống. iOS tự quản lý RAM chung."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Dọn an toàn" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray<NSURL *> *dirs = @[
            [[fm URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] firstObject] ?: [NSURL fileURLWithPath:@"/nonexistent"],
            [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
        ];
        unsigned long long bytes = 0;
        NSUInteger removed = 0;
        for (NSURL *dir in dirs) {
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:dir.path isDirectory:&isDir] || !isDir) continue;
            NSArray<NSURL *> *children = [fm contentsOfDirectoryAtURL:dir includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey] options:0 error:nil];
            for (NSURL *child in children) {
                NSDirectoryEnumerator<NSURL *> *enumerator = [fm enumeratorAtURL:child includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey] options:0 errorHandler:nil];
                for (NSURL *item in enumerator) {
                    NSNumber *size = nil;
                    [item getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
                    bytes += size.unsignedLongLongValue;
                }
                NSNumber *size = nil;
                [child getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
                bytes += size.unsignedLongLongValue;
                NSError *error = nil;
                if ([fm removeItemAtURL:child error:&error]) removed++;
                else NSLog(@"[ProMotionControl] Safe cache cleanup skipped %@: %@", child.lastPathComponent, error.localizedDescription);
            }
        }
        NSString *message = [NSString stringWithFormat:@"Đã xóa %lu mục cache/tmp riêng của app, giải phóng khoảng %@. Không có RAM hệ thống hoặc dữ liệu app khác bị xóa.", (unsigned long)removed, PMHumanBytes(bytes)];
        UIAlertController *done = [UIAlertController alertControllerWithTitle:@"Dọn cache hoàn tất" message:message preferredStyle:UIAlertControllerStyleAlert];
        [done addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:done animated:YES completion:nil];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Giới thiệu";
    [self buildInfo];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self buildInfo];
}

- (void)showRespringSafetyNotice
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Respring"
        message:@"Để tránh khởi động lại SpringBoard ngoài ý muốn hoặc gây treo máy, ứng dụng không tự chạy lệnh đặc quyền. Hãy dùng nút Respring trong công cụ jailbreak mà bạn tin cậy sau khi lưu công việc."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Đã hiểu" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)buildInfo
{
    [self clearContent];
    [self addHeaderWithEyebrow:@"GIỚI THIỆU" title:@"ProMotion Control" subtitle:@"Thông tin ứng dụng và liên kết cộng đồng"];

    UIStackView *identity = [self newCardWithTitle:nil subtitle:nil];
    UIStackView *row = [[UIStackView alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 14.0;
    NSString *iconPath = [[NSBundle mainBundle] pathForResource:@"AppIcon60x60@2x" ofType:@"png"];
    UIImage *icon = iconPath.length ? [UIImage imageWithContentsOfFile:iconPath] : nil;
    if (icon) {
        UIImageView *image = [[UIImageView alloc] initWithImage:icon];
        image.translatesAutoresizingMaskIntoConstraints = NO;
        image.layer.cornerRadius = 14.0;
        image.clipsToBounds = YES;
        image.contentMode = UIViewContentModeScaleAspectFit;
        [image.widthAnchor constraintEqualToConstant:62.0].active = YES;
        [image.heightAnchor constraintEqualToConstant:62.0].active = YES;
        [row addArrangedSubview:image];
    }
    UIStackView *details = [[UIStackView alloc] initWithFrame:CGRectZero];
    details.axis = UILayoutConstraintAxisVertical;
    details.spacing = 4.0;
    [details addArrangedSubview:PMLabel(@"ProMotion Control", 16, UIFontWeightBold, PMPrimaryTextColor())];
    [details addArrangedSubview:PMLabel(PMAppVersionString(), 13, UIFontWeightMedium, PMAccentColor())];
    [details addArrangedSubview:PMLabel(@"Tối ưu hiệu năng · Kiểm soát Hz/FPS", 11, UIFontWeightRegular, PMMutedColor())];
    [row addArrangedSubview:details];
    [identity addArrangedSubview:row];

    UIStackView *detailsCard = [self newCardWithTitle:@"Thông tin ứng dụng" subtitle:nil];
    NSArray<NSArray<NSString *> *> *items = @[
        @[@"Tác giả", @"Nguyễn Minh Hải, Taojb"],
        @[@"Phiên bản", PMAppVersionString()],
        @[@"Phiên bản iOS", UIDevice.currentDevice.systemVersion ?: @"Không rõ"],
        @[@"Bundle ID", @"com.dell.promotioncontrol.app"],
        @[@"Kiểu gói", @"Jailbreak · Rootless · Theos"],
        @[@"Mô tả", @"Không biết để gì, lên TikTok @nguyenminhhai_2012 để tham khảo. Hỗ trợ iOS 15+"]
    ];
    for (NSUInteger i = 0; i < items.count; i++) {
        UIStackView *itemRow = [[UIStackView alloc] initWithFrame:CGRectZero];
        itemRow.axis = UILayoutConstraintAxisHorizontal;
        itemRow.alignment = UIStackViewAlignmentTop;
        itemRow.spacing = 12.0;
        UILabel *left = PMLabel(items[i][0], 12, UIFontWeightSemibold, PMMutedColor());
        left.numberOfLines = 2;
        [left.widthAnchor constraintEqualToConstant:90.0].active = YES;
        UILabel *right = PMLabel(items[i][1], 12, UIFontWeightMedium, PMPrimaryTextColor());
        right.numberOfLines = 0;
        [itemRow addArrangedSubview:left];
        [itemRow addArrangedSubview:right];
        [detailsCard addArrangedSubview:itemRow];
        if (i + 1 < items.count) [detailsCard addArrangedSubview:PMSeparator()];
    }

    UIStackView *displayOptions = [self newCardWithTitle:@"Hiển thị & ngôn ngữ" subtitle:@"Áp dụng ngay cho toàn bộ giao diện ProMotion Control"];
    UIStackView *appearanceRow = [[UIStackView alloc] initWithFrame:CGRectZero];
    appearanceRow.axis = UILayoutConstraintAxisHorizontal;
    appearanceRow.alignment = UIStackViewAlignmentCenter;
    appearanceRow.spacing = 12.0;
    UIImageView *appearanceIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"sun.max.fill"]];
    appearanceIcon.translatesAutoresizingMaskIntoConstraints = NO;
    appearanceIcon.tintColor = PMAccentColor();
    [appearanceIcon.widthAnchor constraintEqualToConstant:24.0].active = YES;
    [appearanceIcon.heightAnchor constraintEqualToConstant:24.0].active = YES;
    [appearanceRow addArrangedSubview:appearanceIcon];
    UIStackView *appearanceText = [[UIStackView alloc] initWithFrame:CGRectZero];
    appearanceText.axis = UILayoutConstraintAxisVertical;
    appearanceText.spacing = 3.0;
    [appearanceText addArrangedSubview:PMLabel(@"Độ sáng", 13.0, UIFontWeightSemibold, PMPrimaryTextColor())];
    [appearanceText addArrangedSubview:PMLabel(@"Chọn Sáng hoặc Màu mặc định", 11.0, UIFontWeightRegular, PMMutedColor())];
    [appearanceRow addArrangedSubview:appearanceText];
    [appearanceRow addArrangedSubview:PMLabel(PMLightThemeSelected ? @"Sáng" : @"Màu mặc định", 11.0, UIFontWeightSemibold, PMAccentColor())];
    appearanceRow.userInteractionEnabled = YES;
    appearanceRow.accessibilityLabel = @"Độ sáng";
    [appearanceRow addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(chooseInfoAppearance:)]];
    [displayOptions addArrangedSubview:appearanceRow];
    [displayOptions addArrangedSubview:PMSeparator()];

    UIStackView *languageRow = [[UIStackView alloc] initWithFrame:CGRectZero];
    languageRow.axis = UILayoutConstraintAxisHorizontal;
    languageRow.alignment = UIStackViewAlignmentCenter;
    languageRow.spacing = 12.0;
    UIImageView *languageIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"character.bubble"]];
    languageIcon.translatesAutoresizingMaskIntoConstraints = NO;
    languageIcon.tintColor = PMAccentColor();
    [languageIcon.widthAnchor constraintEqualToConstant:24.0].active = YES;
    [languageIcon.heightAnchor constraintEqualToConstant:24.0].active = YES;
    [languageRow addArrangedSubview:languageIcon];
    UIStackView *languageText = [[UIStackView alloc] initWithFrame:CGRectZero];
    languageText.axis = UILayoutConstraintAxisVertical;
    languageText.spacing = 3.0;
    [languageText addArrangedSubview:PMLabel(@"Ngôn ngữ", 13.0, UIFontWeightSemibold, PMPrimaryTextColor())];
    [languageText addArrangedSubview:PMLabel(@"Chọn Tiếng Việt hoặc Tiếng Anh", 11.0, UIFontWeightRegular, PMMutedColor())];
    [languageRow addArrangedSubview:languageText];
    [languageRow addArrangedSubview:PMLabel(PMEnglishSelected ? @"Tiếng Anh" : @"Tiếng Việt", 11.0, UIFontWeightSemibold, PMAccentColor())];
    languageRow.userInteractionEnabled = YES;
    languageRow.accessibilityLabel = @"Ngôn ngữ";
    [languageRow addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(chooseInfoLanguage:)]];
    [displayOptions addArrangedSubview:languageRow];

    UIStackView *utilities = [self newCardWithTitle:@"Công cụ an toàn" subtitle:@"Chỉ thao tác với dữ liệu tạm thuộc ProMotion Control"];
    [self addRouteRowWithTitle:@"Dọn cache an toàn"
                      subtitle:@"Chỉ dọn cache/tmp riêng của ProMotion Control; không dọn RAM hệ thống"
                         route:@"clean-cache" symbol:@"trash" toStack:utilities];
    [utilities addArrangedSubview:PMSeparator()];
    UIButton *respringButton = PMButton(@"Respring · xem hướng dẫn an toàn");
    [respringButton.heightAnchor constraintGreaterThanOrEqualToConstant:46.0].active = YES;
    [respringButton addTarget:self action:@selector(showRespringSafetyNotice) forControlEvents:UIControlEventTouchUpInside];
    [utilities addArrangedSubview:respringButton];

    UIStackView *links = [self newCardWithTitle:@"Liên kết & cộng đồng" subtitle:@"Chạm để mở ứng dụng tương ứng hoặc trình duyệt mặc định"];
    [self addRouteRowWithTitle:@"TikTok"
                      subtitle:@"@nguyenminhhai_2012"
                         route:@"external:https://www.tiktok.com/@nguyenminhhai_2012"
                       symbol:@"play.rectangle.fill"
                      toStack:links];
    [links addArrangedSubview:PMSeparator()];
    [self addRouteRowWithTitle:@"Link Bio"
                      subtitle:@"linkbio.co/nguyenminhhai2012"
                         route:@"external:https://linkbio.co/nguyenminhhai2012"
                       symbol:@"link"
                      toStack:links];
    [links addArrangedSubview:PMSeparator()];
    [self addRouteRowWithTitle:@"Nhóm Discord"
                      subtitle:@"discord.gg/tHRZ4dEUP"
                         route:@"external:https://discord.gg/tHRZ4dEUP"
                       symbol:@"bubble.left.and.bubble.right.fill"
                      toStack:links];

    [self addNote:@"Các liên kết HTTPS được mở bằng trình xử lý liên kết của iOS: nếu có ứng dụng hỗ trợ liên kết, iOS có thể mở ứng dụng đó; nếu không, liên kết sẽ mở trong trình duyệt mặc định." toStack:self.contentStack];
    [self addNote:@"FPS và Hz trên Trang chủ là mục tiêu đã chọn; CPU là tải hệ thống đo qua Mach API. Các mục tiêu không phải FPS đo thực tế bên trong mọi game." toStack:self.contentStack];
}

@end

@implementation PMDiagnosticsViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Chẩn đoán runtime";
    [self buildDiagnostics];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self buildDiagnostics];
}

- (void)buildDiagnostics
{
    [self clearContent];
    [self addHeaderWithEyebrow:@"RUNTIME STATUS" title:@"Đối chiếu cấu hình" subtitle:@"Các số dưới đây là yêu cầu và báo cáo từ tiến trình, không phải bộ đo FPS toàn hệ thống."];

    [self addNote:@"Các số liệu là thông tin chẩn đoán cấu hình và tiến trình; iOS vẫn giới hạn Hz/FPS theo phần cứng, ứng dụng và API được hỗ trợ." toStack:self.contentStack];

    NSDictionary *domain = PMReadDomain();
    UIStackView *global = [self newCardWithTitle:@"Cấu hình toàn cục" subtitle:nil];
    NSArray *globalKeys = @[@"Enabled", @"FramePacing", @"AdvancedDisplayEnforcement", @"OverrideBlockedApps", @"RefreshMode", @"FPSMode", @"CustomRefreshRate", @"CustomFPS", @"RuntimeState"];
    for (NSString *key in globalKeys) {
        id value = domain[key];
        NSString *text = value ? [value description] : @"Chưa ghi";
        [global addArrangedSubview:PMLabel([NSString stringWithFormat:@"%@  ·  %@", key, text], 12, UIFontWeightRegular, PMMutedColor())];
    }

    UIStackView *profilesCard = [self newCardWithTitle:@"Chẩn đoán theo app" subtitle:nil];
    NSDictionary *profiles = [domain[@"AppProfiles"] isKindOfClass:[NSDictionary class]] ? domain[@"AppProfiles"] : @{};
    // Show runtime reports even for apps that only inherit the global profile.
    // Previously this screen enumerated AppProfiles alone, so global-only apps
    // could be modified at runtime but remain invisible in diagnostics.
    NSMutableSet<NSString *> *bundleIDSet = [NSMutableSet set];
    for (id key in profiles.allKeys) {
        if ([key isKindOfClass:[NSString class]] && [(NSString *)key length] > 0) [bundleIDSet addObject:key];
    }
    NSArray<NSString *> *runtimePrefixes = @[@"RuntimeApplyStatus.", @"RuntimeAPIReadbackStatus.", @"RuntimeDiagnostic.", @"RuntimeMetricsUpdatedAt.", @"RuntimeRateLayerSummary.", @"RuntimeCAFrameRateRangeMakeHookCount.", @"RuntimeUIScreenMaximumFPSHookCount.", @"RuntimeDisplayLinkRangeSetterHookCount.", @"RuntimeDisplayLinkLegacySetterHookCount.", @"RuntimeCAMetalLayerDisplaySyncHookCount.", @"RuntimeCAMetalLayerDrawableCountHookCount.", @"RuntimeCAMetalLayerEDRHookCount.", @"RuntimeOptionalModeRateHooks.", @"RuntimeAdvertisedMaximumFPS.", @"RuntimeAdvertisedMaximumHz.", @"RuntimeAdvertisedTargetFPS.", @"RuntimeNativeScreenMaximumFPS.", @"RuntimeIOKitFramebufferServiceStatus.", @"RuntimeExternalRateConfigStatus.", @"RuntimeScreenRecordingStatus.", @"RuntimeReplayKitHookStatus."];
    for (id key in domain.allKeys) {
        if (![key isKindOfClass:[NSString class]]) continue;
        NSString *keyString = (NSString *)key;
        for (NSString *prefix in runtimePrefixes) {
            if ([keyString hasPrefix:prefix]) {
                NSString *bundleID = [keyString substringFromIndex:prefix.length];
                if (bundleID.length > 0) [bundleIDSet addObject:bundleID];
                break;
            }
        }
    }
    NSArray<NSString *> *bundleIDs = [[bundleIDSet allObjects] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    if (bundleIDs.count == 0) [self addNote:@"Chưa có hồ sơ hoặc báo cáo runtime từ ứng dụng nào. Mở app đích rồi quay lại đây để kiểm tra." toStack:profilesCard];
    for (NSString *bundleID in bundleIDs) {
        NSDictionary *profile = [profiles[bundleID] isKindOfClass:[NSDictionary class]] ? profiles[bundleID] : @{};
        NSString *diagKey = [@"RuntimeDiagnostic." stringByAppendingString:bundleID];
        NSString *rateLayerSummaryKey = [@"RuntimeRateLayerSummary." stringByAppendingString:bundleID];
        NSString *rateLayerSummary = [domain[rateLayerSummaryKey] isKindOfClass:[NSString class]] ? domain[rateLayerSummaryKey] : @"Chưa có báo cáo đường điều khiển nhiều tầng";
        NSString *applyKey = [@"RuntimeApplyResult." stringByAppendingString:bundleID];
        NSString *statusKey = [@"RuntimeApplyStatus." stringByAppendingString:bundleID];
        NSString *readbackKey = [@"RuntimeAPIReadbackStatus." stringByAppendingString:bundleID];
        NSString *updatedKey = [@"RuntimeMetricsUpdatedAt." stringByAppendingString:bundleID];
        NSString *selectedHzKey = [@"RuntimeSelectedHz." stringByAppendingString:bundleID];
        NSString *selectedFPSKey = [@"RuntimeSelectedFPS." stringByAppendingString:bundleID];
        NSString *requestedKey = [@"RuntimeRequestedFPS." stringByAppendingString:bundleID];
        NSString *hardwareKey = [@"RuntimeHardwareMaximumFPS." stringByAppendingString:bundleID];
        NSString *nativeHardwareKey = [@"RuntimeNativeScreenMaximumFPS." stringByAppendingString:bundleID];
        NSString *framebufferServiceKey = [@"RuntimeIOKitFramebufferServiceStatus." stringByAppendingString:bundleID];
        NSString *advertiseEnabledKey = [@"RuntimeCompatibilityRateReportingEnabled." stringByAppendingString:bundleID];
        NSString *advertisedKey = [@"RuntimeAdvertisedMaximumFPS." stringByAppendingString:bundleID];
        NSString *advertisedHzKey = [@"RuntimeAdvertisedMaximumHz." stringByAppendingString:bundleID];
        NSString *advertisedTargetFPSKey = [@"RuntimeAdvertisedTargetFPS." stringByAppendingString:bundleID];
        NSString *rangeKey = [@"RuntimeAppliedRangeText." stringByAppendingString:bundleID];
        NSString *linksKey = [@"RuntimeObservedDisplayLinkCount." stringByAppendingString:bundleID];
        NSString *optionsKey = [@"RuntimeEnabledOptions." stringByAppendingString:bundleID];
        NSString *rangeFactoryCountKey = [@"RuntimeCAFrameRateRangeMakeHookCount." stringByAppendingString:bundleID];
        NSString *screenHookCountKey = [@"RuntimeUIScreenMaximumFPSHookCount." stringByAppendingString:bundleID];
        NSString *rangeSetterCountKey = [@"RuntimeDisplayLinkRangeSetterHookCount." stringByAppendingString:bundleID];
        NSString *legacySetterCountKey = [@"RuntimeDisplayLinkLegacySetterHookCount." stringByAppendingString:bundleID];
        NSString *metalDisplaySyncCountKey = [@"RuntimeCAMetalLayerDisplaySyncHookCount." stringByAppendingString:bundleID];
        NSString *metalDrawableCountKey = [@"RuntimeCAMetalLayerDrawableCountHookCount." stringByAppendingString:bundleID];
        NSString *metalEDRCountKey = [@"RuntimeCAMetalLayerEDRHookCount." stringByAppendingString:bundleID];
        NSString *screenRecordingStatusKey = [@"RuntimeScreenRecordingStatus." stringByAppendingString:bundleID];
        NSString *replayKitHookStatusKey = [@"RuntimeReplayKitHookStatus." stringByAppendingString:bundleID];
        NSString *replayKitStartCountKey = [@"RuntimeReplayKitStartCallbackCount." stringByAppendingString:bundleID];
        NSString *replayKitStartFailureCountKey = [@"RuntimeReplayKitStartFailureCount." stringByAppendingString:bundleID];
        NSString *replayKitStopCountKey = [@"RuntimeReplayKitStopCallbackCount." stringByAppendingString:bundleID];
        NSString *screenRecordingStatus = [domain[screenRecordingStatusKey] isKindOfClass:[NSString class]] ? domain[screenRecordingStatusKey] : @"Chưa có báo cáo";
        NSString *replayKitHookStatus = [domain[replayKitHookStatusKey] isKindOfClass:[NSString class]] ? domain[replayKitHookStatusKey] : @"Chưa được kiểm tra";
        NSString *replayKitStartCount = domain[replayKitStartCountKey] ? [domain[replayKitStartCountKey] description] : @"0";
        NSString *replayKitStartFailures = domain[replayKitStartFailureCountKey] ? [domain[replayKitStartFailureCountKey] description] : @"0";
        NSString *replayKitStopCount = domain[replayKitStopCountKey] ? [domain[replayKitStopCountKey] description] : @"0";
        NSString *replayKitSummary = [NSString stringWithFormat:@"%@ · hook %@ · start callbacks %@ (fail %@) · stop callbacks %@", screenRecordingStatus, replayKitHookStatus, replayKitStartCount, replayKitStartFailures, replayKitStopCount];
        NSString *optionalModeRateHooksKey = [@"RuntimeOptionalModeRateHooks." stringByAppendingString:bundleID];
        NSString *optionalModeRateHooksText = [domain[optionalModeRateHooksKey] isKindOfClass:[NSString class]] ? domain[optionalModeRateHooksKey] : @"Chưa kiểm tra selector bổ sung";
        NSString *thermalStateKey = [@"RuntimeThermalState." stringByAppendingString:bundleID];
        NSString *thermalCapKey = [@"RuntimeThermalGovernorCap." stringByAppendingString:bundleID];
        NSString *thermalNoteKey = [@"RuntimeThermalPolicyNote." stringByAppendingString:bundleID];
        NSDictionary *runtimeOptions = [domain[optionsKey] isKindOfClass:[NSDictionary class]] ? domain[optionsKey] : @{};
        NSArray<NSString *> *optionKeys = @[@"Enabled", @"FramePacing", @"AdvancedDisplayEnforcement", @"AdaptiveFPS", @"ThermalGuard", @"ConflictGuard", @"StutterFix", @"AppStabilityFix", @"BackgroundReduction", @"AppCompatibility", @"ScreenRecordingFix", @"BatterySaver", @"ChargingOptimization", @"SafeRecovery", @"OverrideBlockedApps"];
        NSMutableArray<NSString *> *optionStates = [NSMutableArray array];
        for (NSString *optionKey in optionKeys) {
            NSNumber *enabledValue = [runtimeOptions[optionKey] respondsToSelector:@selector(boolValue)] ? runtimeOptions[optionKey] : nil;
            if (enabledValue) [optionStates addObject:[NSString stringWithFormat:@"%@=%@", optionKey, enabledValue.boolValue ? @"ON" : @"OFF"]];
        }
        NSString *optionsText = optionStates.count ? [optionStates componentsJoinedByString:@" · "] : @"Chưa có snapshot tùy chọn từ runtime";
        NSString *diag = [domain[diagKey] isKindOfClass:[NSString class]] ? domain[diagKey] : @"Chưa có báo cáo từ app";
        NSString *apply = [domain[applyKey] isKindOfClass:[NSString class]] ? domain[applyKey] : @"Chưa có kết quả áp dụng";
        NSString *selectedHz = domain[selectedHzKey] ? ([domain[selectedHzKey] integerValue] > 0 ? [NSString stringWithFormat:@"%ld Hz", (long)[domain[selectedHzKey] integerValue]] : @"Auto") : @"Chưa có báo cáo";
        NSString *selectedFPS = domain[selectedFPSKey] ? ([domain[selectedFPSKey] integerValue] > 0 ? [NSString stringWithFormat:@"%ld FPS", (long)[domain[selectedFPSKey] integerValue]] : @"Auto") : @"Chưa có báo cáo";
        NSString *requested = domain[requestedKey] ? [domain[requestedKey] description] : @"—";
        NSString *hardware = domain[hardwareKey] ? [domain[hardwareKey] description] : @"—";
        NSString *nativeHardware = domain[nativeHardwareKey] ? [domain[nativeHardwareKey] description] : hardware;
        NSInteger framebufferStatus = [domain[framebufferServiceKey] respondsToSelector:@selector(integerValue)] ? [domain[framebufferServiceKey] integerValue] : -2;
        NSString *framebufferText = framebufferStatus == 1 ? @"IOMobileFramebuffer nhìn thấy (chỉ dò dịch vụ; không gọi selector riêng)" : (framebufferStatus == 0 ? @"IOMobileFramebuffer không nhìn thấy trong tiến trình" : (framebufferStatus == -1 ? @"IOKit discovery không khả dụng" : @"Chưa kiểm tra IOKit service"));
        NSString *externalConfigKey = [@"RuntimeExternalRateConfigStatus." stringByAppendingString:bundleID];
        NSString *externalConfigText = [domain[externalConfigKey] isKindOfClass:[NSString class]] ? domain[externalConfigKey] : @"Chưa có trạng thái cấu hình bổ sung";
        BOOL advertiseEnabled = [domain[advertiseEnabledKey] respondsToSelector:@selector(boolValue)] && [domain[advertiseEnabledKey] boolValue];
        NSString *advertised = advertiseEnabled && [domain[advertisedHzKey] respondsToSelector:@selector(integerValue)] && [domain[advertisedTargetFPSKey] respondsToSelector:@selector(integerValue)]
            ? [NSString stringWithFormat:@"%@ Hz / %@ FPS (giả lập)", domain[advertisedHzKey], domain[advertisedTargetFPSKey]]
            : (advertiseEnabled && [domain[advertisedKey] respondsToSelector:@selector(integerValue)] && [domain[advertisedKey] integerValue] > 0
                ? [NSString stringWithFormat:@"%@ FPS (giả lập)", domain[advertisedKey]] : @"Tắt/Chưa có số báo cáo");
        NSString *appliedRange = [domain[rangeKey] isKindOfClass:[NSString class]] ? domain[rangeKey] : @"Chưa có dải API";
        NSString *observedLinks = domain[linksKey] ? [domain[linksKey] description] : @"Chưa có báo cáo";
        NSString *rangeFactoryCalls = domain[rangeFactoryCountKey] ? [domain[rangeFactoryCountKey] description] : @"Chưa quan sát";
        NSString *screenHookCalls = domain[screenHookCountKey] ? [domain[screenHookCountKey] description] : @"Chưa quan sát";
        NSString *rangeSetterCalls = domain[rangeSetterCountKey] ? [domain[rangeSetterCountKey] description] : @"Chưa quan sát";
        NSString *legacySetterCalls = domain[legacySetterCountKey] ? [domain[legacySetterCountKey] description] : @"Chưa quan sát";
        NSString *metalDisplaySyncCalls = domain[metalDisplaySyncCountKey] ? [domain[metalDisplaySyncCountKey] description] : @"Chưa quan sát";
        NSString *metalDrawableCalls = domain[metalDrawableCountKey] ? [domain[metalDrawableCountKey] description] : @"Chưa quan sát";
        NSString *metalEDRCalls = domain[metalEDRCountKey] ? [domain[metalEDRCountKey] description] : @"Chưa quan sát";
        NSInteger thermalStateValue = [domain[thermalStateKey] respondsToSelector:@selector(integerValue)] ? [domain[thermalStateKey] integerValue] : -1;
        NSArray<NSString *> *thermalLabels = @[@"Bình thường", @"Ấm", @"Nóng", @"Rất nóng"];
        NSString *thermalStateText = (thermalStateValue >= 0 && thermalStateValue < (NSInteger)thermalLabels.count)
            ? thermalLabels[thermalStateValue] : @"Chưa có báo cáo";
        NSString *thermalCapText = [domain[thermalCapKey] respondsToSelector:@selector(integerValue)] && [domain[thermalCapKey] integerValue] > 0
            ? [NSString stringWithFormat:@"%ld FPS", (long)[domain[thermalCapKey] integerValue]] : @"Chưa áp dụng/Guard OFF";
        NSString *thermalNoteText = [domain[thermalNoteKey] isKindOfClass:[NSString class]] ? domain[thermalNoteKey] : @"Chưa có chính sách nhiệt từ tiến trình";
        NSString *runtimeStatus = [domain[statusKey] isKindOfClass:[NSString class]] ? domain[statusKey] : @"";
        NSString *readbackStatus = [domain[readbackKey] isKindOfClass:[NSString class]] ? domain[readbackKey] : @"Chưa có API read-back";
        NSNumber *metricsUpdated = [domain[updatedKey] respondsToSelector:@selector(doubleValue)] ? domain[updatedKey] : nil;
        if (runtimeStatus.length == 0 || !metricsUpdated) {
            NSString *diagLower = diag.lowercaseString;
            if (![diag isEqualToString:@"Chưa có báo cáo từ app"]) {
                if ([diagLower containsString:@"không có api"] || [diagLower containsString:@"không cung cấp api"])
                    runtimeStatus = @"API không tương thích";
                else if ([diagLower containsString:@"công tắc tổng đang tắt"] || [diagLower containsString:@"hồ sơ riêng của ứng dụng đang tắt"])
                    runtimeStatus = @"Đã nạp tweak · cấu hình đang tắt";
                else if ([diagLower containsString:@"cấu hình đã nạp"] || [diagLower containsString:@"đang chờ cadisplaylink"])
                    runtimeStatus = @"Đã nạp tweak · đang chờ CADisplayLink tương thích";
                else
                    runtimeStatus = @"Đã nạp tweak · chưa có báo cáo áp dụng";
            } else {
                runtimeStatus = @"Chưa được nạp tweak hoặc chưa có báo cáo từ tiến trình";
            }
        }
        NSInteger policyValue = [profile[@"InterventionPolicy"] respondsToSelector:@selector(integerValue)] ? [profile[@"InterventionPolicy"] integerValue] : 0;
        NSInteger performanceValue = [profile[@"PerformanceMode"] respondsToSelector:@selector(integerValue)] ? [profile[@"PerformanceMode"] integerValue] : 0;
        NSInteger profileHzMode = [profile[@"RefreshMode"] respondsToSelector:@selector(integerValue)] ? [profile[@"RefreshMode"] integerValue] : -2;
        NSInteger profileFPSMode = [profile[@"FPSMode"] respondsToSelector:@selector(integerValue)] ? [profile[@"FPSMode"] integerValue] : -2;
        BOOL hasExplicitTuning = profileHzMode != -2 || profileFPSMode != -2 || performanceValue != 0;
        BOOL isInheritedSeed = profile.count > 0 && [profile objectForKey:@"Enabled"] != nil &&
            ![profile[@"Enabled"] boolValue] && policyValue == 0 && !hasExplicitTuning;
        BOOL globalRuntimeActive = (!domain[@"Enabled"] || [domain[@"Enabled"] boolValue]) &&
            (!domain[@"FramePacing"] || [domain[@"FramePacing"] boolValue]) &&
            (!domain[@"AdvancedDisplayEnforcement"] || [domain[@"AdvancedDisplayEnforcement"] boolValue]);
        NSString *enabledText = isInheritedSeed || profile.count == 0
            ? (globalRuntimeActive ? @"Kế thừa toàn cục (đang bật)" : @"Kế thừa toàn cục (đang tắt)")
            : ([profile[@"Enabled"] boolValue] ? @"Có" : @"Không");
        NSString *policyText = (policyValue == 2) ? @"Bị chặn" : ((policyValue == 1) ? @"Cho phép" : @"Tự động");
        NSArray<NSString *> *performanceNames = @[@"Tự động", @"Hiệu năng", @"Cân bằng", @"Tiết kiệm"];
        NSString *performanceText = (performanceValue >= 0 && performanceValue < (NSInteger)performanceNames.count) ? performanceNames[performanceValue] : @"Tự động";
        NSString *profileHzText = profileHzMode == -2 ? @"Kế thừa toàn cục" : (profile[@"RefreshMode"] ? [profile[@"RefreshMode"] description] : @"Dùng chung");
        NSString *profileFPSText = profileFPSMode == -2 ? @"Kế thừa toàn cục" : (profile[@"FPSMode"] ? [profile[@"FPSMode"] description] : @"Dùng chung");
        NSString *item = [NSString stringWithFormat:@"%@\nBật: %@ · Chính sách: %@ · Ưu tiên: %@\nHz mode: %@ · FPS mode: %@\nĐã chọn hiệu lực: %@ / %@ · Mục tiêu kết hợp: %@ FPS · Dải API gửi: %@\nTrần native: %@ FPS · UIScreen đang quảng bá: %@ · Tối đa native: %@ Hz\nHook calls: UIScreen %@ · CAFrameRateRangeMake %@ · Range setter %@ · Legacy interval %@\nCAMetalLayer: displaySync %@ · drawableCount %@ · EDR %@\nQuay màn hình / ReplayKit: %@\nCADisplayLink quan sát: %@\nIOKit discovery: %@\nĐường điều khiển: %@\nAPI read-back: %@\nRate-report hooks: %@\nCấu hình RootHide/CFPreferences: %@\nNhiệt iOS: %@ · Thermal Guard cap: %@\nTùy chọn runtime: %@\nTrạng thái: %@\n%@\n%@\n%@",
            bundleID, enabledText, policyText, performanceText, profileHzMode == -2 ? @"Kế thừa toàn cục" : profileHzText, profileFPSText, selectedHz, selectedFPS, requested, appliedRange, hardware, advertised, nativeHardware, screenHookCalls, rangeFactoryCalls, rangeSetterCalls, legacySetterCalls, metalDisplaySyncCalls, metalDrawableCalls, metalEDRCalls, replayKitSummary, observedLinks, framebufferText, rateLayerSummary, readbackStatus, optionalModeRateHooksText, externalConfigText, thermalStateText, thermalCapText, optionsText, runtimeStatus, diag, apply, thermalNoteText];
        [profilesCard addArrangedSubview:PMLabel(item, 11, UIFontWeightRegular, PMMutedColor())];
        if (![bundleID isEqualToString:bundleIDs.lastObject]) [profilesCard addArrangedSubview:PMSeparator()];
    }
    UIStackView *privacy = [self newCardWithTitle:@"Kiểm tra quyền lưu" subtitle:nil];
    NSString *writeText = PMLastWriteState < 0 ? @"Chưa có thao tác ghi trong phiên app này." : (PMLastWriteState == 1 ? @"App đọc lại được giá trị vừa ghi trong chính tiến trình này; điều đó chưa chứng minh tweak bên ngoài nhìn thấy cùng dữ liệu." : @"Không xác minh được giá trị sau khi ghi; có thể sandbox chặn domain dùng chung.");
    [self addNote:writeText toStack:privacy];
    UIButton *probe = PMButton(@"Kiểm tra ghi cấu hình");
    [probe.heightAnchor constraintEqualToConstant:44].active = YES;
    [probe addTarget:self action:@selector(runWriteProbe) forControlEvents:UIControlEventTouchUpInside];
    [privacy addArrangedSubview:probe];
    [self addNote:@"Đọc lại được giá trị trong app quản lý chưa chứng minh tiến trình tweak đọc được domain đó. Hãy kiểm tra kết quả runtime trong app đích sau khi đổi cấu hình. Không có API UIKit chung để khẳng định FPS thực tế đã trình bày; hãy dùng bộ đếm FPS trong app test/game nếu có." toStack:self.contentStack];
}

- (void)runWriteProbe
{
    NSString *key = @"AppManagerLastProbe";
    BOOL ok = PMWriteDomainChanges(@{key: @([[NSDate date] timeIntervalSince1970])});
    [self buildDiagnostics];
    if (!ok) [self showWriteFailure];
}

@end
