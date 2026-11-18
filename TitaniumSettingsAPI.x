// =================================================================================================
// TitaniumSettingsAPI.x
// This file provides the concrete definitions for shared symbols
// (variables and functions) that are declared as `extern` in other .x files.
// This centralizes their implementation and resolves linker errors.
//
// NÂNG CẤP: PM_ExportMasterRate giờ đây đọc giá trị từ preference bundle
// và đảm bảo giá trị trả về nằm trong khoảng 10-240Hz, với 120Hz là mặc định.
//
// SỬA LỖI: Đã loại bỏ [prefs release]; vì dự án sử dụng ARC.
// =================================================================================================

#import <substrate.h> // Cần thiết cho Logos/Objective-C
#import <Foundation/Foundation.h> // Cần thiết để sử dụng NSUserDefaults

// Định nghĩa biến toàn cục Titanium_SharedRealThermalState
// Biến này được các module khác đọc và ghi (như Overdrive và Supreme)
// Khởi tạo giá trị mặc định là Nominal (0)
volatile NSInteger Titanium_SharedRealThermalState = 0;

// Hằng số cho Preference Bundle ID và Key
static NSString *const kProMotionControlBundleID = @"com.promotioncontrol.preferences";
static NSString *const kMasterRateKey = @"MasterRate";

// Định nghĩa hàm PM_ExportMasterRate
// Hàm này sẽ đọc giá trị Master Rate từ preference bundle.
// Nếu không có giá trị nào được lưu, nó sẽ trả về 120Hz mặc định.
// Nó cũng đảm bảo giá trị nằm trong khoảng an toàn 10-240Hz.
NSInteger PM_ExportMasterRate(void) {
    @autoreleasepool {
        // Lấy NSUserDefaults cho bundle ID của tweak.
        // Đây là cách chuẩn để truy cập cài đặt từ PreferenceLoader.
        NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kProMotionControlBundleID];
        
        // Đọc giá trị MasterRate. Giá trị mặc định nếu không tìm thấy là 120.
        // Mày có thể thay đổi giá trị mặc định này nếu muốn.
        NSInteger savedRate = [prefs integerForKey:kMasterRateKey];
        
        // Đã xóa [prefs release]; vì dự án sử dụng ARC. ARC sẽ tự quản lý bộ nhớ cho prefs.

        NSInteger finalRate = 0;

        // Đảm bảo giá trị nằm trong khoảng 10-240Hz
        if (savedRate >= 10 && savedRate <= 240) {
            finalRate = savedRate;
        } else {
            // Nếu giá trị không hợp lệ (ví dụ: 0 hoặc ngoài phạm vi), dùng giá trị mặc định
            finalRate = 120;
        }
        
        NSLog(@"[ProMotionControl::TitaniumSettingsAPI] Master Rate đọc từ cài đặt: %ld (ban đầu: %ld)", (long)finalRate, (long)savedRate);
        return finalRate;
    }
}

// Nếu có các hàm hoặc biến extern khác, hãy định nghĩa chúng ở đây.
// Ví dụ về một hàm để thiết lập Master Rate (nếu cần cho các phần khác của tweak)
// void Titanium_SetMasterRate(NSInteger newRate) {
//     @autoreleasepool {
//         NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kProMotionControlBundleID];
//         NSInteger safeNewRate = newRate;
//         if (safeNewRate < 10) safeNewRate = 10;
//         if (safeNewRate > 240) safeNewRate = 240;
//         [prefs setInteger:safeNewRate forKey:kMasterRateKey];
//         [prefs synchronize]; // Đồng bộ hóa ngay lập tức
//         NSLog(@"[ProMotionControl::TitaniumSettingsAPI] Master Rate đã được thiết lập thành: %ld", (long)safeNewRate);
//         // Đã xóa [prefs release]; vì dự án sử dụng ARC.
//     }
// }
