#import "PMAppDelegate.h"
#import "PMControlViewController.h"

static BOOL PMRecoveryUsesLightTheme(void) {
    NSDictionary *domain = [[NSUserDefaults standardUserDefaults] persistentDomainForName:@"com.dell.promotioncontrol"];
    NSString *theme = [domain[@"Theme"] isKindOfClass:[NSString class]] ? domain[@"Theme"] : @"dark";
    return [theme.lowercaseString isEqualToString:@"light"];
}
static void PMShowTypingIntro(UIWindow *window) {
    if (!window) return;
    UIView *overlay = [[UIView alloc] initWithFrame:window.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [UIColor colorWithRed:8.0/255.0 green:6.0/255.0 blue:17.0/255.0 alpha:1.0];
    overlay.alpha = 1.0;

    UILabel *brand = [[UILabel alloc] initWithFrame:CGRectMake(20, 0, MAX(240.0, CGRectGetWidth(window.bounds) - 40.0), 190)];
    brand.center = CGPointMake(CGRectGetMidX(window.bounds), CGRectGetMidY(window.bounds));
    brand.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    brand.textAlignment = NSTextAlignmentCenter;
    brand.numberOfLines = 0;
    brand.textColor = UIColor.whiteColor;
    brand.font = [UIFont monospacedSystemFontOfSize:17.0 weight:UIFontWeightSemibold];
    brand.adjustsFontSizeToFitWidth = YES;
    brand.minimumScaleFactor = 0.75;
    [overlay addSubview:brand];

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(20, CGRectGetMaxY(brand.frame) + 14.0, MAX(240.0, CGRectGetWidth(window.bounds) - 40.0), 24)];
    hint.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    hint.textAlignment = NSTextAlignmentCenter;
    hint.textColor = [UIColor colorWithRed:171.0/255.0 green:207.0/255.0 blue:225.0/255.0 alpha:1.0];
    hint.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
    hint.text = @"Đang khởi tạo giao diện an toàn…";
    [overlay addSubview:hint];
    [window addSubview:overlay];

    NSString *appVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (![appVersion isKindOfClass:[NSString class]] || appVersion.length == 0) appVersion = @"5.8.48";
    NSString *fullText = [NSString stringWithFormat:@"ProMotion Control\nVersion %@t\nTác giả:Nguyễn Minh Hải,TaoJB\nMã nguồn: Nguyễn Minh Hải ( chờ ngày quay trở lại )", appVersion];
    __block NSUInteger position = 0;
    __block void (^typeNext)(void) = nil;
    __weak UILabel *weakBrand = brand;
    __weak UIView *weakOverlay = overlay;
    typeNext = ^{
        UILabel *label = weakBrand;
        UIView *cover = weakOverlay;
        if (!label || !cover) { typeNext = nil; return; }
        if (position < fullText.length) {
            position++;
            label.text = [fullText substringToIndex:position];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.035 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), typeNext);
        } else {
            typeNext = nil;
        }
    };
    typeNext();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.25 animations:^{
            overlay.alpha = 0.0;
        } completion:^(__unused BOOL finished) {
            [overlay removeFromSuperview];
        }];
    });
}

static UIColor *PMRecoveryBackground(void) {
    return PMRecoveryUsesLightTheme()
        ? [UIColor colorWithRed:244.0/255.0 green:248.0/255.0 blue:253.0/255.0 alpha:1.0]
        : [UIColor colorWithRed:8.0/255.0 green:6.0/255.0 blue:17.0/255.0 alpha:1.0];
}
static UIColor *PMRecoveryTextColor(void) {
    return PMRecoveryUsesLightTheme()
        ? [UIColor colorWithRed:18.0/255.0 green:31.0/255.0 blue:49.0/255.0 alpha:1.0]
        : UIColor.whiteColor;
}
static UIColor *PMRecoveryMutedTextColor(void) {
    return PMRecoveryUsesLightTheme()
        ? [UIColor colorWithRed:77.0/255.0 green:94.0/255.0 blue:115.0/255.0 alpha:1.0]
        : [UIColor colorWithWhite:0.78 alpha:1.0];
}
static UIColor *PMRecoveryAccent(void) {
    return [UIColor colorWithRed:168.0/255.0 green:61.0/255.0 blue:255.0/255.0 alpha:1.0];
}

