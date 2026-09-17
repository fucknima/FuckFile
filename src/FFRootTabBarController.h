#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Main application shell: persistent bottom navigation plus a floating global
// search affordance. Each tab owns its own UINavigationController so browsing
// stacks are preserved when switching sections.
@interface FFRootTabBarController : UITabBarController

- (UINavigationController *)activeNavigationController;

// 打开任务中心（模态，内部接好「点击已完成任务跳转」）。
// 所有入口（任务胶囊、网页下载条）都走这里，保证跳转接线一致。
- (void)presentTaskCenter;

@end

NS_ASSUME_NONNULL_END
