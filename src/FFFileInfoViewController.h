#import <UIKit/UIKit.h>
#import "FFBrowserViewController.h"

NS_ASSUME_NONNULL_BEGIN

// 文件属性页（ADR-013）：替代原 fullDetail Alert。
// 基础信息来自 FFEntry；慢数据（目录递归统计、xattr、SHA-256）
// 进入页面后后台加载，不阻塞浏览。
@interface FFFileInfoViewController : UITableViewController

- (instancetype)initWithEntry:(FFEntry *)entry icon:(nullable UIImage *)icon;

@end

NS_ASSUME_NONNULL_END
