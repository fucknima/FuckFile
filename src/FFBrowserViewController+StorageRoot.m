#import "FFBrowserViewController.h"
#import "FFStorageEnvironment.h"

#import <objc/runtime.h>

@interface FFBrowserViewController (FFStorageRootPrivate)
@property(nonatomic, copy) NSString *currentPath;
@property(nonatomic, strong) NSArray<FFEntry *> *entries;
@property(nonatomic, strong) NSArray<FFEntry *> *filteredEntries;
@property(nonatomic, strong) UICollectionView *collectionView;
@property(nonatomic) BOOL gridMode;

- (instancetype)initWithPath:(NSString *)path;
- (void)viewWillAppear:(BOOL)animated;
- (NSArray<FFEntry *> *)loadDirectoryContents;
- (void)setupCollectionView;
- (void)applyLayoutModeAnimated:(BOOL)animated;
- (void)refreshVisibleContent;
@end

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
        if (initOriginal && initReplacement) method_exchangeImplementations(initOriginal, initReplacement);
        if (appearOriginal && appearReplacement) method_exchangeImplementations(appearOriginal, appearReplacement);
        if (loadOriginal && loadReplacement) method_exchangeImplementations(loadOriginal, loadReplacement);
    });
}

- (instancetype)ff_storage_initWithPath:(NSString *)path
{
    // Old favorites / task history / deep links can still contain the removed
    // Documents/Device Storage prefix. Canonicalize at the browser boundary so
    // every caller lands on the flattened Documents tree.
    NSString *canonical = FFCanonicalStoragePath(path ?: @"");
    FFBrowserViewController *browser = [self ff_storage_initWithPath:canonical];
    if (browser && [canonical.stringByStandardizingPath
        isEqualToString:FFStorageRootPath().stringByStandardizingPath]) {
        browser.title = @"Documents";
    }
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

@end
