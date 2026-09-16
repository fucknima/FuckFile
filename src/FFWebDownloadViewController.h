#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// In-app browser for sites that need a login before a file can be downloaded.
// Cookies live in the shared WKWebsiteDataStore (persisted). Navigations that
// produce a download are handed to FFFileTaskManager (NSURLSession) with the
// login headers attached, so progress shows in the task centre, downloads keep
// running after the page is left, and a stopped download can resume.
@interface FFWebDownloadViewController : UIViewController

- (instancetype)initWithDestinationDirectory:(NSString *)directory;
- (instancetype)initWithURL:(nullable NSURL *)url
     destinationDirectory:(NSString *)directory;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
