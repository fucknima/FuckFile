#import <UIKit/UIKit.h>

// Structured property-list editor. Supports nested dictionaries and
// arrays, editing strings/numbers/booleans, adding and deleting entries,
// and saves back to the file (XML or binary, preserving the original
// format). Write failures offer a copy export like the text editor.
@interface FFPlistEditorViewController : UITableViewController

- (instancetype)initWithPath:(NSString *)path;

@end
