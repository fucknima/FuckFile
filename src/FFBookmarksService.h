#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FFBookmark : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *path;
@property(nonatomic) BOOL isDirectory;
@property(nonatomic, strong) NSDate *addedDate;
@end

// Favorites: persisted in Documents/Device Storage/Favorites.plist.
@interface FFFavoritesService : NSObject

+ (instancetype)sharedService;

- (NSArray<FFBookmark *> *)bookmarks;
- (BOOL)isFavoritePath:(NSString *)path;
- (void)togglePath:(NSString *)path name:(NSString *)name isDirectory:(BOOL)isDirectory;
- (void)removePath:(NSString *)path;

@end

// Recent access log: persisted in NSUserDefaults (newest first, deduped,
// capped at 50). Browser navigation records entries here.
@interface FFRecentService : NSObject

+ (instancetype)sharedService;

- (NSArray<FFBookmark *> *)entries;
- (void)recordPath:(NSString *)path name:(NSString *)name isDirectory:(BOOL)isDirectory;
- (void)removePath:(NSString *)path;
- (void)clear;

@end

NS_ASSUME_NONNULL_END
