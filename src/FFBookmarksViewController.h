#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, FFBookmarksMode) {
    FFBookmarksModeFavorites = 0,
    FFBookmarksModeRecent,
};

// Shared list UI for favorites and recently-accessed locations.
@interface FFBookmarksViewController : UITableViewController

- (instancetype)initWithMode:(FFBookmarksMode)mode;

@end
