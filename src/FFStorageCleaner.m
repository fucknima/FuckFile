#import "FFStorageCleaner.h"
#import "FFAppDataLeaseManager.h"
#import "FFAppDataRegistry.h"
#import "FFAppDataScanCoordinator.h"
#import "FFLogger.h"
#import "FFOnlineAppNameResolver.h"
#import "FFPathPolicy.h"
#import "FFShareBridge.h"
#import "FFSystemAccessManager.h"
#import "FFThumbnailService.h"
#import "MCMManager+ExtensionData.h"

#import <UIKit/UIKit.h>
#import <errno.h>
#import <sys/stat.h>

static const NSTimeInterval kFFStorageCleanerShareResidualMinimumAge = 24.0 * 60.0 * 60.0;
static NSString *const kFFStorageCleanerOwnBundleID = @"com.apple.mobile.MobileHouseArrest";

typedef struct {
    unsigned long long bytes;
    NSUInteger files;
    BOOL safe;
} FFStorageMeasure;

@interface FFStorageCleanupItem ()
@property(nonatomic, copy, readwrite) NSString *identifier;
@property(nonatomic, copy, readwrite) NSString *title;
@property(nonatomic, copy, readwrite) NSString *subtitle;
@property(nonatomic, readwrite) FFStorageCleanupItemKind kind;
@property(nonatomic, readwrite) unsigned long long bytes;
@property(nonatomic, readwrite) NSUInteger itemCount;
@property(nonatomic, readwrite, getter=isRecommended) BOOL recommended;
@property(nonatomic, copy, readwrite, nullable) NSString *bundleIdentifier;
@property(nonatomic, readwrite) unsigned long long cacheBytes;
@property(nonatomic, readwrite) unsigned long long temporaryBytes;
@property(nonatomic, copy) NSArray<NSString *> *candidatePaths;
@end
@implementation FFStorageCleanupItem @end

@interface FFStorageCleanupSnapshot ()
@property(nonatomic, copy, readwrite) NSArray<FFStorageCleanupItem *> *items;
@property(nonatomic, readwrite) unsigned long long totalBytes;
@property(nonatomic, readwrite, getter=isAppDataAvailable) BOOL appDataAvailable;
@property(nonatomic, copy, readwrite) NSString *appDataStatusText;
@end
@implementation FFStorageCleanupSnapshot @end

@interface FFStorageCleanupResult ()
@property(nonatomic, readwrite) unsigned long long requestedBytes;
@property(nonatomic, readwrite) unsigned long long freedBytes;
@property(nonatomic, readwrite) NSUInteger failedItemCount;
@property(nonatomic, copy, readwrite) NSArray<NSError *> *errors;
@end
@implementation FFStorageCleanupResult @end

@interface FFStorageCleaner ()
@property(nonatomic, strong) dispatch_queue_t queue;
@end

@implementation FFStorageCleaner

+ (instancetype)sharedCleaner
{
    static FFStorageCleaner *cleaner;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ cleaner = [FFStorageCleaner new]; });
    return cleaner;
}

- (instancetype)init
{
    self = [super init];
    if (self) _queue = dispatch_queue_create("ff.storage-cleaner", DISPATCH_QUEUE_SERIAL);
    return self;
}

#pragma mark - Safe path / measurement helpers

static NSString *FFCleanPath(NSString *path)
{
    return path.stringByStandardizingPath;
}

static BOOL FFPathIsRealDirectory(NSString *path, BOOL *exists)
{
    if (exists) *exists = NO;
    struct stat info;
    if (lstat(path.fileSystemRepresentation, &info) != 0) return errno == ENOENT;
    if (exists) *exists = YES;
    if (S_ISLNK(info.st_mode)) return NO;
    return S_ISDIR(info.st_mode);
}

