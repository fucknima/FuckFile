#import <UIKit/UIKit.h>

@class FFSQLiteService;

// One-row editor for ordinary SQLite tables (rowid identity). Changes are
// written through a single BEGIN IMMEDIATE … COMMIT statement list; only
// edited columns are updated. WITHOUT ROWID tables and views are not
// editable and never reach this screen.
@interface FFSQLiteRowEditorViewController : UITableViewController

- (instancetype)initWithService:(FFSQLiteService *)service
                          table:(NSString *)table
                          rowID:(long long)rowID
                        columns:(NSArray<NSString *> *)columns
                         values:(NSDictionary<NSString *, NSString *> *)values
                     completion:(void (^)(BOOL saved))completion;

@end
