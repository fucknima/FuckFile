#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Cheap metadata-only fingerprint of the device-local LaunchServices csstore.
// It does not read the store contents: filename, size, modification time and
// inode are combined so foreground/cold-launch checks can tell whether app
// installation state may have changed before starting an expensive deep scan.
NSString * _Nullable FFLSStoreFingerprint(NSString *lsdContainerRoot);

// Reads the CoreServicesStore catalog/table index and returns the number of
// records in LaunchServices' Bundle table. This is a structural count, not the
// old byte-string candidate count, so it is normally close to the actual number
// of registered applications (including hidden/system apps). Returns NSNotFound
// when the current csstore schema cannot be parsed safely.
NSUInteger FFLSBundleRecordCount(NSString *lsdContainerRoot);

// Uses LSApplicationWorkspace's structured application APIs (user + system,
// plus compatibility fallbacks) and returns deduplicated installed bundle IDs.
// On iOS versions that filter LaunchServices for this process, callers compare
// this count with FFLSBundleRecordCount and fall back to the raw store scan only
// when the structured inventory is incomplete.
NSArray<NSString *> *FFLSStructuredInstalledApplicationIdentifiers(void);

// Scans the device-local LaunchServices store inside the given lsd service
// container root and returns candidate installed-app bundle identifiers.
//
// This is deliberately the final fallback. Some iOS releases hide third-party
// apps from structured ContainerManager / LaunchServices enumeration while the
// store still contains their identifiers. The byte-range candidates must be
// confirmed with a direct ContainerManager lookup by the caller.
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
