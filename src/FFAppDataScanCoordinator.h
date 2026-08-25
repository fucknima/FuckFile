#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const FFAppDataScanStateDidChangeNotification;

@interface FFAppDataScanCoordinator : NSObject

+ (instancetype)sharedCoordinator;

@property(nonatomic, readonly, getter=isScanning) BOOL scanning;
@property(nonatomic, readonly) double progress;
@property(nonatomic, readonly) NSUInteger total;
@property(nonatomic, readonly) NSUInteger linked;

// Structural LaunchServices Bundle-table count. This includes hidden/system app
// records and is independent from how many AppData containers FuckFile can open.
@property(nonatomic, readonly) NSUInteger installedCount;
@property(nonatomic, readonly) BOOL installedCountReliable;

// Fast capability probe. This does not enumerate the whole device. It returns
// as soon as one known App Data container can be activated and linked.
- (void)bootstrapWithCompletion:(void (^)(BOOL ready, NSString * _Nullable failureReason))completion;

// Cheap foreground/cold-launch check. Only stats/parses small LaunchServices
// metadata; a full reconciliation is started when its fingerprint changed.
- (void)checkForInstalledAppChanges;

// Starts a coalesced, low-priority full discovery/reconciliation pass. New App
// containers are registered; registry entries that are positively confirmed
// removed are evicted. Structured LS inventory is used first; the 20k+ raw
// string fallback is used only when structured coverage is incomplete.
- (void)scanWithCompletion:(void (^ _Nullable)(void))completion;

@end

NS_ASSUME_NONNULL_END
