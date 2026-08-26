#import "FFStorageEnvironment.h"

#import <sys/stat.h>
#import <unistd.h>

static void FFMigrateLegacyDiagnosticMap(NSString *documents, NSString *root)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *oldPath = [root stringByAppendingPathComponent:@"ACCESS MAP.txt"];
        NSString *newPath = [documents stringByAppendingPathComponent:@"ACCESS MAP.txt"];
        struct stat st = {0};
        if (lstat(oldPath.fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode)) return;
        if (![fm fileExistsAtPath:newPath]) {
            NSError *error = nil;
            if ([fm moveItemAtPath:oldPath toPath:newPath error:&error]) return;
        }
        // If the parent already has a newer diagnostic map, the Device Storage
        // copy is generated state and can be removed safely.
        [fm removeItemAtPath:oldPath error:nil];
    });
}

NSString *FFStorageRootPath(void)
{
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSHomeDirectory();
    NSString *root = [documents stringByAppendingPathComponent:@"Device Storage"];
    [NSFileManager.defaultManager createDirectoryAtPath:root
        withIntermediateDirectories:YES attributes:nil error:nil];
    FFMigrateLegacyDiagnosticMap(documents, root);
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
    // ACCESS MAP.txt remains listed only for legacy safety. New builds place it
    // one level above Device Storage and never expose it as normal user content.
    return @[@"AppData", @"App Data", @"MobileGestalt", @"ACCESS MAP.txt"];
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
    FFRemoveGeneratedSymlinksInDirectory([root stringByAppendingPathComponent:@"AppData"]);
    FFRemoveGeneratedSymlinksInDirectory([root stringByAppendingPathComponent:@"App Data"]);

    FFRemoveGeneratedRootLink(root, @"MobileGestalt");
    for (NSString *name in [NSFileManager.defaultManager
            contentsOfDirectoryAtPath:root error:nil] ?: @[]) {
        if (![name hasPrefix:@"[MHA-"]) continue;
        FFRemoveGeneratedRootLink(root, name);
    }

    // Legacy cleanup only. Current builds relocate ACCESS MAP.txt to Documents
    // immediately after it is generated.
    NSString *map = [root stringByAppendingPathComponent:@"ACCESS MAP.txt"];
    struct stat st = {0};
    if (lstat(map.fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode))
        [NSFileManager.defaultManager removeItemAtPath:map error:nil];
}
