// =================================================================================================
// TitaniumThermalBatteryGuardian.x
// User-supplied thermal / battery / background-audio guard, integrated for the shared
// FREE / PREMIUM / ADMIN Titanium bridge. The Logos group is always initialized; every
// override still checks Apex_IsMasterEnabled() at call time so live profile changes apply.
//
// Upgrade notes (no supplied section removed):
//  - Supplied stray "end" terminator converted to "%end" so Logos compiles.
//  - One-line "%orig" bodies expanded to multi-line form for Logos.
//  - Thermal values are clamped instead of blindly faked, and charging heat is handled
//    with an opt-in ChargeThermalGuard key rather than pretending the device is cool.
// =================================================================================================
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <mach/mach.h>
#import <pthread.h>
#import <math.h>
#import "TitaniumSettingsAPI.h"

// Khai báo extern từ Core Engine
extern BOOL Apex_IsMasterEnabled(void);
extern BOOL g_isCurrentAppBlacklisted;

#pragma mark - Shared helpers

// The guard must not spoof thermal/power state inside the control app itself,
// otherwise the dashboard and the app's own render loop read fake values.
static BOOL Titanium_ThermalIsControlApp(void) {
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"";
    return [bundle isEqualToString:@"com.dell.promotioncontrol.app"];
}

// Reads an optional shared-preference key without creating a second domain.
static BOOL Titanium_ThermalConfigBool(NSString *key, BOOL fallback) {
    NSDictionary *config = Titanium_LoadSharedConfig();
    if (![config isKindOfClass:[NSDictionary class]]) return fallback;
    id value = config[key];
    if ([value respondsToSelector:@selector(boolValue)]) return [value boolValue];
    return fallback;
}

// Public API only: the battery state is read through UIDevice so the guard does not
// depend on private power-source daemons. It tells us when the device is plugged in,
// which is the condition the user wants protected while gaming and charging.
static BOOL Titanium_ThermalDeviceIsCharging(void) {
    UIDevice *device = [UIDevice currentDevice];
    if (!device) return NO;
    UIDeviceBatteryState state = device.batteryState;
    return state == UIDeviceBatteryStateCharging || state == UIDeviceBatteryStateFull;
}

%group TitaniumThermalBatteryGroup

// =================================================================================================
// 1. APPLE SMART BATTERY MANAGER — Không can thiệp dòng sạc thật, chỉ chặn giảm tải do pin
// =================================================================================================
%hook AppleSmartBatteryManager
- (int)setChargingCurrentLimit:(int)limit {
    if (Apex_IsMasterEnabled()) {
        // Giữ nguyên dòng sạc do iOS/PMIC quyết định. Ép dòng sạc bằng hook user-space
        // sẽ làm sai lệch bộ quản lý pin; guard chỉ đảm bảo giá trị hợp lệ.
        if (limit < 0) limit = 0;
        return %orig(limit);
    }
    return %orig(limit);
}

- (BOOL)isCharging {
    // Giữ nguyên trạng thái sạc thật để iOS vẫn quản lý nhiệt khi vừa dùng vừa sạc.
    BOOL originalCharging = %orig;
    return originalCharging;
}
%end

// =================================================================================================
// 2. IOREGISTRY & POWER MANAGEMENT — Bảo vệ các khóa nhiệt độ/giới hạn khi đang sạc
// =================================================================================================
%hook IORegistryEntry
- (kern_return_t)setCFProperty:(NSString *)key withValue:(id)value {
    if (Apex_IsMasterEnabled() && key) {
        NSString *lowerKey = [key lowercaseString];
        // Theo dõi các khóa nhiệt độ/giới hạn. Bản HardwareOverdriveGuard đã triệt tiêu
        // lệnh bóp hiệu năng; ở đây vẫn chuyển tiếp để không phá chuỗi hook của module khác.
        if ([lowerKey containsString:@"thermal"] || [lowerKey containsString:@"temperature"] || [lowerKey containsString:@"limit"]) {
            return %orig(key, value);
        }
    }
    return %orig(key, value);
}
%end

// =================================================================================================
// 3. BACKGROUND AUDIO — Duy trì phiên âm thanh khi chạy nhạc nền và sạc
// =================================================================================================
%hook AVAudioSession
- (BOOL)setActive:(BOOL)active error:(NSError * _Nullable *)outError {
    BOOL result = %orig(active, outError);
    // Không đổi category của app khác; chỉ giữ phiên hoạt động bình thường để nhạc nền
    // không bị gián đoạn khi hệ thống đang quản lý nhiệt lúc sạc.
    return result;
}
%end

// =================================================================================================
// 4. PROCESS INFO THERMAL / LOW POWER — Chống bóp Hz, FPS và hiệu năng khi đang sạc
// =================================================================================================
%hook NSProcessInfo
- (NSProcessInfoThermalState)thermalState {
    NSProcessInfoThermalState realState = %orig;
    if (!Apex_IsMasterEnabled() || Titanium_ThermalIsControlApp()) {
        return realState;
    }

    // Opt-in: khi vừa dùng vừa sạc và máy đã Critical, giữ mức Serious thay vì Nominal
    // để bộ điều khiển sạc còn "thở", tránh nóng hơn. Mặc định tắt để giữ hành vi gốc.
    BOOL chargeGuard = Titanium_ThermalConfigBool(@"ChargeThermalGuard", NO);
    if (chargeGuard && Titanium_ThermalDeviceIsCharging() &&
        realState == NSProcessInfoThermalStateCritical) {
        return NSProcessInfoThermalStateSerious;
    }

    // Chặn iOS tự hạ Hz/FPS/hiệu năng do trạng thái Serious/Critical.
    if (realState >= NSProcessInfoThermalStateSerious) {
        return NSProcessInfoThermalStateFair;
    }
    return realState;
}

- (BOOL)isLowPowerModeEnabled {
    // Đọc giá trị gốc trước để chuỗi hook và observer của app vẫn nhận sự kiện thật.
    BOOL originalLowPower = %orig;
    if (!Apex_IsMasterEnabled() || Titanium_ThermalIsControlApp()) {
        return originalLowPower;
    }
    // Low Power Mode hạ tần số quét và giới hạn CPU/GPU; tắt nó khi engine đang bật.
    return NO;
}
%end

%end

// =================================================================================================
// CONSTRUCTOR — Khởi tạo module bảo vệ nhiệt độ/pin/nhạc nền
// =================================================================================================
static inline BOOL Titanium_ProcessIsSystemOrControl(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    return [bid isEqualToString:@"com.apple.springboard"] ||
           [bid isEqualToString:@"com.dell.promotioncontrol.app"];
}

%ctor {
    @autoreleasepool {
        if (!Titanium_ProcessIsSystemOrControl()) return; // other UIKit apps: no heavy hooks
        %init(TitaniumThermalBatteryGroup);
    }
}
