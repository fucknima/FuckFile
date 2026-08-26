#import "FFBrowserViewController.h"
#import "FFAppDataRegistry.h"
#import "FFAppDataVirtualPath.h"
#import "FFStorageEnvironment.h"
#import "FFSystemAccessManager.h"
#import "FFAppNames.h"
#import "FFLogger.h"

#import <objc/message.h>
#import <objc/runtime.h>
#import <sys/stat.h>

typedef NS_ENUM(NSInteger, FFAppDataVirtualSortMode) {
    FFAppDataVirtualSortModeName = 0,
    FFAppDataVirtualSortModeSize,
    FFAppDataVirtualSortModeDate,
    FFAppDataVirtualSortModeKind,
};

typedef NS_ENUM(NSInteger, FFAppDataFilterMode) {
    FFAppDataFilterModeAll = 0,
    FFAppDataFilterModeUser,
    FFAppDataFilterModeSystem,
};

typedef NS_ENUM(NSInteger, FFAppDataApplicationKind) {
    FFAppDataApplicationKindUnknown = 0,
    FFAppDataApplicationKindUser,
    FFAppDataApplicationKindSystem,
};

static NSString *const kFFAppDataFilterModeKey = @"FFAppDataFilterModeV1";
static const void *kFFAppDataFilterControlKey = &kFFAppDataFilterControlKey;

static NSString *FFAppDataVirtualEntrySortName(FFEntry *entry)
{
    return entry.displayName.length ? entry.displayName : entry.name;
}

static FFAppDataFilterMode FFCurrentAppDataFilterMode(void)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSNumber *saved = [defaults objectForKey:kFFAppDataFilterModeKey];
    NSInteger value = saved ? saved.integerValue : FFAppDataFilterModeUser;
    if (value < FFAppDataFilterModeAll || value > FFAppDataFilterModeSystem)
        value = FFAppDataFilterModeUser;
    return (FFAppDataFilterMode)value;
}

// LaunchServices already owns the authoritative System/User distinction.  Use
// LSApplicationProxy dynamically so FuckFile does not duplicate that policy or
// misclassify apps merely because their bundle identifier starts with com.apple.
static FFAppDataApplicationKind FFApplicationKindForIdentifier(NSString *identifier)
{
    if (!identifier.length) return FFAppDataApplicationKindUnknown;

    static NSMutableDictionary<NSString *, NSNumber *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ cache = [NSMutableDictionary dictionary]; });

    @synchronized (cache) {
        NSNumber *cached = cache[identifier];
        if (cached) return (FFAppDataApplicationKind)cached.integerValue;
    }

    FFAppDataApplicationKind kind = FFAppDataApplicationKindUnknown;
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL factory = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (proxyClass && [proxyClass respondsToSelector:factory]) {
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)((id)proxyClass, factory, identifier);
        SEL typeSelector = NSSelectorFromString(@"applicationType");
        if (proxy && [proxy respondsToSelector:typeSelector]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(proxy, typeSelector);
            if ([value isKindOfClass:NSString.class]) {
                NSString *type = (NSString *)value;
                if ([type caseInsensitiveCompare:@"System"] == NSOrderedSame)
                    kind = FFAppDataApplicationKindSystem;
                else if ([type caseInsensitiveCompare:@"User"] == NSOrderedSame)
                    kind = FFAppDataApplicationKindUser;
            }
        }

        // Older/newer LaunchServices builds may omit applicationType while still
        // exposing this boolean.  It is a structural fallback, not a bundle-ID
        // naming heuristic.
        if (kind == FFAppDataApplicationKindUnknown && proxy) {
            SEL systemSelector = NSSelectorFromString(@"isSystemOrInternalApp");
            if ([proxy respondsToSelector:systemSelector]) {
                BOOL system = ((BOOL (*)(id, SEL))objc_msgSend)(proxy, systemSelector);
                kind = system ? FFAppDataApplicationKindSystem : FFAppDataApplicationKindUser;
            }
        }
    }

    @synchronized (cache) { cache[identifier] = @(kind); }
    return kind;
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

        Method originalViewDidLoad = class_getInstanceMethod(cls, @selector(viewDidLoad));
        Method virtualViewDidLoad = class_getInstanceMethod(cls, @selector(ff_appData_viewDidLoad));
        if (originalViewDidLoad && virtualViewDidLoad)
            method_exchangeImplementations(originalViewDidLoad, virtualViewDidLoad);
    });
}

