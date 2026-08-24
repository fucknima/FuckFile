#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Apple .ips 系统诊断查看器（viewerID: diagnostic）。
// 解析在后台执行；失败/截断/压缩炸弹均以明确状态行展示，不允许
// 主线程阻塞或 OOM。RHWN payload 只展示可可靠识别的信息。
@interface FFDiagnosticViewController : UITableViewController

- (instancetype)initWithFilePath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
