#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Scans the device-local LaunchServices store inside the given lsd service
// container root and returns candidate installed-app bundle identifiers.
//
// iOS 26 hides third-party apps from the normal ContainerManager and
// LaunchServices enumeration APIs, but the store database still contains
// every installed identifier. Candidates are extracted with a byte-range
// scan and must be confirmed with a direct ContainerManager lookup by the
// caller.
//
// Results are cached in <Documents>/LSIdentifierCache.plist. The cache is
// keyed by a store fingerprint built from file name, size, mtime and inode,
// so equal byte sizes can no longer hide a changed LaunchServices database.
NSArray<NSString *> *FFLSDiscoverInstalledIdentifiers(NSString *lsdContainerRoot,
                                                      NSUInteger maxCandidates);

// Same store scan, but returns "group.<team>.<name>" App Group candidates
// so the caller can confirm them with class-7 lookups. Cached separately.
NSArray<NSString *> *FFLSDiscoverGroupIdentifiers(NSString *lsdContainerRoot,
                                                  NSUInteger maxCandidates);

// Cheap fingerprint of the current LaunchServices store set. Returns nil when
// no readable store is present. Callers can use it to skip repeated deep
// validation when the database has not changed.
NSString * _Nullable FFLSStoreFingerprint(NSString *lsdContainerRoot);

// Removes the parsed identifier caches. This does not touch App Data or any
// system file; it only forces the next discovery pass to reparse csstore.
void FFLSInvalidateDiscoveryCaches(void);

NS_ASSUME_NONNULL_END