static FFStorageMeasure FFMeasureDirectory(NSString *path)
{
    FFStorageMeasure result = {0, 0, YES};
    BOOL exists = NO;
    if (!FFPathIsRealDirectory(path, &exists)) {
        result.safe = NO;
        return result;
    }
    if (!exists) return result;

    NSURL *rootURL = [NSURL fileURLWithPath:path isDirectory:YES];
    NSArray *keys = @[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey, NSURLFileSizeKey];
    NSDirectoryEnumerator<NSURL *> *enumerator = [NSFileManager.defaultManager
        enumeratorAtURL:rootURL includingPropertiesForKeys:keys options:0
        errorHandler:^BOOL(__unused NSURL *url, __unused NSError *error) { return YES; }];
    if (!enumerator) return result;

    for (NSURL *url in enumerator) {
        NSDictionary *values = [url resourceValuesForKeys:keys error:nil];
        if ([values[NSURLIsSymbolicLinkKey] boolValue]) {
            [enumerator skipDescendants];
            continue;
        }
        if ([values[NSURLIsDirectoryKey] boolValue]) continue;
        result.bytes += [values[NSURLFileSizeKey] unsignedLongLongValue];
        result.files++;
    }
    return result;
}

static unsigned long long FFMeasurePath(NSString *path)
{
    struct stat info;
    if (lstat(path.fileSystemRepresentation, &info) != 0) return 0;
    if (S_ISLNK(info.st_mode)) return 0;
    if (S_ISDIR(info.st_mode)) return FFMeasureDirectory(path).bytes;
    return (unsigned long long)MAX((off_t)0, info.st_size);
}

static NSError *FFCleanerError(NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:@"FFStorageCleanerErrorDomain" code:code
        userInfo:@{NSLocalizedDescriptionKey: message ?: @"存储清理失败"}];
}

static BOOL FFRemoveValidatedPath(NSString *path, NSError **error)
{
    NSString *finalName = nil;
    NSString *policyError = nil;
    NSString *parent = [FFPathPolicy resolveParentForMutation:path
        finalName:&finalName errorMessage:&policyError];
    if (!parent.length || !finalName.length) {
        if (error) *error = FFCleanerError(10, policyError ?: @"删除路径未通过安全校验");
        return NO;
    }
    NSString *rebuilt = [parent stringByAppendingPathComponent:finalName];
    if (![FFCleanPath(rebuilt) isEqualToString:FFCleanPath(path)]) {
        if (error) *error = FFCleanerError(11, @"删除路径解析结果不一致，已拒绝操作");
        return NO;
    }
    NSError *removeError = nil;
    BOOL removed = [NSFileManager.defaultManager removeItemAtPath:path error:&removeError];
    if (!removed && error) *error = removeError ?: FFCleanerError(12, @"删除失败");
    return removed;
}

static unsigned long long FFDeleteDirectoryChildren(NSString *directory,
                                                     NSMutableArray<NSError *> *errors)
{
    BOOL exists = NO;
    if (!FFPathIsRealDirectory(directory, &exists)) {
        [errors addObject:FFCleanerError(20, [NSString stringWithFormat:
            @"拒绝清理符号链接或非目录：%@", directory])];
        return 0;
    }
    if (!exists) return 0;

    FFStorageMeasure before = FFMeasureDirectory(directory);
    if (!before.safe) {
        [errors addObject:FFCleanerError(21, @"目录安全检查失败")];
        return 0;
    }

    NSArray<NSString *> *children = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:directory error:nil] ?: @[];
    for (NSString *name in children) {
        if (!name.length || [name isEqualToString:@"."] || [name isEqualToString:@".."]) continue;
        NSString *child = [directory stringByAppendingPathComponent:name];
        if (![[FFCleanPath(child) stringByDeletingLastPathComponent]
            isEqualToString:FFCleanPath(directory)]) {
            [errors addObject:FFCleanerError(22, @"发现异常子路径，已跳过")];
            continue;
        }
        NSError *removeError = nil;
        if (!FFRemoveValidatedPath(child, &removeError) && removeError) [errors addObject:removeError];
    }

    FFStorageMeasure after = FFMeasureDirectory(directory);
    if (!after.safe || after.bytes >= before.bytes) return 0;
    return before.bytes - after.bytes;
}

