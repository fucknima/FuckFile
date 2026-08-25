#import "FFBrowserViewController.h"
#import "FFAppDataRegistry.h"
#import "FFAppDataVirtualPath.h"
#import "FFStorageEnvironment.h"
#import "FFSystemAccessManager.h"
#import "FFAppNames.h"
#import "FFLogger.h"

#import <objc/runtime.h>
#import <sys/stat.h>

typedef NS_ENUM(NSInteger, FFAppDataVirtualSortMode) {
    FFAppDataVirtualSortModeName = 0,
    FFAppDataVirtualSortModeSize,
    FFAppDataVirtualSortModeDate,
    FFAppDataVirtualSortModeKind,
};

static NSString *FFAppDataVirtualEntrySortName(FFEntry *entry)
{
    return entry.displayName.length ? entry.displayName : entry.name;
}

@implementation FFBrowserViewController (FFAppDataVirtualBrowser)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = FFBrowserViewController.class;
        Method originalLoad = class_getInstanceMethod(cls, NSSelectorFromString(@"loadDirectoryContents"));
        Method virtualLoad = class_getInstanceMethod(cls, @selector(ff_appData_loadDirectoryContents));
        if (originalLoad && virtualLoad) method_exchangeImplementations(originalLoad, virtualLoad);

        Method originalOpen = class_getInstanceMethod(cls,
            @selector(openItemAtPath:title:navigationController:completion:));
        Method virtualOpen = class_getInstanceMethod(cls,
            @selector(ff_appData_openItemAtPath:title:navigationController:completion:));
        if (originalOpen && virtualOpen) method_exchangeImplementations(originalOpen, virtualOpen);
    });
}

- (NSArray<FFEntry *> *)ff_appData_loadDirectoryContents
{
    NSString *logicalPath = self.currentPath.stringByStandardizingPath;
    if (FFAppDataIsVirtualRootPath(logicalPath)) {
        if (!FFSystemAccessManager.sharedManager.ready) {
            [self setValue:@"高级系统访问尚未就绪" forKey:@"loadError"];
            return @[];
        }

        FFAppDataRegistry *registry = FFAppDataRegistry.sharedRegistry;
        [registry prepareVirtualRootAndMigrateLegacyLinks];
        [self setValue:nil forKey:@"loadError"];

        NSMutableArray<FFEntry *> *items = [NSMutableArray array];
        for (NSString *identifier in registry.identifiers) {
            FFEntry *item = [FFEntry new];
            item.name = identifier;
            item.displayName = [registry displayNameForIdentifier:identifier] ?: FFAppDisplayName(identifier);
            item.path = [FFAppDataVirtualPath() stringByAppendingPathComponent:identifier];
            item.isDirectory = YES;
            item.isSymlink = NO;
            item.isAppContainer = YES;
            item.containerIdentifier = identifier;
            item.detail = @"App 数据 · 按需连接";
            item.fullDetail = item.detail;

            // Do not acquire a lease just to sort. If this app is already
            // materialized in the current process, opportunistically expose the
            // same lightweight stat metadata used by the normal browser. This
            // makes date/size sorting useful for connected entries without
            // turning a UI sort into a 200+ container scan.
            struct stat st = {0};
            if (stat(item.path.fileSystemRepresentation, &st) == 0) {
                item.size = (unsigned long long)st.st_size;
                item.modificationDate = [NSDate dateWithTimeIntervalSince1970:st.st_mtime];
            }
            [items addObject:item];
        }

        // The virtual-root loader bypasses FFBrowserViewController's normal
        // loadDirectoryContents implementation, so it must apply the browser's
        // active sort state itself. Previously this block always sorted by
        // display name ascending, which made every sort-menu change appear dead.
        NSInteger sortMode = [[self valueForKey:@"sortMode"] integerValue];
        BOOL descending = [[self valueForKey:@"sortDescending"] boolValue];
        [items sortUsingComparator:^NSComparisonResult(FFEntry *left, FFEntry *right) {
            NSComparisonResult comparison = NSOrderedSame;
            switch ((FFAppDataVirtualSortMode)sortMode) {
                case FFAppDataVirtualSortModeSize:
                    if (left.size != right.size)
                        comparison = left.size > right.size ? NSOrderedAscending : NSOrderedDescending;
                    break;
                case FFAppDataVirtualSortModeDate: {
                    NSDate *leftDate = left.modificationDate;
                    NSDate *rightDate = right.modificationDate;
                    if (leftDate && rightDate)
                        comparison = [rightDate compare:leftDate];
                    else if (leftDate || rightDate)
                        comparison = leftDate ? NSOrderedAscending : NSOrderedDescending;
                    break;
                }
                case FFAppDataVirtualSortModeKind:
                    // Every virtual AppData node is the same kind (directory),
                    // so kind sorting intentionally falls through to its stable
                    // display-name tie breaker.
                    break;
                case FFAppDataVirtualSortModeName:
                default:
                    comparison = [FFAppDataVirtualEntrySortName(left)
                        localizedCaseInsensitiveCompare:FFAppDataVirtualEntrySortName(right)];
                    break;
            }
            if (comparison == NSOrderedSame)
                comparison = [FFAppDataVirtualEntrySortName(left)
                    localizedCaseInsensitiveCompare:FFAppDataVirtualEntrySortName(right)];
            if (comparison == NSOrderedSame)
                comparison = [left.name compare:right.name options:NSNumericSearch];
            return descending ? -comparison : comparison;
        }];
        FFLogTag(@"AppDataVirtual", @"root rendered from registry count=%lu sort=%ld descending=%d",
            (unsigned long)items.count, (long)sortMode, descending);
        return items;
    }

    NSString *identifier = nil;
    if (FFAppDataExtractLogicalIdentifier(logicalPath, &identifier, NULL)) {
        NSError *error = nil;
        if (!FFAppDataEnsureLogicalPathMaterialized(logicalPath, &error)) {
            NSString *message = error.localizedDescription.length
                ? [NSString stringWithFormat:@"无法连接 %@：%@", identifier, error.localizedDescription]
                : [NSString stringWithFormat:@"无法连接 %@ 的 App Data", identifier];
            [self setValue:message forKey:@"loadError"];
            FFLogTag(@"AppDataVirtual", @"directory materialization failed path=%@ error=%@",
                logicalPath, error.localizedDescription ?: @"(nil)");
            return @[];
        }
        [self setValue:nil forKey:@"loadError"];
    }

    // Swizzled selector now points to the original implementation. Session-only
    // materialization keeps all existing browser/file-operation paths logical,
    // while the current process owns the MCM lease that makes them readable.
    return [self ff_appData_loadDirectoryContents];
}

- (void)ff_appData_openItemAtPath:(NSString *)path
                            title:(NSString *)title
             navigationController:(UINavigationController *)nav
                        completion:(void (^)(BOOL))completion
{
    NSString *identifier = nil;
    if (!FFAppDataExtractLogicalIdentifier(path, &identifier, NULL)) {
        [self ff_appData_openItemAtPath:path title:title navigationController:nav completion:completion];
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        BOOL ready = FFAppDataEnsureLogicalPathMaterialized(path, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ready) {
                FFLogTag(@"AppDataVirtual", @"direct open failed id=%@ path=%@ error=%@",
                    identifier, path, error.localizedDescription ?: @"(nil)");
                if (completion) completion(NO);
                return;
            }
            [self ff_appData_openItemAtPath:path title:title
                       navigationController:nav completion:completion];
        });
    });
}

@end
