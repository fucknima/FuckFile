#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const FFAppDataScanStateDidChangeNotification;

@interface FFAppDataScanCoordinator : NSObject

+ (instancetype)sharedCoordinator;

@property(nonatomic, readonly, getter=isScanning) BOOL scanning;
@property(nonatomic, readonly, getter=isDeepScanning) BOOL deepScanning;
@property(nonatomic, readonly) double progress;
@property(nonatomic, readonly) NSUInteger total;
@property(nonatomic, readonly) NSUInteger linked;

// Fast capability probe. This does not enumerate the whole device. It returns
// as soon as one known App Data container can be activated and linked.
- (void)bootstrapWithCompletion:(void (^)(BOOL ready, NSString * _Nullable failureReason))completion;

// Normal discovery: validates structured/high-confidence sources first, then
// performs only the deep LaunchServices work that has not already been proven
// for the current store fingerprint.
- (void)scanWithCompletion:(void (^ _Nullable)(void))completion;

// User-requested exhaustive rediscovery. Clears the negative/deep-scan cache,
// reparses LaunchServices and revalidates every candidate. Existing valid
// AppData links and real app files are never deleted by this operation.
- (void)fullRescanWithCompletion:(void (^ _Nullable)(void))completion;

@end

NS_ASSUME_NONNULL_END
