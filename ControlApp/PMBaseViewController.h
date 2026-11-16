#import <UIKit/UIKit.h>

@class PMModeChip, PMCustomChip, PMRouteButton;

@interface PMBaseViewController : UIViewController
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *contentStack;
@property (nonatomic, strong) NSMutableArray<PMModeChip *> *modeChips;
@property (nonatomic, strong) NSMutableArray<PMCustomChip *> *customChips;
- (BOOL)pm_isAdminServerActive;
- (void)pm_refreshActiveServerRuntime;
- (void)setupContent;
- (void)clearContent;
- (UIStackView *)newCardWithTitle:(NSString *)title subtitle:(NSString *)subtitle;
- (void)addHeaderWithEyebrow:(NSString *)eyebrow title:(NSString *)title subtitle:(NSString *)subtitle;
- (void)addNote:(NSString *)note toStack:(UIStackView *)stack;
- (void)addRouteRowWithTitle:(NSString *)title subtitle:(NSString *)subtitle route:(NSString *)route symbol:(NSString *)symbol toStack:(UIStackView *)stack;
- (void)addSwitchRows:(NSArray<NSDictionary *> *)rows title:(NSString *)title toStack:(UIStackView *)stack;
- (void)addModePickerForKey:(NSString *)key title:(NSString *)title subtitle:(NSString *)subtitle bundleID:(NSString *)bundleID;
- (void)refreshModeChips;
- (void)showWriteFailure;
- (void)modeTapped:(PMModeChip *)sender;
- (void)customTapped:(PMCustomChip *)sender;
- (void)switchChanged:(UISwitch *)sender;
- (void)routeTapped:(PMRouteButton *)sender;
@end
