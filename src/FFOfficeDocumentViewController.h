#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Offline reader for Office formats that do not have a dedicated native/app
// viewer. Modern/legacy Word and PowerPoint use Ream for layout-preserving
// HTML; ODF/iWork/WPS/RTF use a structured local fallback. Quick Look remains
// available only as an explicit manual fallback from the viewer menu.
@interface FFOfficeDocumentViewController : UIViewController

- (nullable instancetype)initWithFilePath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
