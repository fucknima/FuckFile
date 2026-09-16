#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const FFTrashDidChangeNotification;

@interface FFTrashEntry : NSObject
@property(nonatomic, copy, readonly) NSString *identifier;
@property(nonatomic, copy, readonly) NSString *name;
@property(nonatomic, copy, readonly) NSString *originalPath;
@property(nonatomic, copy, readonly) NSString *payloadPath;
@property(nonatomic, strong, readonly) NSDate *deletedAt;
@property(nonatomic, readonly) BOOL isDirectory;
@property(nonatomic, readonly) unsigned long long size;
@end

// Soft-delete store. Items are moved (same volume) into <root>/.Trash/<uuid>/
// with a payload plus an item.plist that keeps the original name/path/date so
// restore is exact. Foundation-only so the CI self-check can exercise it.
@interface FFTrashService : NSObject

+ (instancetype)sharedService;
- (instancetype)initWithTrashRoot:(NSString *)trashRoot NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, copy, readonly) NSString *trashRoot;

// Returns how many items were moved; stops early on a hard failure.
- (NSUInteger)moveToTrash:(NSArray<NSString *> *)paths firstError:(NSError **)error;
- (NSArray<FFTrashEntry *> *)entries;
- (NSUInteger)itemCount;
- (BOOL)restoreEntry:(FFTrashEntry *)entry
        restoredPath:(NSString * _Nullable * _Nullable)outPath
               error:(NSError **)error;
- (BOOL)removeEntryPermanently:(FFTrashEntry *)entry error:(NSError **)error;
- (NSUInteger)emptyWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
