#import <UIKit/UIKit.h>

// Native PDF reader: PDFView with page thumbnails, page jump, zoom and
// a share button. Read-only by design.
@interface FFPdfPreviewViewController : UIViewController

- (instancetype)initWithPath:(NSString *)path;

@end
