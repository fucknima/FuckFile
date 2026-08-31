#import "FFStorageEnvironment.h"

#import <limits.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString *FFDocumentsPath(void)
{
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return documents.length ? documents : [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
}

static NSString *FFLegacyStorageRoot(NSString *documents)
{
    return [documents stringByAppendingPathComponent:@"Device Storage"];
}

static NSString *FFApplicationSupportDirectory(void)
{
    NSString *support = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    if (!support.length) support = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"];
    NSString *directory = [support stringByAppendingPathComponent:@"FuckFile"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory
        withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
    return directory;
}

NSString *FFDiagnosticsDirectoryPath(void)
{
    static NSString *directory;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *tmp = NSTemporaryDirectory();
        if (!tmp.length) tmp = [NSHomeDirectory() stringByAppendingPathComponent:@"tmp"];
        directory = [[tmp stringByAppendingPathComponent:@"FuckFile"]
            stringByAppendingPathComponent:@"Diagnostics"];
        [NSFileManager.defaultManager createDirectoryAtPath:directory
            withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
    });
    return directory;
}

static NSString *FFRewriteLegacyPathString(NSString *path)
{
    if (!path.length || !path.isAbsolutePath) return path;
    NSString *candidate = path.stringByStandardizingPath;
    NSString *documents = FFDocumentsPath().stringByStandardizingPath;
    NSString *legacy = FFLegacyStorageRoot(documents).stringByStandardizingPath;
    if ([candidate isEqualToString:legacy]) return documents;
    NSString *prefix = [legacy stringByAppendingString:@"/"];
    if (![candidate hasPrefix:prefix]) return candidate;
    NSString *suffix = [candidate substringFromIndex:prefix.length];
    return suffix.length ? [documents stringByAppendingPathComponent:suffix] : documents;
}

NSString *FFCanonicalStoragePath(NSString *path)
{
    if (!path.length) return path ?: @"";
    return FFRewriteLegacyPathString(path) ?: path.stringByStandardizingPath;
}

static BOOL FFPathIsSymlink(NSString *path, struct stat *statusOut)
{
    struct stat status = {0};
    if (lstat(path.fileSystemRepresentation, &status) != 0) return NO;
    if (statusOut) *statusOut = status;
    return S_ISLNK(status.st_mode);
}

static BOOL FFPathIsRealDirectory(NSString *path)
{
    struct stat status = {0};
    return lstat(path.fileSystemRepresentation, &status) == 0 &&
        S_ISDIR(status.st_mode) && !S_ISLNK(status.st_mode);
}

static NSString *FFSymlinkTarget(NSString *path)
{
    char target[PATH_MAX] = {0};
    ssize_t length = readlink(path.fileSystemRepresentation, target, sizeof(target) - 1);
    if (length <= 0) return nil;
    target[length] = '\0';
    return [NSString stringWithUTF8String:target];
}

static BOOL FFIsContainerTarget(NSString *target)
{
    if (!target.length) return NO;
    NSString *normalized = target;
    if ([normalized hasPrefix:@"/var/"])
        normalized = [@"/private" stringByAppendingString:normalized];
    return [normalized hasPrefix:@"/private/var/"];
}

static BOOL FFIsLegacyGeneratedSymlink(NSString *name, NSString *path)
{
    if (!FFPathIsSymlink(path, NULL)) return NO;
    NSString *target = FFSymlinkTarget(path);
    if (!FFIsContainerTarget(target)) return NO;
    if ([name isEqualToString:@"MobileGestalt"] || [name hasPrefix:@"[MHA-"])
        return YES;
    // Intermediate builds briefly published App container links flat in the
    // dedicated Device Storage root. Recognize only container-looking bundle
    // identifiers + known container target paths; do not delete arbitrary user
    // symlinks merely because their target happens to live under /var.
    BOOL bundleLike = [name containsString:@"."] && ![name containsString:@"/"];
    BOOL appContainer = [target containsString:@"/Containers/Data/Application/"] ||
        [target containsString:@"/containers/Data/Application/"] ||
        [target containsString:@"/Containers/Shared/AppGroup/"] ||
        [target containsString:@"/containers/Shared/AppGroup/"];
    return bundleLike && appContainer;
}

static NSString *FFUniqueLegacyDestination(NSString *destination)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:destination]) return destination;
    NSString *directory = destination.stringByDeletingLastPathComponent;
    NSString *name = destination.lastPathComponent;
    NSString *extension = name.pathExtension;
    NSString *stem = extension.length ? name.stringByDeletingPathExtension : name;
    for (NSUInteger index = 1; index <= 999; index++) {
        NSString *suffix = index == 1 ? @" (Device Storage)" :
            [NSString stringWithFormat:@" (Device Storage %lu)", (unsigned long)index];
        NSString *candidateName = [stem stringByAppendingString:suffix];
        if (extension.length) candidateName = [candidateName stringByAppendingPathExtension:extension];
        NSString *candidate = [directory stringByAppendingPathComponent:candidateName];
        if (![fm fileExistsAtPath:candidate]) return candidate;
    }
    return nil;
}

