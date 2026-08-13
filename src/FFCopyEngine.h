#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Copy engine that works across container roots without NSFileManager
// sandbox-extension bookkeeping. Recursive, fsync'd, EINTR-safe.
// Ported from FilzaSlop Tweak.m (directCopyItem family).
@interface FFCopyEngine : NSObject

+ (BOOL)copyItemAtPath:(NSString *)source
                toPath:(NSString *)destination
                 error:(NSError **)error;

// Progress variant: reports (copiedBytes, totalBytes) after every chunk.
// progress may be nil. Total is computed with a recursive stat sweep
// before copying starts (O(entries), acceptable for large trees).
+ (BOOL)copyItemAtPath:(NSString *)source
                toPath:(NSString *)destination
              progress:(void (^ _Nullable)(unsigned long long copied,
                                           unsigned long long total))progress
                 error:(NSError **)error;

// Recursive byte size (lstat-based, symlinks not followed).
+ (unsigned long long)sizeOfItemAtPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
