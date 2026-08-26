#import <Foundation/Foundation.h>

@class FFAppDataRegistry;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const FFOnlineAppNameResolutionEnabledKey;
FOUNDATION_EXPORT NSNotificationName const FFOnlineAppNameResolutionPreferenceDidChangeNotification;

// Defaults to YES when the preference has never been written.
FOUNDATION_EXPORT BOOL FFOnlineAppNameResolutionEnabled(void);
FOUNDATION_EXPORT void FFSetOnlineAppNameResolutionEnabled(BOOL enabled);

// Best-effort online enrichment for third-party AppData entries whose current
// display name is still just the Bundle ID. It never blocks AppData discovery or
// opening, never queries com.apple.*, and only accepts an App Store record when
// its returned bundleId exactly matches the requested identifier.
@interface FFOnlineAppNameResolver : NSObject

+ (instancetype)sharedResolver;

- (void)resolveMissingNamesInRegistry:(FFAppDataRegistry *)registry;
- (void)cancelPendingResolution;

@end

NS_ASSUME_NONNULL_END
