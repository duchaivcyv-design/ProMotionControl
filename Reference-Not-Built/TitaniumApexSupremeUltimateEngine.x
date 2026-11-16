// =================================================================================================
// TitaniumApexSupremeUltimateEngine.x
// Supreme Ultimate Logos source supplied by the user for the ProMotionControl tweak.
// Integrated verbatim; the only edits are the ones required to compile as part of
// this project, to keep the Titanium FREE/PREMIUM/ADMIN bridge contract (0 = AUTO),
// and to make the "critical thermal" safeguard actually reachable.
// =================================================================================================
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <pthread.h>
#import <sys/socket.h>
#import <netinet/in.h>

// Khai báo các hàm ngoại vi từ Core Bridge điều khiển tổng
#import "TitaniumSettingsAPI.h"

extern NSInteger Titanium_GetMasterRate(void);
extern BOOL Apex_IsMasterEnabled(void);
extern BOOL g_isCurrentAppBlacklisted;

// Bridge integration: getSelectedHz returns 0 for AUTO so the Supreme layer can
// never divide by zero or advertise a 0 Hz mode. It only overrides on 10...244.
static inline NSInteger Titanium_SupremeEffectiveRate(void) {
    NSInteger rate = Titanium_GetMasterRate();
    return (rate >= 10 && rate <= 244) ? rate : 0;
}

static inline BOOL Titanium_SupremeShouldOverride(void) {
    return Apex_IsMasterEnabled() && !g_isCurrentAppBlacklisted && Titanium_SupremeEffectiveRate() > 0;
}

// The hooked -[NSProcessInfo thermalState] below reports a softened value to the
// rest of the process. It stores the untouched %orig here so the IORegistryEntry
// thermal safeguard can still see a real Critical state instead of the softened one.
static volatile NSInteger g_TitaniumLastRealThermalState = NSProcessInfoThermalStateNominal;

static inline NSProcessInfoThermalState Titanium_RealThermalStateSnapshot(void) {
    (void)[[NSProcessInfo processInfo] thermalState]; // refreshes the snapshot through the hook
    return (NSProcessInfoThermalState)g_TitaniumLastRealThermalState;
}

// =================================================================================================
// 1. SUPREME DISPLAY MODE & UNBOUNDED PIXEL CLOCK (200MHz - 800MHz+ Bandwidth Overclock)
// =================================================================================================
@interface TitaniumSupremeUltimateDisplayMode : NSObject
@end

@implementation TitaniumSupremeUltimateDisplayMode
- (double)refreshRate       { return (double)Titanium_SupremeEffectiveRate(); }
- (double)refreshRateForMode { return (double)Titanium_SupremeEffectiveRate(); }
- (double)safeRefreshRate    { return (double)Titanium_SupremeEffectiveRate(); }
- (double)nominalRefreshRate { return (double)Titanium_SupremeEffectiveRate(); }
- (double)pixelAspectRatio   { return 1.0; }
- (CGSize)size              { return [UIScreen mainScreen].nativeBounds.size; }
- (CGSize)pixelSize         { return [UIScreen mainScreen].nativeBounds.size; }
- (unsigned int)pixelClock  { return 0xFFFFFFFF; } // Lỗ hổng vô cực: Mở rộng Pixel Clock từ 200MHz lên 800MHz+ không giới hạn
- (uint32_t)timingFlags     { return 0xFFFFFFFF; } // Triệt tiêu hoàn toàn V-Sync phần cứng
@end

static TitaniumSupremeUltimateDisplayMode *Titanium_GetSupremeMode(void) {
    static TitaniumSupremeUltimateDisplayMode *s_supremeMode = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_supremeMode = [[TitaniumSupremeUltimateDisplayMode alloc] init];
    });
    return s_supremeMode;
}

%group TitaniumApexSupremeUltimateGroup

// =================================================================================================
// 2. IOMOBILEFRAMEBUFFER & PANEL DRIVER (Bẻ khóa tầng Panel, ProMotion & Driver hiển thị)
// =================================================================================================
%hook IOMobileFramebufferClient
- (int)setDisplayRefreshRate:(float)rate options:(unsigned int)options {
    if (Titanium_SupremeShouldOverride()) {
        return 0; // Chặn mọi lệnh từ chối, ép driver phần cứng chấp nhận thông số mới
    }
    return %orig(rate, options);
}

- (int)setDisplayRefreshRate:(float)rate {
    if (Titanium_SupremeShouldOverride()) {
        return 0;
    }
    return %orig(rate);
}

