// MCMManager — MCM identity-bypass integration layer for FuckFile.
// Core logic ported from 0xjohnnydev/FilzaSlop MCMFilzaIntegration.m,
// stripped of Filza-specific hooks (paste, root helper, wallpaper lab).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *MCMVirtualRoot(void);
FOUNDATION_EXPORT NSString *MCMWallpaperLabName(void); // kept for compat, unused

@interface MCMManager : NSObject

+ (instancetype)sharedManager;

// Enumerates container classes and builds the symlink virtual root.
// Safe to call repeatedly; performs its work exactly once per process.
- (void)start;

// Returns the activated real path for a class-2 (app data) container.
- (nullable NSString *)dataContainerPathForIdentifier:(NSString *)identifier
                                                error:(NSString * _Nullable * _Nullable)error;

// Map of category folder name -> (link name -> symlink target), refreshed by
// -start. Used by the browser to show which roots are active.
@property(nonatomic, readonly) NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *categoryLinks;

// YES once -start finished (even if everything failed).
@property(nonatomic, readonly) BOOL started;

@end

NS_ASSUME_NONNULL_END
