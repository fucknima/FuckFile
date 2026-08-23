#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

// Web viewer: renders local .html/.htm with a read-access root limited to
// the file's own folder, and resolves .url / .webloc shortcuts to their
// target page.
@interface FFWebViewerViewController : UIViewController

- (nullable instancetype)initWithFilePath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
