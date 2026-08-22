#import <QuickLook/QuickLook.h>

NS_ASSUME_NONNULL_BEGIN

// System Quick Look for files without a dedicated viewer, and as the
// router's fallback preview. Pushed directly onto the caller's stack.
@interface FFQuickLookViewController : QLPreviewController

// Returns nil when the file is unreadable (caller should fall back).
- (nullable instancetype)initWithFilePath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