#pragma mark - Local candidates

static NSString *FFThumbnailRoot(void)
{
    NSString *caches = NSSearchPathForDirectoriesInDomains(
        NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return [caches stringByAppendingPathComponent:@"Thumbnails"];
}

static NSArray<NSString *> *FFShareInboxRoots(void)
{
    NSMutableOrderedSet<NSString *> *roots = [NSMutableOrderedSet orderedSet];
    NSURL *groupURL = [NSFileManager.defaultManager
        containerURLForSecurityApplicationGroupIdentifier:FFShareAppGroupIdentifier];
    if (groupURL.path.length)
        [roots addObject:[groupURL.path stringByAppendingPathComponent:FFShareInboxDirectoryName]];

    FFSystemAccessManager *access = FFSystemAccessManager.sharedManager;
    if (access.ready && access.loadedThisSession) {
        NSString *detail = nil;
        NSString *extensionRoot = [[MCMManager sharedManager]
            extensionContainerPathForIdentifier:FFShareExtensionBundleIdentifier error:&detail];
        if (extensionRoot.length) {
            [roots addObject:[[[extensionRoot stringByAppendingPathComponent:@"Documents"]
                stringByAppendingPathComponent:FFShareInboxDirectoryName] stringByStandardizingPath]];
        } else if (detail.length) {
            FFLogTag(@"StorageCleaner", @"extension inbox unavailable: %@", detail);
        }
    }
    return roots.array;
}

static NSTimeInterval FFPathAge(NSString *path)
{
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    NSDate *date = attrs[NSFileModificationDate] ?: attrs[NSFileCreationDate];
    if (!date) return -1;
    return [NSDate.date timeIntervalSinceDate:date];
}

static BOOL FFIsSafeShareResidual(NSString *path, NSArray<NSString *> *roots)
{
    NSString *parent = FFCleanPath(path.stringByDeletingLastPathComponent);
    BOOL rooted = NO;
    for (NSString *root in roots) {
        if ([parent isEqualToString:FFCleanPath(root)]) { rooted = YES; break; }
    }
    if (!rooted) return NO;

    NSTimeInterval age = FFPathAge(path);
    if (age < kFFStorageCleanerShareResidualMinimumAge) return NO;
    NSString *name = path.lastPathComponent;
    if ([name hasPrefix:@".partial-"]) return YES;
    if ([name hasSuffix:FFShareItemSuffix]) {
        NSString *payload = [path stringByAppendingPathComponent:@"payload"];
        BOOL isDirectory = NO;
        BOOL payloadExists = [NSFileManager.defaultManager fileExistsAtPath:payload isDirectory:&isDirectory];
        return !payloadExists || isDirectory;
    }
    return NO;
}

static NSArray<NSString *> *FFCollectShareResiduals(void)
{
    NSArray<NSString *> *roots = FFShareInboxRoots();
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSString *root in roots) {
        BOOL exists = NO;
        if (!FFPathIsRealDirectory(root, &exists) || !exists) continue;
        for (NSString *name in [NSFileManager.defaultManager
             contentsOfDirectoryAtPath:root error:nil] ?: @[]) {
            NSString *path = [root stringByAppendingPathComponent:name];
            if (FFIsSafeShareResidual(path, roots)) [paths addObject:path];
        }
    }
    return paths;
}

