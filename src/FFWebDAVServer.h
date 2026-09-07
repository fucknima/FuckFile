#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const FFWebDAVServerDidChangeNotification;

@interface FFWebDAVServer : NSObject

+ (instancetype)sharedServer;

@property(nonatomic, readonly, getter=isRunning) BOOL running;
@property(nonatomic, copy, readonly, nullable) NSString *addressString;
@property(nonatomic, copy, readonly, nullable) NSString *rootPath;
@property(nonatomic, copy, readonly, nullable) NSString *username;
@property(nonatomic, readonly) uint16_t port;

- (BOOL)startWithRoot:(NSString *)rootPath
             username:(NSString *)username
             password:(NSString *)password
                 port:(uint16_t)port
                error:(NSError * _Nullable * _Nullable)error;

- (void)stop;

@end

NS_ASSUME_NONNULL_END
