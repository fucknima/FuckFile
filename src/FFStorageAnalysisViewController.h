#import <UIKit/UIKit.h>

// Device free/used space, app data/cache/trash size and per-category usage
// (images/videos/audio/documents/archives/other) with a cache cleanup action.
// The scan runs off the main thread and is cancelled when the page goes away.
@interface FFStorageAnalysisViewController : UITableViewController

@end
