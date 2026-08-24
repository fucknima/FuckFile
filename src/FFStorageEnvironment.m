#import "FFStorageEnvironment.h"

#import <sys/stat.h>
#import <unistd.h>

NSString *FFStorageRootPath(void)
{
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSHomeDirectory();
    NSString *root = [documents stringByAppendingPathComponent:@"Device Storage"];
    [NSFileManager.defaultManager createDirectoryAtPath:root
        withIntermediateDirectories:YES attributes:nil error:nil];
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
    return @[@"AppData", @"App Data", @"ACCESS MAP.txt"];
}

static BOOL FFIsManagedRootName(NSString *name)
{
    if (!name.length) return NO;
    if ([FFManagedSystemEntryNames() containsObject:name]) return YES;
    // MCM advanced probes are intentionally namespaced this way. Keep the
    // predicate generic so future [MHA-*] links do not leak into normal mode.
    return [name hasPrefix:@"[MHA-"];
}

BOOL FFPathRequiresSystemAccess(NSString *path)
{
    if (!path.length) return NO;
    NSString *candidate = path.stringByStandardizingPath;
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
        struct stat st = {0};
        if (lstat(child.fileSystemRepresentation, &st) == 0 && S_ISLNK(st.st_mode))
            unlink(child.fileSystemRepresentation);
    }
    if ([NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:nil].count == 0)
        [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
}

void FFPrepareStorageRootForNormalMode(void)
{
    NSString *root = FFStorageRootPath();
    // AppData/App Data are generated containers populated with symlinks. Remove
    // only generated symlinks and delete the directory only if it becomes empty;
    // never delete a real user-created file or directory tree.
    FFRemoveGeneratedSymlinksInDirectory([root stringByAppendingPathComponent:@"AppData"]);
    FFRemoveGeneratedSymlinksInDirectory([root stringByAppendingPathComponent:@"App Data"]);

    // Root-level [MHA-*] entries are generated advanced-access symlinks too
    // (for example MobileGestalt). They must not survive into normal mode.
    for (NSString *name in [NSFileManager.defaultManager
            contentsOfDirectoryAtPath:root error:nil] ?: @[]) {
        if (![name hasPrefix:@"[MHA-"]) continue;
        NSString *path = [root stringByAppendingPathComponent:name];
        struct stat st = {0};
        if (lstat(path.fileSystemRepresentation, &st) == 0 && S_ISLNK(st.st_mode))
            unlink(path.fileSystemRepresentation);
    }

    NSString *map = [root stringByAppendingPathComponent:@"ACCESS MAP.txt"];
    struct stat st = {0};
    if (lstat(map.fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode))
        [NSFileManager.defaultManager removeItemAtPath:map error:nil];
}