@interface PMRecoveryLaunchController : UIViewController
@property (nonatomic, strong) UIImageView *brandImageView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *openButton;
@end

@implementation PMRecoveryLaunchController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = PMRecoveryBackground();

    // Intentionally use frame/autoresizing-based layout in recovery UI. This screen
    // must be as small and dependency-light as possible when diagnosing launch crashes.
    NSString *iconPath = [[NSBundle mainBundle] pathForResource:@"AppIcon60x60@3x" ofType:@"png"];
    UIImage *icon = iconPath.length ? [UIImage imageWithContentsOfFile:iconPath] : nil;
    if (!icon) {
        iconPath = [[NSBundle mainBundle] pathForResource:@"AppIcon60x60@2x" ofType:@"png"];
        icon = iconPath.length ? [UIImage imageWithContentsOfFile:iconPath] : nil;
    }
    self.brandImageView = [[UIImageView alloc] initWithImage:icon];
    self.brandImageView.frame = CGRectMake(0, 0, 84, 84);
    self.brandImageView.contentMode = UIViewContentModeScaleAspectFit;
    self.brandImageView.layer.cornerRadius = 18.0;
    self.brandImageView.clipsToBounds = YES;
    [self.view addSubview:self.brandImageView];

    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.titleLabel.text = @"ProMotion Control";
    self.titleLabel.textColor = PMRecoveryTextColor();
    self.titleLabel.font = [UIFont systemFontOfSize:24.0 weight:UIFontWeightBold];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.numberOfLines = 1;
    [self.view addSubview:self.titleLabel];

    self.subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.subtitleLabel.text = @"Chế độ khởi động an toàn";
    self.subtitleLabel.textColor = PMRecoveryMutedTextColor();
    self.subtitleLabel.font = [UIFont systemFontOfSize:14.0];
    self.subtitleLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.subtitleLabel];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statusLabel.text = @"Ứng dụng đã mở ở chế độ an toàn. Nhấn nút bên dưới để thử giao diện đầy đủ.";
    self.statusLabel.textColor = PMRecoveryMutedTextColor();
    self.statusLabel.font = [UIFont systemFontOfSize:13.0];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    [self.view addSubview:self.statusLabel];

    self.openButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.openButton.backgroundColor = PMRecoveryAccent();
    self.openButton.layer.cornerRadius = 16.0;
    [self.openButton setTitle:@"Mở giao diện ProMotion Control" forState:UIControlStateNormal];
    [self.openButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.openButton.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    [self.openButton addTarget:self action:@selector(openMainInterface:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.openButton];
    [self layoutRecoveryViews];
    NSLog(@"[ProMotionControl] Minimal launch recovery screen initialized.");
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutRecoveryViews];
}

- (void)layoutRecoveryViews {
    if (!self.isViewLoaded) return;
    CGFloat width = CGRectGetWidth(self.view.bounds);
    CGFloat height = CGRectGetHeight(self.view.bounds);
    CGFloat safeTop = self.view.safeAreaInsets.top;
    CGFloat contentWidth = MAX(240.0, width - 40.0);
    CGFloat centerY = safeTop + (height - safeTop - self.view.safeAreaInsets.bottom) * 0.5;
    CGFloat blockHeight = 84.0 + 18.0 + 34.0 + 10.0 + 22.0 + 18.0 + 58.0 + 20.0 + 52.0;
    CGFloat top = MAX(safeTop + 24.0, centerY - blockHeight * 0.5);
    CGFloat x = (width - contentWidth) * 0.5;
    self.brandImageView.frame = CGRectMake((width - 84.0) * 0.5, top, 84.0, 84.0);
    self.titleLabel.frame = CGRectMake(x, top + 102.0, contentWidth, 34.0);
    self.subtitleLabel.frame = CGRectMake(x, top + 146.0, contentWidth, 22.0);
    self.statusLabel.frame = CGRectMake(x, top + 176.0, contentWidth, 58.0);
    self.openButton.frame = CGRectMake(x, top + 252.0, contentWidth, 52.0);
}

