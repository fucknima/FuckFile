#import <UIKit/UIKit.h>

// Image viewer with pinch/double-tap zoom, swipe or toolbar navigation through
// the images of the same folder, share, file info and delete-to-trash.
@interface FFImageViewerViewController : UIViewController

- (instancetype)initWithPath:(NSString *)path;
- (instancetype)init NS_UNAVAILABLE;

@end
