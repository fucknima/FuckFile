#import "FFIPAMetadataService.h"
#import "FFArchiveService.h"
#import "FFLogger.h"

@interface FFIPAMetadataService ()
@property(nonatomic, strong) NSCache<NSString *, FFIPAMetadata *> *cache;
@property(nonatomic, strong) dispatch_queue_t queue;
@end

@implementation FFIPAMetadata
@end

@implementation FFIPAMetadataService

+ (instancetype)sharedService
{
    static FFIPAMetadataService *service;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ service = [FFIPAMetadataService new]; });
    return service;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _cache = [NSCache new];
        _cache.countLimit = 128;
        _queue = dispatch_queue_create("ff.ipa.metadata", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

static NSString *FFIPACacheKey(NSString *path)
{
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    NSNumber *size = attrs[NSFileSize] ?: @0;
    NSDate *mtime = attrs[NSFileModificationDate] ?: [NSDate dateWithTimeIntervalSince1970:0];
    return [NSString stringWithFormat:@"%@#%@#%.0f", path, size, mtime.timeIntervalSince1970];
}

static NSArray<NSString *> *FFIPAIconNamesFromInfo(NSDictionary *info)
{
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    void (^append)(id) = ^(id value) {
        if ([value isKindOfClass:NSString.class] && [value length]) [names addObject:value];
        else if ([value isKindOfClass:NSArray.class]) {
            for (id item in value)
                if ([item isKindOfClass:NSString.class] && [item length]) [names addObject:item];
        }
    };

    append(info[@"CFBundleIconFiles"]);
    append(info[@"CFBundleIconName"]);

    NSDictionary *icons = [info[@"CFBundleIcons"] isKindOfClass:NSDictionary.class] ? info[@"CFBundleIcons"] : nil;
    NSDictionary *primary = [icons[@"CFBundlePrimaryIcon"] isKindOfClass:NSDictionary.class] ? icons[@"CFBundlePrimaryIcon"] : nil;
    append(primary[@"CFBundleIconFiles"]);
    append(primary[@"CFBundleIconName"]);

    NSDictionary *ipadIcons = [info[@"CFBundleIcons~ipad"] isKindOfClass:NSDictionary.class] ? info[@"CFBundleIcons~ipad"] : nil;
    NSDictionary *ipadPrimary = [ipadIcons[@"CFBundlePrimaryIcon"] isKindOfClass:NSDictionary.class] ? ipadIcons[@"CFBundlePrimaryIcon"] : nil;
    append(ipadPrimary[@"CFBundleIconFiles"]);
    append(ipadPrimary[@"CFBundleIconName"]);

    NSMutableOrderedSet *dedup = [NSMutableOrderedSet orderedSet];
    for (NSString *name in names) {
        NSString *base = name.lastPathComponent;
        if (base.length) [dedup addObject:base];
    }
    return dedup.array;
}

static NSInteger FFIPAIconScore(NSString *entryPath, NSArray<NSString *> *declaredNames)
{
    NSString *file = entryPath.lastPathComponent;
    NSString *lower = file.lowercaseString;
    if (![lower.pathExtension isEqualToString:@"png"]) return NSIntegerMin;

    NSInteger score = 0;
    if ([lower containsString:@"appicon"]) score += 500;
    if ([lower containsString:@"icon"]) score += 250;
    if ([lower containsString:@"@3x"]) score += 80;
    else if ([lower containsString:@"@2x"]) score += 40;

    for (NSString *declared in declaredNames) {
        NSString *d = declared.lowercaseString.stringByDeletingPathExtension;
        NSString *f = lower.stringByDeletingPathExtension;
        if ([f isEqualToString:d] || [f hasPrefix:[d stringByAppendingString:@"@"]]) score += 1000;
        else if ([f containsString:d] && d.length >= 4) score += 700;
    }

    // 优先典型主屏幕图标尺寸命名。
    if ([lower containsString:@"60x60"] || [lower containsString:@"76x76"] ||
        [lower containsString:@"83.5x83.5"] || [lower containsString:@"1024x1024"])
        score += 120;
    return score;
}

- (void)metadataForIPAAtPath:(NSString *)path
                  completion:(void (^)(FFIPAMetadata *, NSError *))completion
{
    if (!path.length) {
        if (completion) completion(nil, [NSError errorWithDomain:@"FFIPA" code:1 userInfo:@{NSLocalizedDescriptionKey:@"IPA 路径为空"}]);
        return;
    }
    NSString *key = FFIPACacheKey(path);
    FFIPAMetadata *cached = [self.cache objectForKey:key];
    if (cached) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(cached, nil); });
        return;
    }

    dispatch_async(self.queue, ^{
        NSError *error = nil;
        FFArchiveService *archive = [FFArchiveService new];
        NSArray<FFArchiveEntry *> *entries = [archive listEntries:path error:&error];
        if (!entries) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, error); });
            return;
        }

        NSString *appRoot = nil;
        for (FFArchiveEntry *entry in entries) {
            if (!entry.isDirectory) continue;
            if (![entry.entryPath hasPrefix:@"Payload/"]) continue;
            NSString *trimmed = [entry.entryPath stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
            if ([trimmed.pathExtension.lowercaseString isEqualToString:@"app"] &&
                [trimmed pathComponents].count == 2) {
                appRoot = trimmed;
                break;
            }
        }
        if (!appRoot) {
            NSError *e = [NSError errorWithDomain:@"FFIPA" code:2 userInfo:@{NSLocalizedDescriptionKey:@"归档中找不到 Payload/*.app"}];
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, e); });
            return;
        }

        NSString *tempDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"ffipa-%@", NSUUID.UUID.UUIDString]];
        [NSFileManager.defaultManager createDirectoryAtPath:tempDir withIntermediateDirectories:YES attributes:nil error:nil];

        NSString *infoEntry = [appRoot stringByAppendingPathComponent:@"Info.plist"];
        NSString *infoPath = [archive extractEntry:infoEntry fromArchive:path toDirectory:tempDir error:&error];
        NSDictionary *info = infoPath ? [NSDictionary dictionaryWithContentsOfFile:infoPath] : nil;
        if (![info isKindOfClass:NSDictionary.class]) {
            [NSFileManager.defaultManager removeItemAtPath:tempDir error:nil];
            NSError *e = error ?: [NSError errorWithDomain:@"FFIPA" code:3 userInfo:@{NSLocalizedDescriptionKey:@"无法解析 IPA 中的 Info.plist"}];
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, e); });
            return;
        }

        NSArray<NSString *> *declaredNames = FFIPAIconNamesFromInfo(info);
        NSString *bestIconEntry = nil;
        NSInteger bestScore = NSIntegerMin;
        NSString *appPrefix = [appRoot stringByAppendingString:@"/"];
        for (FFArchiveEntry *entry in entries) {
            if (entry.isDirectory || ![entry.entryPath hasPrefix:appPrefix]) continue;
            NSString *relative = [entry.entryPath substringFromIndex:appPrefix.length];
            if ([relative containsString:@"/"]) continue; // 主 bundle 根目录图标优先，避免误抓资源包图标
            NSInteger score = FFIPAIconScore(entry.entryPath, declaredNames);
            if (score > bestScore) { bestScore = score; bestIconEntry = entry.entryPath; }
        }

        UIImage *icon = nil;
        if (bestIconEntry && bestScore > 0) {
            NSString *iconPath = [archive extractEntry:bestIconEntry fromArchive:path toDirectory:tempDir error:nil];
            if (iconPath) icon = [UIImage imageWithContentsOfFile:iconPath];
        }

        FFIPAMetadata *metadata = [FFIPAMetadata new];
        metadata.displayName = [info[@"CFBundleDisplayName"] isKindOfClass:NSString.class] ? info[@"CFBundleDisplayName"] :
            ([info[@"CFBundleName"] isKindOfClass:NSString.class] ? info[@"CFBundleName"] : appRoot.lastPathComponent.stringByDeletingPathExtension);
        metadata.bundleIdentifier = [info[@"CFBundleIdentifier"] isKindOfClass:NSString.class] ? info[@"CFBundleIdentifier"] : @"?";
        metadata.version = [info[@"CFBundleShortVersionString"] isKindOfClass:NSString.class] ? info[@"CFBundleShortVersionString"] : @"?";
        metadata.build = [info[@"CFBundleVersion"] isKindOfClass:NSString.class] ? info[@"CFBundleVersion"] : @"?";
        metadata.minimumOS = [info[@"MinimumOSVersion"] isKindOfClass:NSString.class] ? info[@"MinimumOSVersion"] : @"?";
        metadata.executableName = [info[@"CFBundleExecutable"] isKindOfClass:NSString.class] ? info[@"CFBundleExecutable"] : nil;
        metadata.appBundlePath = appRoot;
        metadata.icon = icon;

        [self.cache setObject:metadata forKey:key];
        [NSFileManager.defaultManager removeItemAtPath:tempDir error:nil];
        FFLogTag(@"IPA", @"metadata parsed %@ (%@) icon=%@", metadata.displayName, metadata.bundleIdentifier, icon ? @"yes" : @"no");
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(metadata, nil); });
    });
}

- (void)iconForIPAAtPath:(NSString *)path completion:(void (^)(UIImage *))completion
{
    [self metadataForIPAAtPath:path completion:^(FFIPAMetadata *metadata, NSError *error) {
        (void)error;
        if (completion) completion(metadata.icon);
    }];
}

- (void)clearCache
{
    [self.cache removeAllObjects];
}

@end
