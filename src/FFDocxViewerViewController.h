#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Lightweight DOCX-family reader. Spreadsheet/presentation/PDF/iWork formats
// deliberately stay on system Quick Look; this viewer exists only where the
// dedicated Word reading experience is materially better.
@interface FFDocxViewerViewController : UIViewController
- (nullable instancetype)initWithFilePath:(NSString *)path;
@end

NS_ASSUME_NONNULL_END
