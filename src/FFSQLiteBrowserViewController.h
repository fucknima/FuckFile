#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// SQLite3 viewer root page: database summary, tables, views and a free
// SQL query console. Read-only.
@interface FFSQLiteBrowserViewController : UITableViewController

- (nullable instancetype)initWithDatabasePath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
