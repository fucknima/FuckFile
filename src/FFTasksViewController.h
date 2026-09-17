#import <UIKit/UIKit.h>

// Task center: live queue of copy/move/extract operations with progress
// bars, cancel and history cleanup.
@interface FFTasksViewController : UITableViewController

// 点击已完成任务时回调目标路径（文件或目录）；由宿主负责关闭页面并跳转。
@property(nonatomic, copy, nullable) void (^revealHandler)(NSString *path);

@end
