#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Cheap metadata-only fingerprint of the device-local LaunchServices csstore.
// It does not read the store contents: filename, size, modification time and
// inode are combined so foreground/cold-launch checks can tell whether app
// installation state may have changed before starting an expensive deep scan.
nullable NSString *FFLSStoreFingerprint(NSString *lsdContainerRoot);

// Scans the device-local LaunchServices store inside the given lsd service
// container root and returns candidate installed-app bundle identifiers.
//
// iOS 26 hides third-party apps from the normal ContainerManager and
// LaunchServices enumeration APIs, but the store database still contains
// every installed identifier. Candidates are extracted with a byte-range
// scan and must be confirmed with a direct ContainerManager lookup by the
// caller.
//
// Results are cached in <Documents>/LSIdentifierCache.plist keyed by the
// metadata fingerprint above; a rescan happens only when the store changed.
NSArray<NSString *> *FFLSDiscoverInstalledIdentifiers(NSString *lsdContainerRoot,
                                                      NSUInteger maxCandidates);

// Same store scan, but returns "group.<team>.<name>" App Group candidates
// so the caller can confirm them with class-7 lookups. Cached separately.
NSArray<NSString *> *FFLSDiscoverGroupIdentifiers(NSString *lsdContainerRoot,
                                                  NSUInteger maxCandidates);

NS_ASSUME_NONNULL_END
