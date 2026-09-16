#import <UIKit/UIKit.h>

// Minimal drill-down directory chooser (directories only, rooted at the given
// path). Present it inside a navigation controller; «选择此文件夹» dismisses the
// whole presentation and reports the chosen path. Used by archive extraction
// to pick a destination other than the archive's own folder.
@interface FFDirectoryPickerViewController : UITableViewController

- (instancetype)initWithRootPath:(NSString *)rootPath
                      completion:(void (^)(NSString *path))completion;

@end
