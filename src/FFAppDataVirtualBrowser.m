#import "FFBrowserViewController.h"
#import "FFAppDataRegistry.h"
#import "FFAppDataVirtualPath.h"
#import "FFStorageEnvironment.h"
#import "FFSystemAccessManager.h"
#import "FFAppNames.h"
#import "FFLogger.h"

#import <objc/runtime.h>

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
            [items addObject:item];
        }
        [items sortUsingComparator:^NSComparisonResult(FFEntry *left, FFEntry *right) {
            NSString *a = left.displayName.length ? left.displayName : left.name;
            NSString *b = right.displayName.length ? right.displayName : right.name;
            return [a localizedCaseInsensitiveCompare:b];
        }];
        FFLogTag(@"AppDataVirtual", @"root rendered from registry count=%lu",
            (unsigned long)items.count);
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
