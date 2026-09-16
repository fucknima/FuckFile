#import <UIKit/UIKit.h>

// iPad-only two-column shell (locations sidebar + file browser). The iPhone
// keeps the tab bar layout; FFRootTabBarController picks this shell only when
// the idiom is iPad and still hosts the task pill above the tab bar.
@interface FFMainSplitViewController : UISplitViewController

// Navigation controller of the detail column; used by the app delegate for
// import result navigation on iPad.
- (UINavigationController *)activeNavigationController;

@end