- (int)getDisplayRefreshRate:(float *)arg1 {
    if (Apex_IsMasterEnabled() && arg1) {
        *arg1 = (float)Titanium_SupremeEffectiveRate();
        return 0;
    }
    return %orig(arg1);
}

- (float)getDisplayRefreshRate {
    if (Apex_IsMasterEnabled()) {
        return (float)Titanium_SupremeEffectiveRate();
    }
    return %orig;
}

- (BOOL)isDisplayRefreshRateSupported:(float)rate {
    if (Apex_IsMasterEnabled()) return YES; // Cho phép toàn bộ dải từ 10Hz đến 244Hz
    return %orig(rate);
}

- (int)getDefaultDisplayMode:(id *)arg1 {
    if (Apex_IsMasterEnabled() && arg1) {
        *arg1 = (id)Titanium_GetSupremeMode();
        return 0;
    }
    return %orig(arg1);
}
%end

// =================================================================================================
// 3. CAWINDOWSERVERDISPLAY & RENDER SERVER (Ép xung nhịp dựng hình, loại bỏ độ trễ V-Sync)
// =================================================================================================
%hook CAWindowServerDisplay
- (void)setMinimumFrameDuration:(double)duration {
    if (Titanium_SupremeShouldOverride()) {
        NSInteger target = Titanium_SupremeEffectiveRate();
        %orig(1.0 / (double)target);
        return;
    }
    %orig(duration);
}

- (double)minimumFrameDuration {
    if (Titanium_SupremeShouldOverride()) return 1.0 / (double)Titanium_SupremeEffectiveRate();
    return %orig;
}

- (void)setMaximumRefreshRate:(double)rate {
    if (Titanium_SupremeShouldOverride()) {
        %orig((double)Titanium_SupremeEffectiveRate());
        return;
    }
    %orig(rate);
}

- (double)maximumRefreshRate {
    if (Titanium_SupremeShouldOverride()) return (double)Titanium_SupremeEffectiveRate();
    return %orig;
}

- (void)setMinimumRefreshRate:(double)rate {
    if (Titanium_SupremeShouldOverride()) {
        %orig((double)Titanium_SupremeEffectiveRate());
        return;
    }
    %orig(rate);
}

- (double)minimumRefreshRate {
    if (Titanium_SupremeShouldOverride()) return (double)Titanium_SupremeEffectiveRate();
    return %orig;
}

- (void)setIdealRefreshRate:(double)rate {
    if (Titanium_SupremeShouldOverride()) {
        %orig((double)Titanium_SupremeEffectiveRate());
        return;
    }
    %orig(rate);
}

- (double)idealRefreshRate {
    if (Titanium_SupremeShouldOverride()) return (double)Titanium_SupremeEffectiveRate();
    return %orig;
}

- (BOOL)allowsVirtualModes { return YES; }
- (void)setAllowsVirtualModes:(BOOL)flag {
    %orig(YES);
}
%end

// =================================================================================================
// 4. CADISPLAY & CADISPLAYLINK (Khóa cứng tần số quét màn hình & Luồng khung hình tuyệt đối)
// =================================================================================================
%hook CADisplay
- (double)refreshRate {
    if (Titanium_SupremeShouldOverride()) return (double)Titanium_SupremeEffectiveRate();
    return %orig;
}

- (void)setRefreshRate:(double)rate {
    if (Titanium_SupremeShouldOverride()) {
        %orig((double)Titanium_SupremeEffectiveRate());
        return;
    }
    %orig(rate);
}

- (NSInteger)preferredFPS {
    if (Titanium_SupremeShouldOverride()) return Titanium_SupremeEffectiveRate();
    return %orig;
}

- (void)setPreferredFPS:(NSInteger)fps {
    if (Titanium_SupremeShouldOverride()) {
        %orig(Titanium_SupremeEffectiveRate());
        return;
    }
    %orig(fps);
}

- (NSArray *)availableModes {
    NSArray *orig = %orig;
    if (Titanium_SupremeShouldOverride()) {
        id supremeMode = (id)Titanium_GetSupremeMode();
        return supremeMode ? (orig ? [orig arrayByAddingObject:supremeMode] : @[supremeMode]) : orig;
    }
    return orig;
}

- (id)currentMode {
    if (Titanium_SupremeShouldOverride()) {
        id supremeMode = (id)Titanium_GetSupremeMode();
        if (supremeMode) return supremeMode;
    }
    return %orig;
}

- (void)setCurrentMode:(id)mode {
    if (Titanium_SupremeShouldOverride()) {
        id supremeMode = (id)Titanium_GetSupremeMode();
        %orig(supremeMode ? supremeMode : mode);
        return;
    }
    %orig(mode);
}
%end