- (void)ff_appData_viewDidLoad
{
    [self ff_appData_viewDidLoad];
    if (!FFAppDataIsVirtualRootPath(self.currentPath.stringByStandardizingPath)) return;

    UISegmentedControl *filter = [[UISegmentedControl alloc]
        initWithItems:@[@"全部", @"用户", @"系统"]];
    filter.selectedSegmentIndex = FFCurrentAppDataFilterMode();
    filter.frame = CGRectMake(0, 0, 176, 32);
    filter.accessibilityLabel = @"App Data 类型筛选";
    [filter addTarget:self action:@selector(ff_appData_filterChanged:)
        forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = filter;
    objc_setAssociatedObject(self, kFFAppDataFilterControlKey, filter,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)ff_appData_filterChanged:(UISegmentedControl *)sender
{
    NSInteger selected = sender.selectedSegmentIndex;
    if (selected < FFAppDataFilterModeAll || selected > FFAppDataFilterModeSystem) return;
    [NSUserDefaults.standardUserDefaults setInteger:selected forKey:kFFAppDataFilterModeKey];
    [self reloadEntries];
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

        FFAppDataFilterMode filterMode = FFCurrentAppDataFilterMode();
        NSMutableArray<FFEntry *> *items = [NSMutableArray array];
        NSUInteger userCount = 0;
        NSUInteger systemCount = 0;
        NSUInteger unknownCount = 0;

        for (NSString *identifier in registry.identifiers) {
            FFAppDataApplicationKind kind = FFApplicationKindForIdentifier(identifier);
            if (kind == FFAppDataApplicationKindSystem) systemCount++;
            else if (kind == FFAppDataApplicationKindUser) userCount++;
            else unknownCount++;

            // Unknown records stay with the user-facing set instead of being
            // silently hidden. Only positively confirmed System records enter
            // the System filter.
            if (filterMode == FFAppDataFilterModeUser && kind == FFAppDataApplicationKindSystem)
                continue;
            if (filterMode == FFAppDataFilterModeSystem && kind != FFAppDataApplicationKindSystem)
                continue;

            FFEntry *item = [FFEntry new];
            item.name = identifier;
            item.displayName = [registry displayNameForIdentifier:identifier] ?: FFAppDisplayName(identifier);
            item.path = [FFAppDataVirtualPath() stringByAppendingPathComponent:identifier];
            item.isDirectory = YES;
            item.isSymlink = NO;
            item.isAppContainer = YES;
            item.containerIdentifier = identifier;
            if (kind == FFAppDataApplicationKindSystem)
                item.detail = @"系统 App 数据 · 按需连接";
            else if (kind == FFAppDataApplicationKindUser)
                item.detail = @"用户 App 数据 · 按需连接";
            else
                item.detail = @"App 数据 · 按需连接";
            item.fullDetail = item.detail;

            // Do not acquire a lease just to sort. If this app is already
            // materialized in the current process, opportunistically expose the
            // same lightweight stat metadata used by the normal browser.
            struct stat st = {0};
            if (stat(item.path.fileSystemRepresentation, &st) == 0) {
                item.size = (unsigned long long)st.st_size;
                item.modificationDate = [NSDate dateWithTimeIntervalSince1970:st.st_mtime];
            }
            [items addObject:item];
        }

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
        FFLogTag(@"AppDataVirtual", @"root filter=%ld visible=%lu user=%lu system=%lu unknown=%lu sort=%ld descending=%d",
            (long)filterMode, (unsigned long)items.count, (unsigned long)userCount,
            (unsigned long)systemCount, (unsigned long)unknownCount, (long)sortMode, descending);
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
