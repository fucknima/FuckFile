#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Main application shell: persistent bottom navigation plus a floating global
// search affordance. Each tab owns its own UINavigationController so browsing
// stacks are preserved when switching sections.
@interface FFRootTabBarController : UITabBarController

- (UINavigationController *)activeNavigationController;

@end

NS_ASSUME_NONNULL_END
