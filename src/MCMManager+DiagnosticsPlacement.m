#import "MCMManager.h"
#import "FFStorageEnvironment.h"
#import "FFLogger.h"
#import <objc/runtime.h>
#import <sys/stat.h>

@interface MCMManager (FFDiagnosticsPlacementPrivate)
- (void)writeAccessMap:(NSString *)root;
- (void)ff_diagnostics_writeAccessMap:(NSString *)root;
@end

@implementation MCMManager (DiagnosticsPlacement)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method original = class_getInstanceMethod(self, @selector(writeAccessMap:));
        Method replacement = class_getInstanceMethod(self, @selector(ff_diagnostics_writeAccessMap:));
        if (original && replacement) method_exchangeImplementations(original, replacement);
    });
}

- (void)ff_diagnostics_writeAccessMap:(NSString *)root
{
    // Preserve MCM's existing map-generation logic, then immediately move the
    // generated file out of the user-visible Documents tree into app tmp.
    [self ff_diagnostics_writeAccessMap:root];
    if (!root.length) return;

    NSString *source = [root stringByAppendingPathComponent:@"ACCESS MAP.txt"];
    struct stat st = {0};
    if (lstat(source.fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode)) return;

    NSString *diagnostics = FFDiagnosticsDirectoryPath();
    NSString *destination = [diagnostics stringByAppendingPathComponent:@"ACCESS MAP.txt"];
    NSString *temporary = [diagnostics stringByAppendingPathComponent:@".ACCESS MAP.txt.tmp"];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:diagnostics withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions:@0700} error:nil];
    [fm removeItemAtPath:temporary error:nil];

    NSError *moveError = nil;
    if (![fm moveItemAtPath:source toPath:temporary error:&moveError]) {
        FFLogTag(@"Diagnostics", @"ACCESS MAP tmp staging failed error=%@",
            moveError.localizedDescription ?: @"(nil)");
        return;
    }

    [fm removeItemAtPath:destination error:nil];
    if (![fm moveItemAtPath:temporary toPath:destination error:&moveError]) {
        // Best-effort rollback keeps diagnostics available without leaving a
        // partial destination. A later storage migration will relocate it.
        [fm moveItemAtPath:temporary toPath:source error:nil];
        FFLogTag(@"Diagnostics", @"ACCESS MAP tmp commit failed error=%@",
            moveError.localizedDescription ?: @"(nil)");
        return;
    }
    FFLogTag(@"Diagnostics", @"ACCESS MAP moved to app tmp");
}

@end
