#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT const uint16_t FFLocalShareBridgePort;

@interface FFLocalShareBridgeServer : NSObject

+ (instancetype)sharedServer;

// Opens a one-shot loopback listener for a token supplied by the share
// extension through the existing wake URL. No App Group or MCM access is used.
- (void)prepareForToken:(NSString *)token
          expectedCount:(NSUInteger)expectedCount
             completion:(void (^)(NSUInteger imported,
                                  NSArray<NSString *> *destinations,
                                  NSArray<NSError *> *errors))completion;

@end

// Share-extension side. Streams regular files from an extension-private inbox
// to the host over 127.0.0.1. Successfully acknowledged items are removed;
// unsupported/failed items remain queued for the existing advanced fallback.
FOUNDATION_EXPORT BOOL FFLocalShareBridgeSendInbox(NSString *inboxPath,
                                                   NSString *token,
                                                   NSUInteger * _Nullable sentCount,
                                                   NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
