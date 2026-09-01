#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class FFAppDataRegistry;

typedef NS_ENUM(NSInteger, FFOnlineAppNameResolutionState) {
    FFOnlineAppNameResolutionStateDisabled = 0,
    FFOnlineAppNameResolutionStateWaitingForSystemAccess,
    FFOnlineAppNameResolutionStateWaitingForScan,
    FFOnlineAppNameResolutionStateIdle,
    FFOnlineAppNameResolutionStateResolving,
    FFOnlineAppNameResolutionStateWaitingForRetry,
};

FOUNDATION_EXPORT NSString *const FFOnlineAppNameResolutionEnabledKey;
FOUNDATION_EXPORT NSNotificationName const FFOnlineAppNameResolutionPreferenceDidChangeNotification;
FOUNDATION_EXPORT NSNotificationName const FFOnlineAppNameResolutionStateDidChangeNotification;
FOUNDATION_EXPORT NSNotificationName const FFOnlineAppNameResolutionNamesDidChangeNotification;

FOUNDATION_EXPORT BOOL FFOnlineAppNameResolutionEnabled(void);
FOUNDATION_EXPORT void FFSetOnlineAppNameResolutionEnabled(BOOL enabled);

// Owns the complete online-name lifecycle. It never discovers apps and never
// mutates AppDataRegistry: the registry remains the authoritative inventory and
// local-name source, while this service provides a best-effort display overlay.
@interface FFOnlineAppNameResolver : NSObject

+ (instancetype)sharedResolver;

@property(nonatomic, readonly) FFOnlineAppNameResolutionState state;
@property(nonatomic, readonly) NSUInteger userAppTotal;
@property(nonatomic, readonly) NSUInteger namedAppCount;
@property(nonatomic, readonly) NSUInteger passCompleted;
@property(nonatomic, readonly) NSUInteger passTotal;
@property(nonatomic, readonly) NSUInteger passResolved;
@property(nonatomic, readonly) NSTimeInterval retryAfter;
@property(nonatomic, readonly) double progress;

// Local names are authoritative. An online cached name is used only when the
// local value is empty or still equal to the Bundle ID. Positive cached values
// remain displayable after TTL expiry while they are refreshed in background.
- (nullable NSString *)cachedOnlineNameForIdentifier:(NSString *)identifier;
- (NSString *)displayNameForIdentifier:(NSString *)identifier
                              localName:(nullable NSString *)localName;

// Re-evaluates prerequisites and work. Callers do not need to decide whether
// network access is allowed; the resolver gates itself on the online preference,
// Advanced System Access readiness, AppData scan state and retry backoff.
- (void)reevaluate;
- (void)cancelPendingResolution;

@end

NS_ASSUME_NONNULL_END
