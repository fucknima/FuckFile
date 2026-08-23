#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, FFRootTab) {
    FFRootTabHome = 0,
    FFRootTabFiles = 1,
    FFRootTabSettings = 2,
};

FOUNDATION_EXPORT NSInteger const FFRootTabBarViewTag;

@interface FFRootTabBar : UIView

+ (instancetype)installInViewController:(UIViewController *)viewController
                               selected:(FFRootTab)selected;
+ (void)removeFromViewController:(UIViewController *)viewController;

@end

NS_ASSUME_NONNULL_END
