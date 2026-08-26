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
    return @[@"AppData", @"App Data", @"MobileGestalt", @"ACCESS MAP.txt"];
}

static BOOL FFIsManagedRootName(NSString *name)
{
    if (!name.length) return NO;
    if ([FFManagedSystemEntryNames() containsObject:name]) return YES;
    // Legacy advanced probes used the [MHA-*] namespace. Keep recognising
    // those names so stale links from older builds remain access-gated and can
    // be removed safely during migration/normal-mode cleanup.
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

static void FFRemoveGeneratedRootLink(NSString *root, NSString *name)
{
    NSString *path = [root stringByAppendingPathComponent:name];
    struct stat st = {0};
    if (lstat(path.fileSystemRepresentation, &st) == 0 && S_ISLNK(st.st_mode))
        unlink(path.fileSystemRepresentation);
}

void FFPrepareStorageRootForNormalMode(void)
{
    NSString *root = FFStorageRootPath();
    // AppData/App Data are generated containers populated with symlinks. Remove
    // only generated symlinks and delete the directory only if it becomes empty;
    // never delete a real user-created file or directory tree.
    FFRemoveGeneratedSymlinksInDirectory([root stringByAppendingPathComponent:@"AppData"]);
    FFRemoveGeneratedSymlinksInDirectory([root stringByAppendingPathComponent:@"App Data"]);

    // The current MobileGestalt shortcut uses the concise name. Older builds
    // used [MHA-C12] MobileGestalt Cache; remove both when advanced access is
    // disabled so no stale session lease survives across launches/modes.
    FFRemoveGeneratedRootLink(root, @"MobileGestalt");
    for (NSString *name in [NSFileManager.defaultManager
            contentsOfDirectoryAtPath:root error:nil] ?: @[]) {
        if (![name hasPrefix:@"[MHA-"]) continue;
        FFRemoveGeneratedRootLink(root, name);
    }

    NSString *map = [root stringByAppendingPathComponent:@"ACCESS MAP.txt"];
    struct stat st = {0};
    if (lstat(map.fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode))
        [NSFileManager.defaultManager removeItemAtPath:map error:nil];
}
