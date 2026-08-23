#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Lazy filesystem metadata: nothing here ever runs during directory scans.
// Each call performs its own I/O and is safe to run on a background queue.
FOUNDATION_EXPORT NSArray<NSString *> *FFExtendedAttributeSummaries(NSString *path); // "name (N bytes)" entries
FOUNDATION_EXPORT NSString *_Nullable FFMimeTypeForPath(NSString *path);
FOUNDATION_EXPORT NSString *FFPermissionString(mode_t mode);
FOUNDATION_EXPORT NSString *FFSHA256OfPath(NSString *path);
FOUNDATION_EXPORT unsigned long long FFDirectorySizeAtPath(NSString *path);
FOUNDATION_EXPORT NSUInteger FFItemCountAtPath(NSString *path);

NS_ASSUME_NONNULL_END