%hook CADisplayLink
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
    if (Titanium_SupremeShouldOverride()) {
        NSInteger target = Titanium_SupremeEffectiveRate();
        %orig(CAFrameRateRangeMake((float)target, (float)target, (float)target));
        return;
    }
    %orig(range);
}

- (void)setPreferredFramesPerSecond:(NSInteger)fps {
    if (Titanium_SupremeShouldOverride()) {
        %orig(Titanium_SupremeEffectiveRate());
        return;
    }
    %orig(fps);
}
%end

// =================================================================================================
// 5. AGXACCELERATOR & SMART THERMAL SAFEGUARD (Chống cháy chip/màn hình, Giảm nhiệt độ & Sạc nhanh)
// =================================================================================================
%hook AGXAccelerator
- (int)setPowerState:(unsigned int)state {
    if (Apex_IsMasterEnabled()) {
        %orig(1); // Ép mức điện năng GPU tối đa, không bị bóp xung
        return 1;
    }
    return %orig(state);
}

- (void)setPerfState:(unsigned int)state {
    if (Apex_IsMasterEnabled()) {
        %orig(1); // Ép hiệu năng đồ họa đỉnh cao
        return;
    }
    %orig(state);
}
%end

// Lớp bảo vệ phần cứng thông minh: Giám sát nhiệt độ, tản nhiệt nhanh khi sạc/chạy nền, chống quá nhiệt linh kiện
%hook IORegistryEntry
- (kern_return_t)setCFProperty:(NSString *)key withValue:(id)value {
    if (Apex_IsMasterEnabled() && key) {
        NSString *kl = [key lowercaseString];
        if ([kl containsString:@"thermal"] || [kl containsString:@"power"] || [kl containsString:@"throttle"]) {
            NSProcessInfoThermalState state = Titanium_RealThermalStateSnapshot();
            if (state >= NSProcessInfoThermalStateCritical) {
                return %orig(key, value); // Cho phép tản nhiệt nhẹ khi chạm ngưỡng nguy hiểm tối đa để bảo vệ phần cứng
            }
            return KERN_SUCCESS; // Chặn toàn bộ lệnh bóp hiệu năng thông thường khi sạc hoặc chạy app nền
        }
    }
    return %orig(key, value);
}
%end

%hook NSProcessInfo
- (NSProcessInfoThermalState)thermalState {
    NSProcessInfoThermalState realState = %orig;
    g_TitaniumLastRealThermalState = (NSInteger)realState;
    if (Apex_IsMasterEnabled()) {
        // Tránh tình trạng hệ thống tự động tụt FPS khi sạc pin hoặc chơi game nặng
        return (realState >= NSProcessInfoThermalStateSerious) ? NSProcessInfoThermalStateFair : NSProcessInfoThermalStateNominal;
    }
    return realState;
}

- (BOOL)isLowPowerModeEnabled {
    if (Apex_IsMasterEnabled()) return NO; // Chặn chế độ tiết kiệm pin làm giảm tần số quét và hiệu năng
    return %orig;
}
%end

// =================================================================================================
// 6. TOUCH RESPONSIVENESS & UI/UX STUTTER SHIELD (Cảm ứng siêu nhạy 100%, Chống khựng app & Control Center)
// =================================================================================================
%hook UIWindow
- (void)sendEvent:(UIEvent *)event {
    %orig(event);
    if (event.type == UIEventTypeTouches) {
        for (UITouch *touch in [event allTouches]) {
            if (touch.view && touch.view.gestureRecognizers) {
                for (UIGestureRecognizer *rec in touch.view.gestureRecognizers) {
                    rec.delaysTouchesBegan = NO;
                    rec.delaysTouchesEnded = NO;
                }
            }
        }
    }
}
%end

// Tối ưu hóa chuyển cảnh đóng mở ứng dụng, màn hình khóa, trung tâm điều khiển và nhạc nền không giật lag
%hook SBMainWorkspace
- (void)transitionRequestDidComplete:(id)arg1 {
    %orig(arg1);
    // Chủ động dọn dẹp cache render và tối ưu hóa tải CPU ngay sau khi chuyển động giao diện hoàn tất
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        [[NSURLCache sharedURLCache] removeAllCachedResponses];
    });
}
%end

%end

// =================================================================================================
// CONSTRUCTOR — Khởi tạo toàn bộ Supreme Ultimate Engine
// =================================================================================================
%ctor {
    @autoreleasepool {
        %init(TitaniumApexSupremeUltimateGroup);
    }
}
