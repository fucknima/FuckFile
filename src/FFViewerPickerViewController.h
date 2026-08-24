#import <UIKit/UIKit.h>

@class FFEntry;

// 列表式查看器选择（ADR-014）：替代超长 Action Sheet。
// 两种用途共用一份列表 UI：
// - initWithFile: → 「用其他查看器打开」：选中后写入覆盖关联并立即打开；
// - initWithExtension: → 「文件关联」编辑：选中后仅写入覆盖关联。
@interface FFViewerPickerViewController : UITableViewController

- (instancetype)initWithFile:(FFEntry *)item;
- (instancetype)initWithExtension:(NSString *)extension;

@end
