#import <UIKit/UIKit.h>

@class FFEntry;

NS_ASSUME_NONNULL_BEGIN

// Full file/directory metadata page, replaces the old single Alert.
// xattr / MIME / counts load asynchronously on a background queue.
@interface FFFileInfoViewController : UITableViewController

- (instancetype)initWithEntry:(FFEntry *)entry;

@end

NS_ASSUME_NONNULL_END
