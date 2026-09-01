#import "FFBrowserViewController.h"
#import "FFFileTask.h"
#import "FFFileTaskManager.h"
#import "FFLogger.h"
#import "FFPathBreadcrumbView.h"
#import "FFStorageEnvironment.h"

#import <objc/runtime.h>

@interface FFBrowserViewController (FFStorageRootPrivate)
@property(nonatomic, copy) NSString *currentPath;
@property(nonatomic, strong) NSArray<FFEntry *> *entries;
@property(nonatomic, strong) NSArray<FFEntry *> *filteredEntries;
@property(nonatomic, strong) UICollectionView *collectionView;
@property(nonatomic) BOOL gridMode;
@property(nonatomic, strong) FFPathBreadcrumbView *breadcrumbView;
@property(nonatomic, strong) NSLayoutConstraint *breadcrumbHeightConstraint;
@property(nonatomic, copy) NSArray<NSString *> *breadcrumbPaths;

- (instancetype)initWithPath:(NSString *)path;
- (void)viewWillAppear:(BOOL)animated;
- (NSArray<FFEntry *> *)loadDirectoryContents;
- (void)setupCollectionView;
- (void)applyLayoutModeAnimated:(BOOL)animated;
- (void)refreshVisibleContent;
- (void)updateBreadcrumbVisibility;
- (void)extractEntry:(FFEntry *)item;
@end

static BOOL FFStoragePathIsInsideRoot(NSString *path, NSString *root)
{
    NSString *candidate = path.stringByStandardizingPath;
    NSString *base = root.stringByStandardizingPath;
    if (!candidate.length || !base.length) return NO;
    return [candidate isEqualToString:base] ||
        [candidate hasPrefix:[base stringByAppendingString:@"/"]];
}

static void FFCleanupLegacyGeneratedCachesAtStorageRoot(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *root = FFStorageRootPath();
        NSString *legacyRoot = [root stringByAppendingPathComponent:@"Device Storage"];
        for (NSString *name in @[@"LSIdentifierCache.plist", @"LSGroupCache.plist"]) {
            [fm removeItemAtPath:[root stringByAppendingPathComponent:name] error:nil];
            [fm removeItemAtPath:[legacyRoot stringByAppendingPathComponent:name] error:nil];
        }
        if ([fm contentsOfDirectoryAtPath:legacyRoot error:nil].count == 0)
            [fm removeItemAtPath:legacyRoot error:nil];
    });
}

@implementation FFBrowserViewController (StorageRoot)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = FFBrowserViewController.class;
        Method initOriginal = class_getInstanceMethod(cls, @selector(initWithPath:));
        Method initReplacement = class_getInstanceMethod(cls, @selector(ff_storage_initWithPath:));
        Method appearOriginal = class_getInstanceMethod(cls, @selector(viewWillAppear:));
        Method appearReplacement = class_getInstanceMethod(cls, @selector(ff_storage_viewWillAppear:));
        Method loadOriginal = class_getInstanceMethod(cls, @selector(loadDirectoryContents));
        Method loadReplacement = class_getInstanceMethod(cls, @selector(ff_storage_loadDirectoryContents));
        Method breadcrumbOriginal = class_getInstanceMethod(cls, @selector(updateBreadcrumbVisibility));
        Method breadcrumbReplacement = class_getInstanceMethod(cls, @selector(ff_storage_updateBreadcrumbVisibility));
        Method extractOriginal = class_getInstanceMethod(cls, @selector(extractEntry:));
        Method extractReplacement = class_getInstanceMethod(cls, @selector(ff_storage_extractEntry:));
        if (initOriginal && initReplacement) method_exchangeImplementations(initOriginal, initReplacement);
        if (appearOriginal && appearReplacement) method_exchangeImplementations(appearOriginal, appearReplacement);
        if (loadOriginal && loadReplacement) method_exchangeImplementations(loadOriginal, loadReplacement);
        if (breadcrumbOriginal && breadcrumbReplacement) method_exchangeImplementations(breadcrumbOriginal, breadcrumbReplacement);
        if (extractOriginal && extractReplacement) method_exchangeImplementations(extractOriginal, extractReplacement);
    });
}

- (instancetype)ff_storage_initWithPath:(NSString *)path
{
    // Old favorites / task history / deep links can still contain the removed
    // Documents/Device Storage prefix. Canonicalize at the browser boundary so
    // every caller lands on the flattened Documents tree.
    NSString *root = FFStorageRootPath().stringByStandardizingPath;
    FFCleanupLegacyGeneratedCachesAtStorageRoot();
    NSString *canonical = FFCanonicalStoragePath(path ?: @"");
    FFBrowserViewController *browser = [self ff_storage_initWithPath:canonical];
    if (browser && [canonical.stringByStandardizingPath isEqualToString:root])
        browser.title = @"Documents";
    return browser;
}

