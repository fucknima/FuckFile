#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *FFRelativeTimeString(NSDate *date);

// Short path for display in lists: "AppData › 微信 › Documents",
// never the raw /private/var/... prefix.
FOUNDATION_EXPORT NSString *FFDisplayPathForPath(NSString *path);

NS_ASSUME_NONNULL_END
