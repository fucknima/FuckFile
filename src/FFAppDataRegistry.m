#import "FFAppDataRegistry.h"
#import "FFStorageEnvironment.h"
#import "FFAppNames.h"
#import "MCMManager.h"
#import "FFLogger.h"

#import <limits.h>
#import <sys/stat.h>
#import <unistd.h>

NSNotificationName const FFAppDataRegistryDidChangeNotification =
    @"FFAppDataRegistryDidChangeNotification";

static NSString *const kFFAppDataRegistryKey = @"FFAppDataVirtualRegistryV1";

@implementation FFAppDataRegistry {
    NSMutableDictionary<NSString *, NSString *> *_entries;
    BOOL _preparedLegacyLinks;
}

+ (instancetype)sharedRegistry
{
    static FFAppDataRegistry *registry;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ registry = [FFAppDataRegistry new]; });
    return registry;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        NSDictionary *stored = [NSUserDefaults.standardUserDefaults
            dictionaryForKey:kFFAppDataRegistryKey];
        _entries = [NSMutableDictionary dictionary];
        [stored enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            (void)stop;
            if (![key isKindOfClass:NSString.class]) return;
            NSString *identifier = key;
            if (![self.class safeIdentifier:identifier]) return;
            NSString *name = [value isKindOfClass:NSString.class] ? value : @"";
            _entries[identifier] = name ?: @"";
        }];
    }
    return self;
}

+ (BOOL)safeIdentifier:(NSString *)identifier
{
    if (identifier.length < 3 || identifier.length > 255) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"];
    return [identifier rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound &&
        ![identifier hasPrefix:@"."] && ![identifier hasSuffix:@"."] &&
        ![identifier containsString:@".."] && [identifier containsString:@"."];
}

- (NSArray<NSString *> *)identifiers
{
    @synchronized (self) {
        return [_entries.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    }
}

- (NSString *)displayNameForIdentifier:(NSString *)identifier
{
    if (!identifier.length) return nil;
    @synchronized (self) {
        NSString *stored = _entries[identifier];
        return stored.length ? [stored copy] : nil;
    }
}

- (BOOL)containsIdentifier:(NSString *)identifier
{
    if (!identifier.length) return NO;
    @synchronized (self) { return _entries[identifier] != nil; }
}

- (void)persistLocked
{
    [NSUserDefaults.standardUserDefaults setObject:_entries.copy
                                             forKey:kFFAppDataRegistryKey];
}

- (void)publishChange
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter
            postNotificationName:FFAppDataRegistryDidChangeNotification object:self];
        // Existing browser code already listens for this notification to refresh
        // AppData links. Reuse it while the UI transitions from physical links to
        // logical registry-backed nodes.
        [NSNotificationCenter.defaultCenter
            postNotificationName:FFMCMAppLinksUpdatedNotification object:self];
    });
}

- (BOOL)registerIdentifier:(NSString *)identifier displayName:(NSString *)displayName
{
    if (![self.class safeIdentifier:identifier]) return NO;
    NSString *cleanName = [displayName stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    BOOL changed = NO;
    @synchronized (self) {
        NSString *previous = _entries[identifier];
        if (!previous) {
            _entries[identifier] = cleanName.length ? cleanName : @"";
            changed = YES;
        } else if (cleanName.length && ![previous isEqualToString:cleanName]) {
            _entries[identifier] = cleanName;
            changed = YES;
        }
        if (changed) [self persistLocked];
    }
    if (changed) {
        FFLogTag(@"AppDataRegistry", @"registered id=%@ name=%@",
            identifier, cleanName.length ? cleanName : @"(none)");
        [self publishChange];
    }
    return changed;
}

- (void)prepareVirtualRootAndMigrateLegacyLinks
{
    BOOL shouldPrepare = NO;
    @synchronized (self) {
        if (!_preparedLegacyLinks) {
            _preparedLegacyLinks = YES;
            shouldPrepare = YES;
        }
    }
    if (!shouldPrepare) return;

    NSString *root = FFAppDataVirtualPath();
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:root withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions: @0700} error:nil];

    NSArray<NSString *> *children = [fm contentsOfDirectoryAtPath:root error:nil] ?: @[];
    NSUInteger migrated = 0;
    NSUInteger removed = 0;
    for (NSString *name in children) {
        if (![self.class safeIdentifier:name]) continue;
        NSString *path = [root stringByAppendingPathComponent:name];
        struct stat st = {0};
        if (lstat(path.fileSystemRepresentation, &st) != 0 || !S_ISLNK(st.st_mode))
            continue;

        NSString *displayName = nil;
        char target[PATH_MAX] = {0};
        ssize_t length = readlink(path.fileSystemRepresentation, target, sizeof(target) - 1);
        if (length > 0) {
            target[length] = '\0';
            NSString *targetPath = [NSString stringWithUTF8String:target];
            displayName = FFAppContainerItemName(targetPath);
        }
        if ([self registerIdentifier:name displayName:displayName]) migrated++;

        // These links were generated by the old AppData implementation. Their
        // target may be inaccessible until this process acquires a new MCM lease,
        // so keeping them across launches creates the stale/empty-folder bug.
        if (unlink(path.fileSystemRepresentation) == 0) removed++;
    }

    FFLogTag(@"AppDataRegistry", @"legacy migration entries=%lu removedLinks=%lu known=%lu",
        (unsigned long)migrated, (unsigned long)removed,
        (unsigned long)self.identifiers.count);
}

@end
