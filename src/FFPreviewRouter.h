#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class FFEntry;

// Preview routing shared by the browser, search, favorites and recents.
// Every preview is pushed onto the navigation controller passed by the
// caller — no detached view controller instances are created.
@interface FFPreviewRouter : NSObject

// Pushes the appropriate preview for the item (image/video/audio/PDF/
// text/plist/hex) onto nav. Returns YES when a preview was pushed.
+ (BOOL)previewItem:(FFEntry *)item navigationController:(UINavigationController *)nav;

// Text/plist/hex viewer with a share button (used by previewData).
+ (void)presentText:(NSString *)title body:(NSString *)body
    navigationController:(UINavigationController *)nav;

@end

NS_ASSUME_NONNULL_END
