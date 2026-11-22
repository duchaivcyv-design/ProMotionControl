// =================================================================================================
// TitaniumCrossAppBypassEngine.x
// User-supplied cross-app CADisplayLink/UIScreen module, connected to the same
// FREE / PREMIUM / ADMIN preference snapshot as the other Titanium engines.
// The package filter remains intentionally scoped to the control app; no sandbox or
// RootHide privilege is created by this source. The hooks are ready wherever the
// package is explicitly injected and use the blacklist on every call.
// =================================================================================================
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <math.h>
#import "TitaniumSettingsAPI.h"

// Khai báo extern lấy thông số Hz & FPS chuẩn xác từ Core API
extern NSInteger Titanium_GetMasterRate(void);
extern NSInteger Titanium_GetMasterFPS(void);
extern BOOL Apex_IsMasterEnabled(void);
extern BOOL g_isCurrentAppBlacklisted;

// A profile may select only Hz or only FPS. Reuse the other selected value rather
// than turning an AUTO (0) value into an unintended 10 Hz/FPS request.
static inline NSInteger Titanium_CrossAppEffectiveRate(void) {
    NSInteger rate = Titanium_GetMasterRate();
    if (rate <= 0) rate = Titanium_GetMasterFPS();
    return MIN(MAX(rate, 10), 244);
}

static inline NSInteger Titanium_CrossAppEffectiveFPS(void) {
    NSInteger fps = Titanium_GetMasterFPS();
    if (fps <= 0) fps = Titanium_GetMasterRate();
    return MIN(MAX(fps, 10), 244);
}

%group TitaniumCrossAppBypassGroup

// =================================================================================================
// 1. CROSS-APP CADISPLAYLINK OVERRIDE — Vượt rào Sandbox / RootHide để áp dụng Hz/FPS chuẩn cho mọi App
// =================================================================================================
%hook CADisplayLink
- (void)setPreferredFrameRateRange:(CAFrameRateRange)range {
    if (Apex_IsMasterEnabled() && !g_isCurrentAppBlacklisted) {
        NSInteger targetHz = Titanium_CrossAppEffectiveRate();

        // Khai báo chính xác thông số Hz đã chọn một cách thông minh, cân bằng (giới hạn an toàn từ 10 đến 244Hz)
        // Đảm bảo min, max, preferred đều bám sát mức ngườ dùng cài đặt mà không gây tràn bộ đệm phần cứng
        float clampedHz = (float)fmax(10, fmin(targetHz, 244));
        CAFrameRateRange preciseRange = CAFrameRateRangeMake(clampedHz, clampedHz, clampedHz);

        %orig(preciseRange);
        return;
    }
    %orig(range);
}

- (void)setPreferredFramesPerSecond:(NSInteger)fps {
    if (Apex_IsMasterEnabled() && !g_isCurrentAppBlacklisted) {
        NSInteger targetFPS = Titanium_CrossAppEffectiveFPS();

        // Ép buộc chính xác thông số FPS đã chọn cho mọi ứng dụng bên thứ ba và game bị chặn trong Sandbox
        NSInteger clampedFPS = fmax(10, fmin(targetFPS, 244));
        %orig(clampedFPS);
        return;
    }
    %orig(fps);
}
%end

// =================================================================================================
// 2. UISCREEN REFRESH RATE BYPASS — Bẻ khóa giới hạn hiển thị bên trong các Engine game/app nặng
// =================================================================================================
%hook UIScreen
- (id)currentMode {
    id origMode = %orig;
    if (Apex_IsMasterEnabled() && !g_isCurrentAppBlacklisted) {
        // Cho phép app nhận diện thông số hiển thị mượt mà theo cấu hình ngườ dùng
        return origMode;
    }
    return origMode;
}

- (CADisplayLink *)displayLinkWithTarget:(id)target selector:(SEL)sel {
    CADisplayLink *link = %orig(target, sel);
    if (Apex_IsMasterEnabled() && !g_isCurrentAppBlacklisted) {
        NSInteger targetHz = Titanium_CrossAppEffectiveRate();
        if (@available(iOS 15.0, *)) {
            float hzFloat = (float)targetHz;
            link.preferredFrameRateRange = CAFrameRateRangeMake(hzFloat, hzFloat, hzFloat);
        } else {
            link.preferredFramesPerSecond = targetHz;
        }
    }
    return link;
}
%end

%end

// =================================================================================================
// CONSTRUCTOR — Khởi tạo module vượt rào xuyên ứng dụng
// =================================================================================================
static inline BOOL Titanium_ProcessIsSystemOrControl(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    return [bid isEqualToString:@"com.apple.springboard"] ||
           [bid isEqualToString:@"com.dell.promotioncontrol.app"];
}

%ctor {
    @autoreleasepool {
        if (!Titanium_ProcessIsSystemOrControl()) return; // other UIKit apps: no heavy hooks
        // Initialize once and let the per-call master/blacklist gates react to live
        // profile changes, including enabling a server after process launch.
        %init(TitaniumCrossAppBypassGroup);
    }
}
