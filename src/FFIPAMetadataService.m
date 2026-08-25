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

// ZIP writers are not required to emit explicit directory entries. A valid IPA
// may therefore contain Payload/Foo.app/Info.plist without ever containing a
// Payload/Foo.app/ entry. Derive the main bundle root from the Info.plist path
// itself and only accept a first-level app directly below Payload so embedded
// Watch apps / PlugIns are never mistaken for the main application.
static NSString *FFIPAMainAppRoot(NSArray<FFArchiveEntry *> *entries)
{
    NSString *best = nil;
    for (FFArchiveEntry *entry in entries) {
        if (entry.isDirectory) continue;
        NSString *path = [entry.entryPath stringByTrimmingCharactersInSet:
            [NSCharacterSet characterSetWithCharactersInString:@"/"]];
        NSArray<NSString *> *parts = path.pathComponents;
        if (parts.count != 3) continue;
        if ([parts[0] caseInsensitiveCompare:@"Payload"] != NSOrderedSame) continue;
        if ([parts[1].pathExtension caseInsensitiveCompare:@"app"] != NSOrderedSame) continue;
        if ([parts[2] caseInsensitiveCompare:@"Info.plist"] != NSOrderedSame) continue;
        NSString *candidate = [NSString pathWithComponents:@[parts[0], parts[1]]];
        if (!best || [candidate compare:best options:NSCaseInsensitiveSearch] == NSOrderedAscending)
            best = candidate;
    }

    // Compatibility fallback for unusual archives that do have an explicit
    // app directory but whose Info.plist could not be listed/decoded.
    if (!best) {
        for (FFArchiveEntry *entry in entries) {
            NSString *trimmed = [entry.entryPath stringByTrimmingCharactersInSet:
                [NSCharacterSet characterSetWithCharactersInString:@"/"]];
            NSArray<NSString *> *parts = trimmed.pathComponents;
            if (parts.count != 2) continue;
            if ([parts[0] caseInsensitiveCompare:@"Payload"] != NSOrderedSame) continue;
            if ([parts[1].pathExtension caseInsensitiveCompare:@"app"] != NSOrderedSame) continue;
            best = trimmed;
            break;
        }
    }
    return best;
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
    for (NSString *iconsKey in @[@"CFBundleIcons", @"CFBundleIcons~ipad"]) {
        NSDictionary *icons = [info[iconsKey] isKindOfClass:NSDictionary.class] ? info[iconsKey] : nil;
        NSDictionary *primary = [icons[@"CFBundlePrimaryIcon"] isKindOfClass:NSDictionary.class]
            ? icons[@"CFBundlePrimaryIcon"] : nil;
        append(primary[@"CFBundleIconFiles"]);
        append(primary[@"CFBundleIconName"]);
    }
    NSMutableOrderedSet *dedup = [NSMutableOrderedSet orderedSet];
    for (NSString *name in names) {
        NSString *base = name.lastPathComponent;
        if (base.length) [dedup addObject:base];
    }
    return dedup.array;
}

static NSInteger FFIPAIconScore(NSString *entryPath, NSArray<NSString *> *declaredNames)
{
    NSString *lower = entryPath.lastPathComponent.lowercaseString;
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
        else if (d.length >= 4 && [f containsString:d]) score += 700;
    }
    if ([lower containsString:@"60x60"] || [lower containsString:@"76x76"] ||
        [lower containsString:@"83.5x83.5"] || [lower containsString:@"1024x1024"])
        score += 120;
    return score;
}

