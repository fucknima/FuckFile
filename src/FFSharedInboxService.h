#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const FFSharedInboxDidImportNotification;

@interface FFSharedInboxService : NSObject

// Consumes the App Group inbox when the signer grants the shared container.
// When the group is unavailable the share extension streams files over the
// loopback bridge instead (FFLocalShareBridge).
+ (void)processPendingWithCompletion:(void (^ _Nullable)(NSUInteger imported,
    NSArray<NSString *> *destinations, NSArray<NSError *> *errors))completion;

@end

NS_ASSUME_NONNULL_END
