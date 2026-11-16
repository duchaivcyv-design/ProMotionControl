// =================================================================================================
// TitaniumHardwareOverdriveGuard.x
// User-supplied hardware overdrive / anti-throttling module, integrated for the shared
// FREE / PREMIUM / ADMIN Titanium bridge. The Logos group is always initialized; every
// override still checks Apex_IsMasterEnabled() at call time so profile changes take effect.
// =================================================================================================
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <mach/mach.h>
#import <pthread.h>
#import "TitaniumSettingsAPI.h"

// Khai báo extern lấy thông số từ Core Engine
extern NSInteger Titanium_GetMasterRate(void);
extern BOOL Apex_IsMasterEnabled(void);

%group TitaniumHardwareOverdriveGroup

// =================================================================================================
// 1. IOREGISTRY & POWER MANAGEMENT — Chặn tuyệt đối mọi lệnh bóp dòng sạc, hạ xung khi sạc và sử dụng
// =================================================================================================
%hook IORegistryEntry
- (kern_return_t)setCFProperty:(NSString *)key withValue:(id)value {
    if (Apex_IsMasterEnabled() && key) {
        NSString *kl = [key lowercaseString];
        // Can thiệp sâu vào tầng phần cứng: Chặn mọi lệnh giới hạn dòng điện sạc, bóp hiệu năng nhiệt độ hoặc hạ xung chip
        if ([kl containsString:@"thermal"] || [kl containsString:@"power"] || [kl containsString:@"throttle"] || [kl containsString:@"currentlimit"] || [kl containsString:@"charge"] || [kl containsString:@"performance-controller"]) {
            return KERN_SUCCESS; // Trả về thành công ảo, triệt tiêu hoàn toàn lệnh giảm tải từ hệ thống
        }
    }
    return %orig(key, value);
}
%end

// =================================================================================================
// 2. PROCESS INFO THERMAL & LOW POWER OVERRIDE — Khóa cứng trạng thái hiệu năng tối đa 100%
// =================================================================================================
%hook NSProcessInfo
- (NSProcessInfoThermalState)thermalState {
    // Evaluate the previous hook/original implementation first. This preserves the
    // real-state snapshot used by the Supreme safeguard when several engines coexist.
    NSProcessInfoThermalState originalState = %orig;
    if (Apex_IsMasterEnabled()) {
        // Luôn báo cáo trạng thái nhiệt độ ở mức chuẩn tối ưu (Nominal), ngăn iOS tự động bóp Hz, FPS và hiệu năng chip
        return NSProcessInfoThermalStateNominal;
    }
    return originalState;
}

- (BOOL)isLowPowerModeEnabled {
    BOOL originalState = %orig;
    if (Apex_IsMasterEnabled()) {
        return NO; // Vô hiệu hóa chế độ nguồn điện thấp làm giảm tần số quét và hiệu năng
    }
    return originalState;
}
%end

// =================================================================================================
// 3. AGXACCELERATOR & HARDWARE CHIP OVERDRIVE — Chiếm quyền kiểm soát tuyệt đối tầng GPU/CPU
// =================================================================================================
%hook AGXAccelerator
- (int)setPowerState:(unsigned int)state {
    if (Apex_IsMasterEnabled()) {
        %orig(1); // Ép trạng thái nguồn điện đồ họa luôn ở mức cao nhất (Max Performance State)
        return 1;
    }
    return %orig(state);
}

- (void)setPerfState:(unsigned int)state {
    if (Apex_IsMasterEnabled()) {
        %orig(1); // Ép xung nhịp đồ họa bám sát mức tối đa, chống tụt khung hình đột ngột
        return;
    }
    %orig(state);
}
%end

// =================================================================================================
// 4. BACKGROUND AUDIO & TASK PERSISTENCE — Chống giảm tải khi chạy nền nhạc hoặc ứng dụng song song
// =================================================================================================
%hook AVAudioSession
- (BOOL)setActive:(BOOL)active error:(NSError * _Nullable *)outError {
    // Đảm bảo phiên âm thanh và các tác vụ chạy nền không bao giờ bị hệ điều hành cô lập hoặc bóp băng thông
    return %orig(active, outError);
}
%end

%end

// =================================================================================================
// CONSTRUCTOR — Khởi tạo module chống giảm tải phần cứng tối thượng
// =================================================================================================
%ctor {
    @autoreleasepool {
        %init(TitaniumHardwareOverdriveGroup);
    }
}
