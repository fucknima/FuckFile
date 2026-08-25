#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const FFAppDataScanStateDidChangeNotification;

@interface FFAppDataScanCoordinator : NSObject

+ (instancetype)sharedCoordinator;

@property(nonatomic, readonly, getter=isScanning) BOOL scanning;
@property(nonatomic, readonly) double progress;
@property(nonatomic, readonly) NSUInteger total;
@property(nonatomic, readonly) NSUInteger linked;

// Fast capability probe. This does not enumerate the whole device. It returns
// as soon as one known App Data container can be activated and linked.
- (void)bootstrapWithCompletion:(void (^)(BOOL ready, NSString * _Nullable failureReason))completion;

// Cheap foreground/cold-launch check. Only stats the LaunchServices store; a
// full reconciliation is started when its metadata fingerprint changed.
- (void)checkForInstalledAppChanges;

// Starts a coalesced, low-priority full discovery/reconciliation pass. New App
// containers are registered; registry entries that are positively confirmed
// removed are evicted. If a scan is already running, completion joins it.
- (void)scanWithCompletion:(void (^ _Nullable)(void))completion;

@end

NS_ASSUME_NONNULL_END
