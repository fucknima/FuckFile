#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Offline spreadsheet viewer backed by Univer + SheetJS. The original file is
// never uploaded; it is exposed only to this controller's private WKURLScheme.
@interface FFSpreadsheetViewController : UIViewController

- (nullable instancetype)initWithFilePath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
