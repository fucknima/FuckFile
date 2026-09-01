#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// 单行路径导航条（ADR-013）：横向滚动、上级可点、当前目录加粗。
// 只负责显示与点击回调，跳转由 Browser 的导航模型完成。
@interface FFPathBreadcrumbView : UIView

// names 为显示用组件（如 Documents › AppData › 微信），
// selectedIndex 为当前目录；点击任意组件回调 index。
- (void)setComponentNames:(NSArray<NSString *> *)names
             selectedIndex:(NSUInteger)index
                    target:(id)target
                    action:(SEL)action;

@end

NS_ASSUME_NONNULL_END