- (void)ff_storage_viewWillAppear:(BOOL)animated
{
    [self ff_storage_viewWillAppear:animated];

    NSString *root = FFStorageRootPath().stringByStandardizingPath;
    BOOL isRoot = [self.currentPath.stringByStandardizingPath isEqualToString:root];
    if (!isRoot) return;
    self.title = @"Documents";

    // The Files-tab root controller is created once and survives switching to
    // Settings, so it must re-read the default display preference when it comes
    // back. Restrict this synchronization to the root only: subfolders keep
    // their explicit “更多 → 显示方式” choice, preserving the existing local
    // list/grid semantics.
    BOOL preferredGrid = [NSUserDefaults.standardUserDefaults
        boolForKey:@"FFSettingsGridMode"];
    if (self.gridMode != preferredGrid) {
        self.gridMode = preferredGrid;
        if (preferredGrid && !self.collectionView) [self setupCollectionView];
        [self applyLayoutModeAnimated:NO];
        [self refreshVisibleContent];
    }
}

- (NSArray<FFEntry *> *)ff_storage_loadDirectoryContents
{
    NSArray<FFEntry *> *loaded = [self ff_storage_loadDirectoryContents];
    if (loaded.count == 0) return loaded ?: @[];

    NSString *parent = self.currentPath.stringByStandardizingPath;
    if (![parent isEqualToString:FFStorageRootPath().stringByStandardizingPath])
        return loaded;

    // Documents is now the actual homepage. Generated metadata from older or
    // current builds must never masquerade as user files even when “show hidden”
    // is enabled. AppData/MobileGestalt are deliberately NOT filtered here.
    NSMutableArray<FFEntry *> *visible = [NSMutableArray arrayWithCapacity:loaded.count];
    for (FFEntry *entry in loaded) {
        if (FFIsInternalStorageEntry(parent, entry.name)) continue;
        [visible addObject:entry];
    }
    return visible;
}

- (void)ff_storage_updateBreadcrumbVisibility
{
    NSString *root = FFStorageRootPath().stringByStandardizingPath;
    NSString *current = FFCanonicalStoragePath(self.currentPath ?: @"").stringByStandardizingPath;
    BOOL atRoot = [current isEqualToString:root];
    self.breadcrumbHeightConstraint.constant = atRoot ? 0 : 32;
    self.breadcrumbView.hidden = atRoot;
    if (atRoot) {
        self.breadcrumbPaths = @[];
        return;
    }

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];

    if (FFStoragePathIsInsideRoot(current, root)) {
        [names addObject:@"Documents"];
        [paths addObject:root];
        NSString *relative = [current substringFromIndex:root.length];
        NSString *cursor = root;
        for (NSString *component in relative.pathComponents) {
            if (!component.length || [component isEqualToString:@"/"]) continue;
            cursor = [[cursor stringByAppendingPathComponent:component] stringByStandardizingPath];
            [names addObject:component];
            [paths addObject:cursor];
        }
        // Navigation title already names the current folder; breadcrumbs are
        // ancestors only. A first-level child therefore shows “Documents >”.
        if (names.count > 1) {
            [names removeLastObject];
            [paths removeLastObject];
        }
    } else {
        // Defensive fallback for a direct external/system path opened from a
        // search/history result: expose at most the final two ancestors and
        // never render the entire /private/var/... chain.
        NSString *parent = current.stringByDeletingLastPathComponent;
        NSMutableArray<NSString *> *reverseNames = [NSMutableArray array];
        NSMutableArray<NSString *> *reversePaths = [NSMutableArray array];
        while (parent.length && ![parent isEqualToString:@"/"] && reverseNames.count < 2) {
            NSString *name = parent.lastPathComponent;
            if (name.length) {
                [reverseNames addObject:name];
                [reversePaths addObject:parent];
            }
            NSString *next = parent.stringByDeletingLastPathComponent;
            if ([next isEqualToString:parent]) break;
            parent = next;
        }
        for (NSInteger index = (NSInteger)reverseNames.count - 1; index >= 0; index--) {
            [names addObject:reverseNames[(NSUInteger)index]];
            [paths addObject:reversePaths[(NSUInteger)index]];
        }
    }

    if (names.count == 0) {
        self.breadcrumbHeightConstraint.constant = 0;
        self.breadcrumbView.hidden = YES;
        self.breadcrumbPaths = @[];
        return;
    }

    self.breadcrumbPaths = paths;
    [self.breadcrumbView setComponentNames:names selectedIndex:names.count - 1
        target:self action:@selector(breadcrumbTapped:)];
}

- (void)ff_storage_extractEntry:(FFEntry *)item
{
    NSString *stem = item.name.stringByDeletingPathExtension;
    if (stem.length == 0) stem = @"archive";
    NSString *sibling = [self.currentPath stringByAppendingPathComponent:
        [stem stringByAppendingString:@" (解压)"]];

    FFFileTask *task = [FFFileTask new];
    task.kind = FFFileTaskKindExtract;
    task.displayName = [NSString stringWithFormat:@"解压 %@", item.name];
    task.sources = @[item.path];
    task.destination = sibling;
    [[FFFileTaskManager sharedManager] enqueueTask:task];
    FFLogTag(@"Browser", @"extract task queued archive=%@ destination=%@",
        item.path, sibling);
}

@end
