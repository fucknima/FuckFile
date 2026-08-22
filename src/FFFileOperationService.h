#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Unified file operation service. Every mutation (create, delete,
// rename, batch delete) goes through here instead of touching
// NSFileManager directly, so path safety (openat + O_NOFOLLOW via
// FFPathPolicy), error handling and conflict policy stay in one place.
@interface FFFileOperationService : NSObject

+ (instancetype)sharedService;

// Creates a directory at path (parents must exist).
- (BOOL)createDirectoryAtPath:(NSString *)path error:(NSError * _Nullable * _Nullable)error;

// Creates an empty regular file at path.
- (BOOL)createEmptyFileAtPath:(NSString *)path error:(NSError * _Nullable * _Nullable)error;

// Renames/moves path -> newPath (same parent rename is atomic via
// renameat on the validated parent fd). Refuses to overwrite when
// overwrite is NO (returns EEXIST so the UI can offer replace/keep).
- (BOOL)renameItemAtPath:(NSString *)path toPath:(NSString *)newPath
                   error:(NSError * _Nullable * _Nullable)error;
- (BOOL)renameItemAtPath:(NSString *)path toPath:(NSString *)newPath
               overwrite:(BOOL)overwrite
                   error:(NSError * _Nullable * _Nullable)error;

// Removes a single item (file, directory tree or our own app link).
- (BOOL)removeItemAtPath:(NSString *)path error:(NSError * _Nullable * _Nullable)error;

// Batch remove; stops at the first failure and reports it. Returns the
// number of items removed.
- (NSUInteger)removeItemsAtPaths:(NSArray<NSString *> *)paths
                    firstError:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
