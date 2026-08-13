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
// Results are cached in <Documents>/LSIdentifierCache.plist keyed by the
// store's byte size; a rescan happens only when the store changed.
NSArray<NSString *> *FFLSDiscoverInstalledIdentifiers(NSString *lsdContainerRoot,
                                                      NSUInteger maxCandidates);

// Same store scan, but returns "group.<team>.<name>" App Group candidates
// so the caller can confirm them with class-7 lookups. Cached separately.
NSArray<NSString *> *FFLSDiscoverGroupIdentifiers(NSString *lsdContainerRoot,
                                                  NSUInteger maxCandidates);

// Extracts a bundle-id -> localized display-name map from the same
// store. Only identifiers in the whitelist (the class-2-confirmed
// installed set) are considered; candidates near each identifier are
// scored and the best one above the threshold wins, so garbage
// mappings are confined to real installed apps only.
NSDictionary<NSString *, NSString *> *FFLSDiscoverAppNames(
    NSString *lsdContainerRoot, NSSet<NSString *> *whitelist);

NS_ASSUME_NONNULL_END
