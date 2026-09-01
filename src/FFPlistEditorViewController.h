#import <UIKit/UIKit.h>

// Structured plist safety boundary. Both content routing and the editor itself
// use this ceiling so a .plist file cannot bypass the large-file guard merely
// because it has an explicit extension association.
FOUNDATION_EXPORT const unsigned long long FFPlistEditorMaximumEditableBytes;

// Structured property-list browser/editor. XML and binary formats are preserved;
// nested dictionaries/arrays share one document lifecycle with dirty tracking,
// conflict detection and atomic save verification.
@interface FFPlistEditorViewController : UITableViewController

- (instancetype)initWithPath:(NSString *)path;

@end
