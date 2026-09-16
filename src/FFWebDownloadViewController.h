#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// In-app browser for sites that need a login before a file can be downloaded.
// Cookies live in the shared WKWebsiteDataStore (persisted), and navigations
// that produce a download are taken over by WKDownload and saved atomically
// into the destination directory through the same unique-name rules as the
// rest of the app.
@interface FFWebDownloadViewController : UIViewController

- (instancetype)initWithDestinationDirectory:(NSString *)directory;
- (instancetype)initWithURL:(nullable NSURL *)url
     destinationDirectory:(NSString *)directory;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