static void FFPromoteLegacyItem(NSString *source, NSString *destination)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *name = source.lastPathComponent;
    if (FFIsLegacyGeneratedSymlink(name, source)) {
        [fm removeItemAtPath:source error:nil];
        return;
    }

    BOOL sourceDirectory = FFPathIsRealDirectory(source);
    BOOL destinationDirectory = FFPathIsRealDirectory(destination);
    if (sourceDirectory && destinationDirectory) {
        for (NSString *childName in [fm contentsOfDirectoryAtPath:source error:nil] ?: @[]) {
            NSString *childSource = [source stringByAppendingPathComponent:childName];
            NSString *childDestination = [destination stringByAppendingPathComponent:childName];
            FFPromoteLegacyItem(childSource, childDestination);
        }
        if ([fm contentsOfDirectoryAtPath:source error:nil].count == 0)
            [fm removeItemAtPath:source error:nil];
        return;
    }

    if (![fm fileExistsAtPath:destination]) {
        [fm moveItemAtPath:source toPath:destination error:nil];
        return;
    }

    // Never overwrite a current Documents item. Preserve both under a stable,
    // visible conflict name so flattening the old root cannot lose user data.
    NSString *unique = FFUniqueLegacyDestination(destination);
    if (unique.length) [fm moveItemAtPath:source toPath:unique error:nil];
}

static void FFRelocateGeneratedFile(NSString *source, NSString *destination)
{
    if (!source.length || !destination.length || [source isEqualToString:destination]) return;
    struct stat status = {0};
    if (lstat(source.fileSystemRepresentation, &status) != 0 || !S_ISREG(status.st_mode)) return;
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:destination.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
    if (![fm fileExistsAtPath:destination]) {
        NSError *error = nil;
        if ([fm moveItemAtPath:source toPath:destination error:&error]) return;
    }
    // Generated diagnostics are never user documents. If a newer destination
    // already exists, discard the stale legacy copy rather than exposing it.
    [fm removeItemAtPath:source error:nil];
}

static NSArray *FFRewriteLegacyPathsInObject(id object, BOOL *changedOut);

static id FFRewriteLegacyObject(id object, BOOL *changed)
{
    if ([object isKindOfClass:NSString.class]) {
        NSString *value = object;
        NSString *rewritten = FFRewriteLegacyPathString(value);
        if (![rewritten isEqualToString:value]) {
            if (changed) *changed = YES;
            return rewritten;
        }
        return value;
    }
    if ([object isKindOfClass:NSArray.class]) {
        NSMutableArray *array = [NSMutableArray arrayWithCapacity:[object count]];
        for (id value in (NSArray *)object)
            [array addObject:FFRewriteLegacyObject(value, changed) ?: NSNull.null];
        return array;
    }
    if ([object isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *dictionary = [NSMutableDictionary dictionaryWithCapacity:[object count]];
        [(NSDictionary *)object enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            (void)stop;
            dictionary[key] = FFRewriteLegacyObject(value, changed) ?: NSNull.null;
        }];
        return dictionary;
    }
    return object;
}

static void FFRewritePlistFileLegacyPaths(NSString *path)
{
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length) return;
    NSPropertyListFormat format = NSPropertyListBinaryFormat_v1_0;
    id plist = [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListImmutable format:&format error:nil];
    if (!plist) return;
    BOOL changed = NO;
    id rewritten = FFRewriteLegacyObject(plist, &changed);
    if (!changed || !rewritten) return;
    NSData *newData = [NSPropertyListSerialization dataWithPropertyList:rewritten
        format:format options:0 error:nil];
    if (newData.length) [newData writeToFile:path options:NSDataWritingAtomic error:nil];
}

