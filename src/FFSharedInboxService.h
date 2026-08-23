#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const FFSharedInboxDidImportNotification;

@interface FFSharedInboxService : NSObject

// Consumes both bridges:
// 1) LCSign-style App Group when the final signature grants it;
// 2) extension-local Documents via MobileHouseArrest class-4 Extension Data.
// The second path makes sharing survive signers that strip App Group entitlements.
+ (void)processPendingWithCompletion:(void (^ _Nullable)(NSUInteger imported,
    NSArray<NSString *> *destinations, NSArray<NSError *> *errors))completion;

@end

NS_ASSUME_NONNULL_END