- (FFIPAMetadata *)metadataForIPAAtPath:(NSString *)path error:(NSError **)error
{
    if (!path.length) {
        if (error) *error = [NSError errorWithDomain:@"FFIPA" code:1
            userInfo:@{NSLocalizedDescriptionKey:@"IPA 路径为空"}];
        return nil;
    }
    NSString *key = FFIPACacheKey(path);
    FFIPAMetadata *cached = [self.cache objectForKey:key];
    if (cached) return cached;

    FFArchiveService *archive = [FFArchiveService new];
    NSArray<FFArchiveEntry *> *entries = [archive listEntries:path error:error];
    if (!entries) return nil;

    NSString *appRoot = FFIPAMainAppRoot(entries);
    if (!appRoot) {
        if (error) *error = [NSError errorWithDomain:@"FFIPA" code:2
            userInfo:@{NSLocalizedDescriptionKey:@"归档中找不到主应用 Payload/*.app/Info.plist"}];
        return nil;
    }

    NSString *tempDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"ffipa-%@", NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:tempDir
        withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *infoEntry = [appRoot stringByAppendingPathComponent:@"Info.plist"];
    NSString *infoPath = [archive extractEntry:infoEntry fromArchive:path
        toDirectory:tempDir error:error];
    NSDictionary *info = infoPath ? [NSDictionary dictionaryWithContentsOfFile:infoPath] : nil;
    if (![info isKindOfClass:NSDictionary.class]) {
        [NSFileManager.defaultManager removeItemAtPath:tempDir error:nil];
        if (error && !*error) *error = [NSError errorWithDomain:@"FFIPA" code:3
            userInfo:@{NSLocalizedDescriptionKey:@"无法解析 IPA 中的 Info.plist"}];
        return nil;
    }

    NSArray<NSString *> *declaredNames = FFIPAIconNamesFromInfo(info);
    NSString *bestIconEntry = nil;
    NSInteger bestScore = NSIntegerMin;
    NSString *appPrefix = [appRoot stringByAppendingString:@"/"];
    for (FFArchiveEntry *entry in entries) {
        if (entry.isDirectory || ![entry.entryPath hasPrefix:appPrefix]) continue;
        NSString *relative = [entry.entryPath substringFromIndex:appPrefix.length];
        // Main app icon PNGs are normally at bundle root. Ignore nested
        // extension/watch/resource icons so the app's own icon always wins.
        if ([relative containsString:@"/"]) continue;
        NSInteger score = FFIPAIconScore(entry.entryPath, declaredNames);
        if (score > bestScore) {
            bestScore = score;
            bestIconEntry = entry.entryPath;
        }
    }

    UIImage *icon = nil;
    if (bestIconEntry && bestScore > 0) {
        NSString *iconPath = [archive extractEntry:bestIconEntry fromArchive:path
            toDirectory:tempDir error:nil];
        if (iconPath) icon = [UIImage imageWithContentsOfFile:iconPath];
    }

    FFIPAMetadata *metadata = [FFIPAMetadata new];
    metadata.displayName = [info[@"CFBundleDisplayName"] isKindOfClass:NSString.class]
        ? info[@"CFBundleDisplayName"]
        : ([info[@"CFBundleName"] isKindOfClass:NSString.class]
            ? info[@"CFBundleName"] : appRoot.lastPathComponent.stringByDeletingPathExtension);
    metadata.bundleIdentifier = [info[@"CFBundleIdentifier"] isKindOfClass:NSString.class]
        ? info[@"CFBundleIdentifier"] : @"?";
    metadata.version = [info[@"CFBundleShortVersionString"] isKindOfClass:NSString.class]
        ? info[@"CFBundleShortVersionString"] : @"?";
    metadata.build = [info[@"CFBundleVersion"] isKindOfClass:NSString.class]
        ? info[@"CFBundleVersion"] : @"?";
    metadata.minimumOS = [info[@"MinimumOSVersion"] isKindOfClass:NSString.class]
        ? info[@"MinimumOSVersion"] : @"?";
    metadata.executableName = [info[@"CFBundleExecutable"] isKindOfClass:NSString.class]
        ? info[@"CFBundleExecutable"] : nil;
    metadata.appBundlePath = appRoot;
    metadata.icon = icon;

    [self.cache setObject:metadata forKey:key];
    [NSFileManager.defaultManager removeItemAtPath:tempDir error:nil];
    FFLogTag(@"IPA", @"metadata parsed %@ (%@) root=%@ icon=%@",
        metadata.displayName, metadata.bundleIdentifier, appRoot, icon ? @"yes" : @"no");
    return metadata;
}

- (void)metadataForIPAAtPath:(NSString *)path
                  completion:(void (^)(FFIPAMetadata *, NSError *))completion
{
    dispatch_async(self.queue, ^{
        NSError *error = nil;
        FFIPAMetadata *metadata = [self metadataForIPAAtPath:path error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(metadata, error);
        });
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