- (void)openMainInterface:(id)sender {
    (void)sender;
    self.openButton.enabled = NO;
    self.statusLabel.text = @"Đang mở giao diện chính…";
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIViewController *root = [PMControlViewController makeAppRootController];
            if (!root) {
                self.statusLabel.text = @"Không tạo được giao diện chính. Ứng dụng vẫn ở chế độ an toàn.";
                self.openButton.enabled = YES;
                return;
            }
            UIWindow *window = self.view.window ?: self.viewIfLoaded.window;
            if (!window) {
                self.statusLabel.text = @"Không tìm thấy cửa sổ ứng dụng. Vui lòng gửi log khởi động.";
                self.openButton.enabled = YES;
                return;
            }
            // Replace the recovery root instead of presenting a second root
            // controller modally; this keeps a single clear UIKit lifecycle.
            window.rootViewController = root;
            [window makeKeyAndVisible];
            NSLog(@"[ProMotionControl] Full interface root installed.");
        } @catch (NSException *exception) {
            NSLog(@"[ProMotionControl] Full interface creation exception: %@: %@\n%@",
                  exception.name, exception.reason, exception.callStackSymbols);
            self.statusLabel.text = [NSString stringWithFormat:@"Giao diện chính gặp lỗi: %@. Ứng dụng vẫn ở chế độ an toàn.", exception.reason ?: exception.name ?: @"NSException"];
            self.openButton.enabled = YES;
        }
    });
}

@end

@implementation PMAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)launchOptions;
    NSLog(@"[ProMotionControl] didFinishLaunching bundle=%@ executable=%@ iOS=%@",
          NSBundle.mainBundle.bundleIdentifier ?: @"(none)",
          NSBundle.mainBundle.executablePath ?: @"(none)",
          UIDevice.currentDevice.systemVersion ?: @"(unknown)");
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.backgroundColor = PMRecoveryBackground();
    if (@available(iOS 13.0, *)) {
        self.window.overrideUserInterfaceStyle = PMRecoveryUsesLightTheme() ? UIUserInterfaceStyleLight : UIUserInterfaceStyleDark;
    }

    // Normal startup should open the real five-tab interface immediately. The
    // recovery controller is a fallback only when the root hierarchy genuinely
    // cannot be constructed; previously it was installed unconditionally, which
    // caused the safe-mode splash shown in the user's video on every launch.
    UIViewController *initialRoot = nil;
    @try {
        initialRoot = [PMControlViewController makeAppRootController];
        if (!initialRoot) {
            NSLog(@"[ProMotionControl] Main root factory returned nil; using recovery UI.");
        }
    } @catch (NSException *exception) {
        NSLog(@"[ProMotionControl] Main root creation failed: %@: %@\n%@",
              exception.name, exception.reason, exception.callStackSymbols);
    }
    self.window.rootViewController = initialRoot ?: [PMRecoveryLaunchController new];
    [self.window makeKeyAndVisible];
    PMShowTypingIntro(self.window);
    return YES;
}

- (UIInterfaceOrientationMask)application:(UIApplication *)application
 supportedInterfaceOrientationsForWindow:(UIWindow *)window
{
    (void)application;
    (void)window;
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        return UIInterfaceOrientationMaskAll;
    }
    return UIInterfaceOrientationMaskPortrait |
           UIInterfaceOrientationMaskLandscapeLeft |
           UIInterfaceOrientationMaskLandscapeRight;
}

@end