- (NSArray<FFStorageCleanupItem *> *)localItems
{
    NSMutableArray<FFStorageCleanupItem *> *items = [NSMutableArray array];

    FFStorageMeasure thumbnailMeasure = FFMeasureDirectory(FFThumbnailRoot());
    if (thumbnailMeasure.safe && (thumbnailMeasure.bytes > 0 || thumbnailMeasure.files > 0)) {
        FFStorageCleanupItem *item = [FFStorageCleanupItem new];
        item.identifier = @"local.thumbnails";
        item.title = @"缩略图缓存";
        item.subtitle = @"FuckFile 生成的图片、视频、PDF 与 IPA 缩略图";
        item.kind = FFStorageCleanupItemKindThumbnailCache;
        item.bytes = thumbnailMeasure.bytes;
        item.itemCount = thumbnailMeasure.files;
        item.recommended = YES;
        [items addObject:item];
    }

    NSArray<NSString *> *residuals = FFCollectShareResiduals();
    if (residuals.count) {
        unsigned long long bytes = 0;
        for (NSString *path in residuals) bytes += FFMeasurePath(path);
        FFStorageCleanupItem *item = [FFStorageCleanupItem new];
        item.identifier = @"local.share-residuals";
        item.title = @"失效分享残留";
        item.subtitle = @"超过 24 小时的未完成分享，以及缺少 payload 的损坏项目";
        item.kind = FFStorageCleanupItemKindShareResiduals;
        item.bytes = bytes;
        item.itemCount = residuals.count;
        item.recommended = YES;
        item.candidatePaths = residuals;
        [items addObject:item];
    }
    return items;
}

#pragma mark - AppData candidates

static BOOL FFEligibleAppIdentifier(NSString *identifier)
{
    if (!identifier.length) return NO;
    NSString *lower = identifier.lowercaseString;
    if ([lower hasPrefix:@"com.apple."]) return NO;
    if ([identifier isEqualToString:kFFStorageCleanerOwnBundleID]) return NO;
    return YES;
}

static NSString *FFDisplayNameForIdentifier(NSString *identifier)
{
    FFAppDataRegistry *registry = FFAppDataRegistry.sharedRegistry;
    NSString *local = [registry displayNameForIdentifier:identifier];
    if (local.length && ![local isEqualToString:identifier]) return local;
    NSString *online = [FFOnlineAppNameResolver.sharedResolver cachedOnlineNameForIdentifier:identifier];
    return online.length ? online : identifier;
}

static BOOL FFContainerTargets(NSString *root, NSString **cachePath, NSString **tmpPath)
{
    if (!root.length || ![root hasPrefix:@"/"]) return NO;
    NSString *standardRoot = FFCleanPath(root);
    NSString *library = FFCleanPath([standardRoot stringByAppendingPathComponent:@"Library"]);
    NSString *cache = FFCleanPath([library stringByAppendingPathComponent:@"Caches"]);
    NSString *tmp = FFCleanPath([standardRoot stringByAppendingPathComponent:@"tmp"]);
    NSString *prefix = [standardRoot stringByAppendingString:@"/"];
    if (![library hasPrefix:prefix] || ![cache hasPrefix:prefix] || ![tmp hasPrefix:prefix]) return NO;

    // Reject a container root, Library, Caches, or tmp that is itself a symlink.
    // Missing cache/tmp directories are fine and simply measure as zero.
    BOOL rootExists = NO, libraryExists = NO, cacheExists = NO, tmpExists = NO;
    if (!FFPathIsRealDirectory(standardRoot, &rootExists) || !rootExists) return NO;
    if (!FFPathIsRealDirectory(library, &libraryExists)) return NO;
    if (!FFPathIsRealDirectory(cache, &cacheExists)) return NO;
    if (!FFPathIsRealDirectory(tmp, &tmpExists)) return NO;
    (void)libraryExists; (void)cacheExists; (void)tmpExists;

    if (cachePath) *cachePath = cache;
    if (tmpPath) *tmpPath = tmp;
    return YES;
}

