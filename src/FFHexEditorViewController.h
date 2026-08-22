#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Paged hex viewer/editor. Reads via open/pread in ~64 KiB pages (never
// the whole file), renders OFFSET/HEX/ASCII rows, supports offset jumps
// and byte edits held in an in-memory patch map until explicit save.
//
// Save goes through FFPathPolicy validation and writes single bytes via
// pwrite with O_NOFOLLOW; on any failure previously written bytes are
// rolled back from the cached originals so the source file is never left
// half-modified.
@interface FFHexEditorViewController : UITableViewController

- (nullable instancetype)initWithFilePath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
