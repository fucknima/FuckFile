#import "MCMManager.h"
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
    // Preserve the existing map-generation logic exactly, then relocate only
    // the generated diagnostic file. This avoids touching MCM discovery/linking.
    [self ff_diagnostics_writeAccessMap:root];
    if (!root.length) return;

    NSString *source = [root stringByAppendingPathComponent:@"ACCESS MAP.txt"];
    struct stat st = {0};
    if (lstat(source.fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode)) return;

    NSString *documents = root.stringByDeletingLastPathComponent;
    NSString *destination = [documents stringByAppendingPathComponent:@"ACCESS MAP.txt"];
    NSFileManager *fm = NSFileManager.defaultManager;

    // The map is regenerated from current state, so replacing the previous
    // parent copy is intentional. Use a temporary sibling + replace/move to keep
    // the visible diagnostic file from ever being partially written.
    NSString *temporary = [documents stringByAppendingPathComponent:@".ACCESS MAP.txt.tmp"];
    [fm removeItemAtPath:temporary error:nil];
    NSError *moveError = nil;
    if (![fm moveItemAtPath:source toPath:temporary error:&moveError]) {
        FFLogTag(@"Diagnostics", @"ACCESS MAP relocate staging failed error=%@",
            moveError.localizedDescription ?: @"(nil)");
        return;
    }

    [fm removeItemAtPath:destination error:nil];
    if (![fm moveItemAtPath:temporary toPath:destination error:&moveError]) {
        // Best effort rollback: do not lose diagnostics if the second rename
        // unexpectedly fails.
        [fm moveItemAtPath:temporary toPath:source error:nil];
        FFLogTag(@"Diagnostics", @"ACCESS MAP relocate commit failed error=%@",
            moveError.localizedDescription ?: @"(nil)");
        return;
    }
    FFLogTag(@"Diagnostics", @"ACCESS MAP relocated outside Device Storage");
}

@end
