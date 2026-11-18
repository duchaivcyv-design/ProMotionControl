#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Safe public bridge to ProMotionControl's canonical active-server settings.
/// A return value of 0 means AUTO / the corresponding override is disabled.
@interface TitaniumSettingsAPI : NSObject
+ (instancetype)sharedAPI;
- (NSInteger)getSelectedHz;
- (NSInteger)getSelectedFPS;
- (BOOL)isEngineEnabled;
- (void)reloadSettings;
- (BOOL)isForceMaxDisplayRateEnabled; // Thêm phương thức mới
- (BOOL)isDisableThermalThrottleEnabled; // Thêm phương thức mới
- (BOOL)isOverclockCPUEnabled; // Thêm phương thức mới
- (BOOL)isOverclockGPUEnabled; // Thêm phương thức mới
@end

FOUNDATION_EXPORT NSInteger Titanium_GetMasterRate(void);
FOUNDATION_EXPORT NSInteger Titanium_GetMasterFPS(void);
FOUNDATION_EXPORT BOOL Apex_IsMasterEnabled(void);
FOUNDATION_EXPORT void Titanium_ForceUpdateRate(NSInteger hz, NSInteger fps);
FOUNDATION_EXPORT NSDictionary *Titanium_LoadSharedConfig(void);
FOUNDATION_EXPORT BOOL g_isCurrentAppBlacklisted;

/// Cached runtime snapshot for hook paths. These never touch the file system on
/// a display-link or audio-session callback; the bridge refreshes them when the
/// settings domain posts com.dell.promotioncontrol.changed.
FOUNDATION_EXPORT NSInteger Titanium_CurrentServerMode(void); // 0 FREE, 1 PREMIUM, 2 ADMIN
FOUNDATION_EXPORT NSInteger Titanium_CurrentTargetHz(void);
FOUNDATION_EXPORT NSInteger Titanium_CurrentTargetFPS(void);
FOUNDATION_EXPORT BOOL Titanium_ConfigBool(NSString *key, BOOL fallback);
FOUNDATION_EXPORT NSInteger Titanium_ConfigInteger(NSString *key, NSInteger fallback);

NS_ASSUME_NONNULL_END
