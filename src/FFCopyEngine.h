#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Copy engine that works across container roots without NSFileManager
// sandbox-extension bookkeeping. Recursive, fsync'd, EINTR-safe.
// Ported from FilzaSlop Tweak.m (directCopyItem family).
@interface FFCopyEngine : NSObject

+ (BOOL)copyItemAtPath:(NSString *)source
                toPath:(NSString *)destination
                 error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
