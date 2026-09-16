#import <UIKit/UIKit.h>

// Whole-storage recursive search page with persisted history. Recursive
// searching already exists inside the browser at the storage root; this page
// adds a first-class entry point, incremental results with relative paths and
// a search history (NSUserDefaults, newest first).
@interface FFGlobalSearchViewController : UIViewController

@end