- (FFStorageCleanupItem *)appItemForIdentifier:(NSString *)identifier
{
    NSError *leaseError = nil;
    NSString *root = [FFAppDataLeaseManager.sharedManager acquireIdentifier:identifier error:&leaseError];
    if (!root.length) {
        if (leaseError) FFLogTag(@"StorageCleaner", @"scan lease FAIL id=%@ error=%@", identifier, leaseError);
        return nil;
    }

    NSString *cachePath = nil, *tmpPath = nil;
    if (!FFContainerTargets(root, &cachePath, &tmpPath)) return nil;
    FFStorageMeasure caches = FFMeasureDirectory(cachePath);
    FFStorageMeasure tmp = FFMeasureDirectory(tmpPath);
    if (!caches.safe || !tmp.safe) {
        FFLogTag(@"StorageCleaner", @"skip unsafe cache target id=%@", identifier);
        return nil;
    }
    unsigned long long total = caches.bytes + tmp.bytes;
    NSUInteger files = caches.files + tmp.files;
    if (total == 0 && files == 0) return nil;

    FFStorageCleanupItem *item = [FFStorageCleanupItem new];
    item.identifier = [@"app:" stringByAppendingString:identifier];
    item.title = FFDisplayNameForIdentifier(identifier);
    item.subtitle = identifier;
    item.kind = FFStorageCleanupItemKindAppData;
    item.bundleIdentifier = identifier;
    item.cacheBytes = caches.bytes;
    item.temporaryBytes = tmp.bytes;
    item.bytes = total;
    item.itemCount = files;
    item.recommended = NO;
    return item;
}

#pragma mark - Scan

- (void)scanWithProgress:(void (^)(NSUInteger, NSUInteger, NSString *))progress
              completion:(void (^)(FFStorageCleanupSnapshot *))completion
{
    dispatch_async(self.queue, ^{
        @autoreleasepool {
            NSMutableArray<FFStorageCleanupItem *> *items = [[self localItems] mutableCopy];
            FFSystemAccessManager *access = FFSystemAccessManager.sharedManager;
            FFAppDataScanCoordinator *scan = FFAppDataScanCoordinator.sharedCoordinator;
            BOOL appAvailable = access.ready && !scan.scanning;
            NSString *status = nil;

            if (!access.ready) {
                status = @"高级系统访问未就绪；当前只扫描 FuckFile 自身垃圾。";
            } else if (scan.scanning) {
                status = @"App Data 正在后台扫描；完成后下拉刷新即可扫描第三方 App 缓存。";
            } else {
                NSArray<NSString *> *all = FFAppDataRegistry.sharedRegistry.identifiers;
                NSMutableArray<NSString *> *eligible = [NSMutableArray array];
                for (NSString *identifier in all) if (FFEligibleAppIdentifier(identifier)) [eligible addObject:identifier];

                NSUInteger total = eligible.count;
                NSUInteger completed = 0;
                for (NSString *identifier in eligible) {
                    @autoreleasepool {
                        FFStorageCleanupItem *item = [self appItemForIdentifier:identifier];
                        if (item) [items addObject:item];
                    }
                    completed++;
                    if (progress) {
                        NSString *name = FFDisplayNameForIdentifier(identifier);
                        dispatch_async(dispatch_get_main_queue(), ^{ progress(completed, total, name); });
                    }
                }
                status = total ? @"仅扫描第三方 App 的 Library/Caches 与 tmp；系统 App 已排除。"
                    : @"没有可扫描的第三方 App Data。";
            }

            NSArray *local = [items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:
                ^BOOL(FFStorageCleanupItem *item, __unused NSDictionary *bindings) {
                    return item.kind != FFStorageCleanupItemKindAppData;
                }]];
            NSArray *apps = [items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:
                ^BOOL(FFStorageCleanupItem *item, __unused NSDictionary *bindings) {
                    return item.kind == FFStorageCleanupItemKindAppData;
                }]];
            apps = [apps sortedArrayUsingComparator:^NSComparisonResult(FFStorageCleanupItem *a, FFStorageCleanupItem *b) {
                if (a.bytes == b.bytes) return [a.title localizedCaseInsensitiveCompare:b.title];
                return a.bytes > b.bytes ? NSOrderedAscending : NSOrderedDescending;
            }];

            NSMutableArray *ordered = [local mutableCopy];
            [ordered addObjectsFromArray:apps];
            FFStorageCleanupSnapshot *snapshot = [FFStorageCleanupSnapshot new];
            snapshot.items = ordered;
            snapshot.appDataAvailable = appAvailable;
            snapshot.appDataStatusText = status ?: @"";
            unsigned long long totalBytes = 0;
            for (FFStorageCleanupItem *item in ordered) totalBytes += item.bytes;
            snapshot.totalBytes = totalBytes;
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(snapshot); });
        }
    });
}

