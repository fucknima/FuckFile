#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, FFBatchRenameMode) {
    FFBatchRenameModeReplace = 0,
    FFBatchRenameModeAffix,
    FFBatchRenameModeSequence,
};

// Pure batch-rename name engine (Foundation-only, exercised by the CI
// self-check). Extensions are preserved; callers still have to check the
// results against the folder contents for collisions.
@interface FFBatchRename : NSObject

// Returns the new names in the same order, or nil with a user-facing message
// when the inputs cannot produce valid unique names.
+ (nullable NSArray<NSString *> *)newNamesForNames:(NSArray<NSString *> *)names
    mode:(FFBatchRenameMode)mode
    find:(nullable NSString *)find
    replace:(nullable NSString *)replace
    caseSensitive:(BOOL)caseSensitive
    prefix:(nullable NSString *)prefix
    suffix:(nullable NSString *)suffix
    sequencePrefix:(nullable NSString *)sequencePrefix
    start:(NSInteger)start
    digits:(NSInteger)digits
    error:(NSString * _Nullable * _Nullable)errorMessage;

@end

NS_ASSUME_NONNULL_END
