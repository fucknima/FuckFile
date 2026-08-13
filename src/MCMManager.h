// MCMManager — MCM identity-bypass integration layer for FuckFile.
// Core logic ported from 0xjohnnydev/FilzaSlop MCMFilzaIntegration.m,
// stripped of Filza-specific hooks (paste, root helper, wallpaper lab).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *MCMVirtualRoot(void);

// Posted after the background LaunchServices confirmation pass finishes
// installing App Data links. Browsers observing this can auto-refresh.
FOUNDATION_EXPORT NSNotificationName const FFMCMAppLinksUpdatedNotification;

@interface MCMManager : NSObject

+ (instancetype)sharedManager;

// Enumerates container classes and builds the symlink virtual root.
// Safe to call repeatedly; performs its work exactly once per process.
- (void)start;

// Returns the activated real path for a class-2 (app data) container.
- (nullable NSString *)dataContainerPathForIdentifier:(NSString *)identifier
                                                error:(NSString * _Nullable * _Nullable)error;

// Activates a scoped (part/part-domain) container route. Used by the
// MobileGestalt editor and the experimental probes.
- (nullable NSString *)activateScoped:(uint64_t)containerClass
                           identifier:(NSString *)identifier
                                group:(BOOL)group
                                 part:(uint64_t)part
                           partDomain:(nullable NSString *)partDomain
                                flags:(uint64_t)flags
                                error:(NSString * _Nullable * _Nullable)error;

// Resolves com.apple.MobileGestalt.plist through the MCM routes, falling
// back to the bad_query escaped link. Returns nil if no route grants access.
- (nullable NSString *)mobileGestaltPath:(NSString * _Nullable * _Nullable)error;

// Map of category folder name -> (link name -> symlink target), refreshed by
// -start. Used by the browser to show which roots are active.
@property(nonatomic, readonly) NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *categoryLinks;

// YES once -start finished (even if everything failed).
@property(nonatomic, readonly) BOOL started;

@end

NS_ASSUME_NONNULL_END
