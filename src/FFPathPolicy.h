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

// The absolute path the virtual root (Device Storage) sits under.
+ (NSString *)documentsRoot;

// YES when the path is (or is below) one of our App Data links: a
// symlink whose target points into /var/.../Containers/...
// Resolves the parent path and final name of `path` for a mutation:
// returns the real parent directory (with our App Data link segments
// replaced by their container targets) and, in *finalName, the entry
// name to operate on. Validates every level with lstat: intermediate
// foreign symlinks are rejected, and the resolved parent must exist as
// a real directory. Returns nil and sets *errorMessage on failure.
// This is the single entry point used by FFFileOperationService.
+ (NSString * _Nullable)resolveParentForMutation:(NSString *)path
                                       finalName:(NSString * _Nullable * _Nullable)finalName
                                   errorMessage:(NSString * _Nullable * _Nullable)errorMessage;

@end

NS_ASSUME_NONNULL_END
