#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#define FFLocalShareBridgePort ((uint16_t)47551)

@interface FFLocalShareBridgeServer : NSObject

+ (instancetype)sharedServer;

- (void)prepareForToken:(NSString *)token
          expectedCount:(NSUInteger)expectedCount
             completion:(void (^)(NSUInteger imported,
                                  NSArray<NSString *> *destinations,
                                  NSArray<NSError *> *errors))completion;

@end

FOUNDATION_EXPORT BOOL FFLocalShareBridgeSendInbox(NSString *inboxPath,
                                                   NSString *sessionID,
                                                   NSString *token,
                                                   NSUInteger * _Nullable sentCount,
                                                   NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
