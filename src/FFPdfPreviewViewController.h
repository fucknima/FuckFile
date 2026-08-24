#import <UIKit/UIKit.h>

// Native PDFKit reader: page indicator/jump, search with previous/next,
// thumbnails, outline navigation, reading modes, zoom presets, history,
// encrypted-document unlock, share and file-info handoff. Read-only by design.
@interface FFPdfPreviewViewController : UIViewController
- (instancetype)initWithPath:(NSString *)path;
@end
