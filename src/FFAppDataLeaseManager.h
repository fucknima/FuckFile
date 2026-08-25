#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Owns process-lifetime class-2 MCM leases. Persistent AppData registry entries
// never imply that a lease exists; this manager reacquires access lazily for the
// current process and deduplicates concurrent requests for the same bundle id.
@interface FFAppDataLeaseManager : NSObject

+ (instancetype)sharedManager;

- (nullable NSString *)acquireIdentifier:(NSString *)identifier
                                   error:(NSError * _Nullable * _Nullable)error;
- (nullable NSString *)currentRootForIdentifier:(NSString *)identifier;
- (BOOL)hasLeaseForIdentifier:(NSString *)identifier;

// Forces a new ContainerManager lookup instead of accepting a readable cached
// process lease. This is used only while reconciling an install/uninstall event:
// a stale cached lease may remain readable for a short time after uninstall.
- (nullable NSString *)reacquireIdentifier:(NSString *)identifier
                                     error:(NSError * _Nullable * _Nullable)error;

// Drops a process-local lease after LaunchServices authoritatively reports that
// the app is no longer installed. Any in-flight acquisition for this identifier
// is allowed to finish first so it cannot repopulate the cache after eviction.
- (void)invalidateIdentifier:(NSString *)identifier;

@end

NS_ASSUME_NONNULL_END
