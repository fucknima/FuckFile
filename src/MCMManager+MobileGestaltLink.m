#import "MCMManager.h"
#import "FFStorageEnvironment.h"
#import "FFLogger.h"
#import <objc/runtime.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString *const FFLegacyMobileGestaltName = @"[MHA-C12] MobileGestalt Cache";
static NSString *const FFMobileGestaltName = @"MobileGestalt";

static void FFRemoveSymlinkIfPresent(NSString *path)
{
    struct stat st = {0};
    if (lstat(path.fileSystemRepresentation, &st) == 0 && S_ISLNK(st.st_mode))
        unlink(path.fileSystemRepresentation);
}

@interface MCMManager (MobileGestaltLink)
- (void)ff_mobileGestalt_runMobileGestaltProbe:(NSString *)root;
@end

@implementation MCMManager (MobileGestaltLink)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method original = class_getInstanceMethod(self, NSSelectorFromString(@"runMobileGestaltProbe:"));
        Method replacement = class_getInstanceMethod(self, @selector(ff_mobileGestalt_runMobileGestaltProbe:));
        if (original && replacement) method_exchangeImplementations(original, replacement);
    });
}

- (void)ff_mobileGestalt_runMobileGestaltProbe:(NSString *)root
{
    if (!root.length) return;

    NSString *legacy = [root stringByAppendingPathComponent:FFLegacyMobileGestaltName];
    NSString *concise = [root stringByAppendingPathComponent:FFMobileGestaltName];

    // MCM leases are process/session scoped. A symlink left by a previous
    // process may still point at a path that exists but is no longer readable.
    // Remove both forms before each probe so this launch always publishes a
    // freshly activated target or nothing at all.
    FFRemoveSymlinkIfPresent(legacy);
    FFRemoveSymlinkIfPresent(concise);

    // After swizzling, this selector invokes the original probe. It currently
    // creates the legacy [MHA-C12] link after validating the target plist.
    [self ff_mobileGestalt_runMobileGestaltProbe:root];

    struct stat st = {0};
    if (lstat(legacy.fileSystemRepresentation, &st) != 0 || !S_ISLNK(st.st_mode)) {
        FFLogTag(@"MCM", @"MobileGestalt refresh did not publish a link");
        return;
    }

    // rename(2) preserves the symlink target verbatim and is atomic inside the
    // same Device Storage directory. This changes only presentation, not the
    // validated MCM target path.
    if (rename(legacy.fileSystemRepresentation, concise.fileSystemRepresentation) == 0) {
        FFLogTag(@"MCM", @"MobileGestalt link refreshed name=%@", FFMobileGestaltName);
    } else {
        FFLogTag(@"MCM", @"MobileGestalt link rename FAIL errno=%d", errno);
    }
}

@end
