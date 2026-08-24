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

// Starts a coalesced, low-priority full discovery pass. If a scan is already
// running, the completion is joined to that pass instead of scheduling another.
- (void)scanWithCompletion:(void (^ _Nullable)(void))completion;

@end

NS_ASSUME_NONNULL_END
