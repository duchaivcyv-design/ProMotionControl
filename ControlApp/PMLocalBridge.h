#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Optional client for a separately installed, root-owned ADMIN daemon.
// Only the three documented, non-arbitrary protocol messages are accepted.
@interface PMLocalBridge : NSObject
+ (void)sendLocalCommand:(NSString *)command
              completion:(void (^)(BOOL success, NSString *response))completion;
+ (BOOL)sendLocalCommand:(NSString *)command
          responseOutput:(NSString * _Nullable __autoreleasing *)responseOutput;
@end

NS_ASSUME_NONNULL_END
