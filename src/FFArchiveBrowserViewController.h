#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// In-archive directory browser (ZIP/IPA family). Shows the package tree,
// previews/extracts single entries, supports multi-select extraction and
// full extraction via the task center. Formats without a backend show an
// explicit unsupported state instead of pretending.
@interface FFArchiveBrowserViewController : UITableViewController

- (nullable instancetype)initWithArchivePath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
