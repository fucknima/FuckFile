#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class FFPathBreadcrumbItem;

// Compact single-line path navigation bar shown under the navigation bar:
// "设备存储 › AppData › 微信 › Documents". Ancestors are tappable and push
// a browser for that path through the receiver's navigation controller.
// Hidden when there is nothing above the root (single item).
@interface FFPathBreadcrumbView : UIView

@property(nonatomic, weak, nullable) UINavigationController *navigationController;
@property(nonatomic, copy, readonly, nonnull) NSString *path;

- (instancetype)initWithPath:(NSString *)path;

@end

@interface FFPathBreadcrumbItem : NSObject
@property(nonatomic, copy) NSString *label;
@property(nonatomic, copy, nullable) NSString *path;
@property(nonatomic) BOOL active;
@property(nonatomic) BOOL isEllipsis;
@end

NS_ASSUME_NONNULL_END