static void FFMigrateFavoritesFile(NSString *source, NSString *destination)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:source] || [source isEqualToString:destination]) return;
    NSArray *incoming = [NSArray arrayWithContentsOfFile:source];
    NSArray *current = [NSArray arrayWithContentsOfFile:destination];
    if (![incoming isKindOfClass:NSArray.class]) {
        [fm removeItemAtPath:source error:nil];
        return;
    }

    NSMutableArray *merged = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSArray *rows in @[[current isKindOfClass:NSArray.class] ? current : @[], incoming]) {
        for (id value in rows) {
            if (![value isKindOfClass:NSDictionary.class]) continue;
            NSMutableDictionary *row = [value mutableCopy];
            NSString *path = [row[@"Path"] isKindOfClass:NSString.class] ? row[@"Path"] : nil;
            if (path.length) row[@"Path"] = FFRewriteLegacyPathString(path);
            NSString *key = [row[@"Path"] isKindOfClass:NSString.class] ? row[@"Path"] : NSUUID.UUID.UUIDString;
            if ([seen containsObject:key]) continue;
            [seen addObject:key];
            [merged addObject:row];
        }
    }
    [fm createDirectoryAtPath:destination.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
    if ([merged writeToFile:destination atomically:YES]) [fm removeItemAtPath:source error:nil];
}

static void FFMigratePersistentLegacyPaths(NSString *documents, NSString *legacyRoot)
{
    NSString *support = FFApplicationSupportDirectory();
    NSString *favorites = [support stringByAppendingPathComponent:@"Favorites.plist"];
    FFMigrateFavoritesFile([legacyRoot stringByAppendingPathComponent:@"Favorites.plist"], favorites);
    FFMigrateFavoritesFile([documents stringByAppendingPathComponent:@"Favorites.plist"], favorites);
    FFRewritePlistFileLegacyPaths(favorites);

    NSString *tasks = [support stringByAppendingPathComponent:@"TaskHistory.plist"];
    FFRewritePlistFileLegacyPaths(tasks);

    NSArray *recent = [NSUserDefaults.standardUserDefaults arrayForKey:@"FFRecentPaths"];
    if ([recent isKindOfClass:NSArray.class]) {
        BOOL changed = NO;
        id rewritten = FFRewriteLegacyObject(recent, &changed);
        if (changed && [rewritten isKindOfClass:NSArray.class])
            [NSUserDefaults.standardUserDefaults setObject:rewritten forKey:@"FFRecentPaths"];
    }
}

static void FFMigrateDiagnostics(NSString *documents, NSString *legacyRoot)
{
    NSString *diagnostics = FFDiagnosticsDirectoryPath();
    NSString *log = [diagnostics stringByAppendingPathComponent:@"FuckFile Log.txt"];
    NSString *map = [diagnostics stringByAppendingPathComponent:@"ACCESS MAP.txt"];

    // Prefer the most recent flat Documents location first, then the older
    // nested root. Both are generated state and may be safely de-duplicated.
    FFRelocateGeneratedFile([documents stringByAppendingPathComponent:@"FuckFile Log.txt"], log);
    FFRelocateGeneratedFile([legacyRoot stringByAppendingPathComponent:@"FuckFile Log.txt"], log);
    FFRelocateGeneratedFile([documents stringByAppendingPathComponent:@"ACCESS MAP.txt"], map);
    FFRelocateGeneratedFile([legacyRoot stringByAppendingPathComponent:@"ACCESS MAP.txt"], map);

    for (NSString *root in @[documents, legacyRoot]) {
        [NSFileManager.defaultManager removeItemAtPath:
            [root stringByAppendingPathComponent:@"FuckFile Log.old.txt"] error:nil];
        [NSFileManager.defaultManager removeItemAtPath:
            [root stringByAppendingPathComponent:@".ACCESS MAP.txt.tmp"] error:nil];
    }
}

static void FFMigrateLegacyStorageRoot(NSString *documents)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *legacyRoot = FFLegacyStorageRoot(documents);
        FFMigrateDiagnostics(documents, legacyRoot);
        FFMigratePersistentLegacyPaths(documents, legacyRoot);

        if (!FFPathIsRealDirectory(legacyRoot)) return;
        NSFileManager *fm = NSFileManager.defaultManager;
        NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:legacyRoot error:nil] ?: @[];
        for (NSString *name in names) {
            // Internal files were handled above and must not become user-facing
            // Documents entries during the flatten operation.
            if ([name isEqualToString:@"FuckFile Log.txt"] ||
                [name isEqualToString:@"FuckFile Log.old.txt"] ||
                [name isEqualToString:@"ACCESS MAP.txt"] ||
                [name isEqualToString:@".ACCESS MAP.txt.tmp"] ||
                [name isEqualToString:@"Favorites.plist"]) {
                [fm removeItemAtPath:[legacyRoot stringByAppendingPathComponent:name] error:nil];
                continue;
            }

            NSString *destinationName = [name isEqualToString:@"App Data"] ? @"AppData" : name;
            NSString *source = [legacyRoot stringByAppendingPathComponent:name];
            NSString *destination = [documents stringByAppendingPathComponent:destinationName];
            FFPromoteLegacyItem(source, destination);
        }
        if ([fm contentsOfDirectoryAtPath:legacyRoot error:nil].count == 0)
            [fm removeItemAtPath:legacyRoot error:nil];
    });
}

