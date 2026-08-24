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

BOOL FFPathRequiresSystemAccess(NSString *path)
{
    if (!path.length) return NO;
    NSString *candidate = path.stringByStandardizingPath;
    NSString *root = FFStorageRootPath().stringByStandardizingPath;
    for (NSString *name in FFManagedSystemEntryNames()) {
        NSString *managed = [root stringByAppendingPathComponent:name].stringByStandardizingPath;
        if ([candidate isEqualToString:managed] ||
            [candidate hasPrefix:[managed stringByAppendingString:@"/"]])
            return YES;
    }
    return NO;
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

    NSString *map = [root stringByAppendingPathComponent:@"ACCESS MAP.txt"];
    struct stat st = {0};
    if (lstat(map.fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode))
        [NSFileManager.defaultManager removeItemAtPath:map error:nil];
}
