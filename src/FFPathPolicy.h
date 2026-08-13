#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Path safety primitives for every file mutation.
//
// Threat model: paths may contain symlinks controlled by other apps
// (inside their containers) or by us (the App Data link layer). A plain
// NSFileManager call follows whatever is in place at call time, so a
// concurrently swapped symlink can redirect an operation. Every mutation
// therefore goes through an openat()-based chain: the parent directory is
// opened level by level with O_NOFOLLOW, our own app links are resolved
// explicitly, and the final entry is operated on relative to that fd.
@interface FFPathPolicy : NSObject

// The absolute path the virtual root (Device Storage) sits under.
+ (NSString *)documentsRoot;

// YES when the path is inside our own sandbox documents tree.
+ (BOOL)isInsideDocuments:(NSString *)path;

// YES when the path is (or is below) one of our App Data links: a
// symlink whose target points into /var/.../Containers/...
+ (BOOL)isAppLinkPath:(NSString *)path;

// Resolves the path for mutation and returns an open directory fd for
// its parent (O_NOFOLLOW per level; our app links followed by reading
// the link and revalidating the target). The caller owns and must
// close the returned fd. The final name component is NOT resolved.
// Returns -1 and sets *errorMessage on failure.
+ (int)openParentDirectoryForPath:(NSString *)path
                           isFinalDirectory:(BOOL)isFinalDirectory
                       errorMessage:(NSString * _Nullable * _Nullable)errorMessage;

@end

NS_ASSUME_NONNULL_END
