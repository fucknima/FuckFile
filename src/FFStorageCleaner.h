#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, FFStorageCleanupItemKind) {
    FFStorageCleanupItemKindThumbnailCache = 0,
    FFStorageCleanupItemKindShareResiduals,
    FFStorageCleanupItemKindAppData,
};

@interface FFStorageCleanupItem : NSObject
@property(nonatomic, copy, readonly) NSString *identifier;
@property(nonatomic, copy, readonly) NSString *title;
@property(nonatomic, copy, readonly) NSString *subtitle;
@property(nonatomic, readonly) FFStorageCleanupItemKind kind;
@property(nonatomic, readonly) unsigned long long bytes;
@property(nonatomic, readonly) NSUInteger itemCount;
@property(nonatomic, readonly, getter=isRecommended) BOOL recommended;
@property(nonatomic, copy, readonly, nullable) NSString *bundleIdentifier;
@property(nonatomic, readonly) unsigned long long cacheBytes;
@property(nonatomic, readonly) unsigned long long temporaryBytes;
@end

@interface FFStorageCleanupSnapshot : NSObject
@property(nonatomic, copy, readonly) NSArray<FFStorageCleanupItem *> *items;
@property(nonatomic, readonly) unsigned long long totalBytes;
@property(nonatomic, readonly, getter=isAppDataAvailable) BOOL appDataAvailable;
@property(nonatomic, copy, readonly) NSString *appDataStatusText;
@end

@interface FFStorageCleanupResult : NSObject
@property(nonatomic, readonly) unsigned long long requestedBytes;
@property(nonatomic, readonly) unsigned long long freedBytes;
@property(nonatomic, readonly) NSUInteger failedItemCount;
@property(nonatomic, copy, readonly) NSArray<NSError *> *errors;
@end

// Conservative storage cleanup. Third-party AppData cleanup is deliberately
// limited to <container>/Library/Caches and <container>/tmp. It never scans or
// deletes Documents, Preferences, Application Support, or custom cache-looking
// directories. com.apple.* containers are excluded from AppData cleanup.
@interface FFStorageCleaner : NSObject

+ (instancetype)sharedCleaner;

- (void)scanWithProgress:(void (^ _Nullable)(NSUInteger completed,
                                             NSUInteger total,
                                             NSString * _Nullable appName))progress
              completion:(void (^)(FFStorageCleanupSnapshot *snapshot))completion;

- (void)cleanItems:(NSArray<FFStorageCleanupItem *> *)items
           progress:(void (^ _Nullable)(NSUInteger completed,
                                        NSUInteger total,
                                        NSString *title))progress
         completion:(void (^)(FFStorageCleanupResult *result))completion;

@end

NS_ASSUME_NONNULL_END