#pragma mark - Cleanup

- (unsigned long long)cleanThumbnailItem:(FFStorageCleanupItem *)item
                                  errors:(NSMutableArray<NSError *> *)errors
{
    (void)item;
    unsigned long long freed = FFDeleteDirectoryChildren(FFThumbnailRoot(), errors);
    [FFThumbnailService.sharedService clearCaches];
    return freed;
}

- (unsigned long long)cleanShareItem:(FFStorageCleanupItem *)item
                              errors:(NSMutableArray<NSError *> *)errors
{
    NSArray<NSString *> *roots = FFShareInboxRoots();
    unsigned long long freed = 0;
    for (NSString *path in item.candidatePaths ?: @[]) {
        if (!FFIsSafeShareResidual(path, roots)) continue;
        unsigned long long bytes = FFMeasurePath(path);
        NSError *removeError = nil;
        if (FFRemoveValidatedPath(path, &removeError)) freed += bytes;
        else if (removeError) [errors addObject:removeError];
    }
    return freed;
}

- (unsigned long long)cleanAppItem:(FFStorageCleanupItem *)item
                            errors:(NSMutableArray<NSError *> *)errors
{
    NSString *identifier = item.bundleIdentifier;
    if (!FFEligibleAppIdentifier(identifier)) {
        [errors addObject:FFCleanerError(30, @"App 标识符未通过清理白名单")];
        return 0;
    }

    NSError *leaseError = nil;
    NSString *root = [FFAppDataLeaseManager.sharedManager reacquireIdentifier:identifier error:&leaseError];
    if (!root.length) {
        [errors addObject:leaseError ?: FFCleanerError(31, @"无法重新获取 App Data 容器")];
        return 0;
    }
    NSString *cachePath = nil, *tmpPath = nil;
    if (!FFContainerTargets(root, &cachePath, &tmpPath)) {
        [errors addObject:FFCleanerError(32, @"App Data 容器路径校验失败")];
        return 0;
    }

    unsigned long long freed = 0;
    freed += FFDeleteDirectoryChildren(cachePath, errors);
    freed += FFDeleteDirectoryChildren(tmpPath, errors);
    return freed;
}

- (void)cleanItems:(NSArray<FFStorageCleanupItem *> *)items
           progress:(void (^)(NSUInteger, NSUInteger, NSString *))progress
         completion:(void (^)(FFStorageCleanupResult *))completion
{
    NSArray<FFStorageCleanupItem *> *requested = [items copy] ?: @[];
    dispatch_async(self.queue, ^{
        NSMutableArray<NSError *> *errors = [NSMutableArray array];
        FFStorageCleanupResult *result = [FFStorageCleanupResult new];
        for (FFStorageCleanupItem *item in requested) result.requestedBytes += item.bytes;

        NSUInteger completed = 0;
        NSUInteger failedItems = 0;
        for (FFStorageCleanupItem *item in requested) {
            NSUInteger errorsBefore = errors.count;
            unsigned long long freed = 0;
            switch (item.kind) {
                case FFStorageCleanupItemKindThumbnailCache:
                    freed = [self cleanThumbnailItem:item errors:errors];
                    break;
                case FFStorageCleanupItemKindShareResiduals:
                    freed = [self cleanShareItem:item errors:errors];
                    break;
                case FFStorageCleanupItemKindAppData:
                    freed = [self cleanAppItem:item errors:errors];
                    break;
            }
            result.freedBytes += freed;
            if (errors.count > errorsBefore) failedItems++;
            FFLogTag(@"StorageCleaner", @"clean kind=%ld title=%@ freed=%llu errors=%lu",
                (long)item.kind, item.title, freed, (unsigned long)(errors.count - errorsBefore));
            completed++;
            if (progress) dispatch_async(dispatch_get_main_queue(), ^{
                progress(completed, requested.count, item.title);
            });
        }

        result.failedItemCount = failedItems;
        result.errors = errors.copy;
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(result); });
    });
}

@end
