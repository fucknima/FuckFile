#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Path safety primitives for every file mutation.
//
// Threat model: paths may contain symlinks controlled by other apps
// (inside their containers) or by us (the App Data link layer). A plain
// NSFileManager call follows whatever is in place at call time.
//
// Resolution model: our own App Data links are resolved explicitly and
// their /var targets re-validated. Inside the container the sandbox
// cannot openat() the system directory chain (no traversal permission
// without a root-level extension), so validation is lstat-based: every
// level must exist as a real directory, foreign symlinks are rejected,
// and the final parent directory is checked right before the mutation.
// The MHA sandbox extension provides the actual read/write permission.
@interface FFPathPolicy : NSObject

// Absolute path of the app's Documents directory, which is also FuckFile's
// user-visible storage root.
+ (NSString *)documentsRoot;

// Resolves the parent path and final name of `path` for a mutation. The parent
// itself is opened with O_NOFOLLOW immediately before the mutation; AppData
// intermediate links are followed by the kernel only when the active MHA lease
// covers their target. Returns nil and sets *errorMessage on failure.
+ (NSString * _Nullable)resolveParentForMutation:(NSString *)path
                                       finalName:(NSString * _Nullable * _Nullable)finalName
                                   errorMessage:(NSString * _Nullable * _Nullable)errorMessage;

@end

NS_ASSUME_NONNULL_END