NSString *FFStorageRootPath(void)
{
    static NSString *root;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        root = FFDocumentsPath().stringByStandardizingPath;
        [NSFileManager.defaultManager createDirectoryAtPath:root
            withIntermediateDirectories:YES attributes:nil error:nil];
        FFMigrateLegacyStorageRoot(root);
    });
    return root;
}

NSString *FFImportedDirectoryPath(void)
{
    NSString *path = [FFStorageRootPath() stringByAppendingPathComponent:@"Imported"];
    [NSFileManager.defaultManager createDirectoryAtPath:path
        withIntermediateDirectories:YES attributes:nil error:nil];
    return path;
}

NSString *FFAppDataVirtualPath(void)
{
    return [FFStorageRootPath() stringByAppendingPathComponent:@"AppData"];
}

NSArray<NSString *> *FFManagedSystemEntryNames(void)
{
    return @[@"AppData", @"App Data", @"MobileGestalt",
        @"[MHA-C12] MobileGestalt Cache", @"ACCESS MAP.txt"];
}

BOOL FFIsInternalStorageEntry(NSString *parentPath, NSString *name)
{
    if (!parentPath.length || !name.length) return NO;
    if (![parentPath.stringByStandardizingPath isEqualToString:FFStorageRootPath()]) return NO;
    static NSSet<NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = [NSSet setWithArray:@[
            @"FuckFile Log.txt", @"FuckFile Log.old.txt", @"ACCESS MAP.txt",
            @".ACCESS MAP.txt.tmp", @"Favorites.plist",
            @"LSIdentifierCache.plist", @"LSGroupCache.plist",
        ]];
    });
    return [names containsObject:name];
}

static BOOL FFIsManagedRootName(NSString *name)
{
    if (!name.length) return NO;
    if ([FFManagedSystemEntryNames() containsObject:name]) return YES;
    return [name hasPrefix:@"[MHA-"];
}

BOOL FFPathRequiresSystemAccess(NSString *path)
{
    if (!path.length) return NO;
    NSString *candidate = FFCanonicalStoragePath(path).stringByStandardizingPath;
    NSString *root = FFStorageRootPath().stringByStandardizingPath;
    if (![candidate isEqualToString:root] &&
        ![candidate hasPrefix:[root stringByAppendingString:@"/"]])
        return NO;

    NSString *relative = [candidate substringFromIndex:root.length];
    while ([relative hasPrefix:@"/"]) relative = [relative substringFromIndex:1];
    NSString *firstComponent = relative.pathComponents.firstObject;
    return FFIsManagedRootName(firstComponent);
}

static void FFRemoveGeneratedSymlinksInDirectory(NSString *directory)
{
    BOOL isDirectory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:directory isDirectory:&isDirectory] ||
        !isDirectory) return;

    NSArray<NSString *> *children = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:directory error:nil] ?: @[];
    for (NSString *name in children) {
        NSString *child = [directory stringByAppendingPathComponent:name];
        if (FFPathIsSymlink(child, NULL)) [NSFileManager.defaultManager removeItemAtPath:child error:nil];
    }
    if ([NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil].count == 0)
        [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
}

static void FFRemoveGeneratedRootLink(NSString *root, NSString *name)
{
    NSString *path = [root stringByAppendingPathComponent:name];
    if (FFPathIsSymlink(path, NULL) && FFIsContainerTarget(FFSymlinkTarget(path)))
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
}

void FFPrepareStorageRootForNormalMode(void)
{
    NSString *root = FFStorageRootPath();
    FFRemoveGeneratedSymlinksInDirectory([root stringByAppendingPathComponent:@"AppData"]);
    FFRemoveGeneratedSymlinksInDirectory([root stringByAppendingPathComponent:@"App Data"]);
    FFRemoveGeneratedRootLink(root, @"MobileGestalt");
    FFRemoveGeneratedRootLink(root, @"[MHA-C12] MobileGestalt Cache");

    // Diagnostics were previously generated in either Documents or the nested
    // Device Storage root. Keep normal-mode launch idempotent and user-visible
    // Documents clean by relocating/removing those legacy artifacts as well.
    FFMigrateDiagnostics(root, FFLegacyStorageRoot(root));
    (void)FFImportedDirectoryPath();
}
