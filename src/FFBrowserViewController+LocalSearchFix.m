#import "FFBrowserViewController.h"
#import "FFSearchService.h"
#import "FFStorageEnvironment.h"

#import <objc/runtime.h>

// Browser search semantics:
//   1) current-folder entries are matched immediately from the browser's
//      already-decorated FFEntry objects (name/displayName/containerIdentifier),
//      so visible folders can never disappear from search;
//   2) FFSearchService then recursively searches descendants under currentPath,
//      so files inside Imported (and other subfolders) are found as well;
//   3) paths are de-duplicated because the recursive service also sees the
//      current folder's immediate children.
//
// The home/global search controller is untouched.
static const void *kFFBrowserRecursiveSearchServiceKey = &kFFBrowserRecursiveSearchServiceKey;
static const void *kFFBrowserRecursiveSearchGenerationKey = &kFFBrowserRecursiveSearchGenerationKey;
static const void *kFFBrowserRecursiveSearchSeenPathsKey = &kFFBrowserRecursiveSearchSeenPathsKey;

@interface FFBrowserViewController (RecursiveSearchHostPrivate)
- (void)refreshVisibleContent;
@end

@interface FFBrowserViewController (LocalSearchFix)
- (void)ff_recursive_updateSearchResultsForSearchController:(UISearchController *)searchController;
@end

@implementation FFBrowserViewController (LocalSearchFix)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method original = class_getInstanceMethod(self,
            @selector(updateSearchResultsForSearchController:));
        Method replacement = class_getInstanceMethod(self,
            @selector(ff_recursive_updateSearchResultsForSearchController:));
        if (original && replacement)
            method_exchangeImplementations(original, replacement);
    });
}

static BOOL FFLocalSearchMatches(NSString *field, NSString *query)
{
    if (!field.length || !query.length) return NO;
    NSStringCompareOptions options = NSCaseInsensitiveSearch |
        NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch;
    return [field rangeOfString:query options:options].location != NSNotFound;
}

- (FFSearchService *)ff_recursiveSearchService
{
    FFSearchService *service = objc_getAssociatedObject(self,
        kFFBrowserRecursiveSearchServiceKey);
    if (!service) {
        service = [FFSearchService new];
        objc_setAssociatedObject(self, kFFBrowserRecursiveSearchServiceKey,
            service, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return service;
}

- (NSUInteger)ff_nextRecursiveSearchGeneration
{
    NSNumber *old = objc_getAssociatedObject(self,
        kFFBrowserRecursiveSearchGenerationKey);
    NSUInteger next = old.unsignedIntegerValue + 1;
    objc_setAssociatedObject(self, kFFBrowserRecursiveSearchGenerationKey,
        @(next), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return next;
}

- (NSArray<FFEntry *> *)ff_immediateMatchesForQuery:(NSString *)query
                                              seen:(NSMutableSet<NSString *> *)seen
{
    NSArray<FFEntry *> *entries = [self valueForKey:@"entries"] ?: @[];
    NSMutableArray<FFEntry *> *matches = [NSMutableArray array];
    for (FFEntry *entry in entries) {
        BOOL matched = FFLocalSearchMatches(entry.displayName, query) ||
            FFLocalSearchMatches(entry.name, query) ||
            FFLocalSearchMatches(entry.containerIdentifier, query);
        if (!matched) continue;
        NSString *key = entry.path.stringByStandardizingPath ?: entry.path;
        if (key.length && [seen containsObject:key]) continue;
        if (key.length) [seen addObject:key];
        [matches addObject:entry];
    }
    return matches;
}

- (void)ff_recursive_updateSearchResultsForSearchController:(UISearchController *)searchController
{
    NSString *query = [searchController.searchBar.text
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];

    if (query.length == 0) {
        [[self ff_recursiveSearchService] cancel];
        [self ff_nextRecursiveSearchGeneration];
        objc_setAssociatedObject(self, kFFBrowserRecursiveSearchSeenPathsKey,
            nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // After swizzling this selector points to the browser's original local
        // updater, which restores the normal current-folder list/filter state.
        [self ff_recursive_updateSearchResultsForSearchController:searchController];
        return;
    }

    NSUInteger generation = [self ff_nextRecursiveSearchGeneration];
    FFSearchService *service = [self ff_recursiveSearchService];
    [service cancel];

    [self setValue:query forKey:@"searchText"];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    objc_setAssociatedObject(self, kFFBrowserRecursiveSearchSeenPathsKey,
        seen, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Seed results from the exact FFEntry objects already shown in this folder.
    // This guarantees Device Storage children such as Imported are searchable,
    // including their decorated app/container display names.
    NSArray<FFEntry *> *immediate = [self ff_immediateMatchesForQuery:query seen:seen];
    [self setValue:immediate forKey:@"filteredEntries"];
    [self refreshVisibleContent];

    NSString *root = self.currentPath;
    __weak typeof(self) weakSelf = self;
    [service startSearch:query underRoot:root batch:^(NSArray<FFFoundItem *> *batch) {
        typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSNumber *current = objc_getAssociatedObject(strongSelf,
            kFFBrowserRecursiveSearchGenerationKey);
        if (current.unsignedIntegerValue != generation) return;

        NSMutableSet<NSString *> *currentSeen = objc_getAssociatedObject(strongSelf,
            kFFBrowserRecursiveSearchSeenPathsKey);
        if (!currentSeen) return;
        NSMutableArray<FFEntry *> *rows =
            [[strongSelf valueForKey:@"filteredEntries"] mutableCopy] ?: [NSMutableArray array];

        for (FFFoundItem *found in batch) {
            NSString *key = found.path.stringByStandardizingPath ?: found.path;
            if (key.length && [currentSeen containsObject:key]) continue;
            if (key.length) [currentSeen addObject:key];

            FFEntry *entry = [FFEntry new];
            entry.name = found.name;
            entry.displayName = found.displayName.length ? found.displayName : found.name;
            entry.path = found.path;
            entry.isDirectory = found.isDirectory;
            entry.size = found.size;

            NSString *relative = [found.path hasPrefix:root]
                ? [found.path substringFromIndex:MIN(root.length + 1, found.path.length)]
                : found.path;
            NSString *parent = relative.stringByDeletingLastPathComponent;
            entry.detail = parent.length ? parent : @"当前文件夹";
            [rows addObject:entry];
        }

        [strongSelf setValue:rows forKey:@"filteredEntries"];
        [strongSelf refreshVisibleContent];
    } completion:^(__unused BOOL finished) {
        typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSNumber *current = objc_getAssociatedObject(strongSelf,
            kFFBrowserRecursiveSearchGenerationKey);
        if (current.unsignedIntegerValue == generation)
            [strongSelf refreshVisibleContent];
    }];
}

@end

#pragma mark - Browser UI consistency

// Keep the browser's runtime display mode, Settings -> 默认视图, the More-menu
// checkmark, and the bottom tab/selection toolbar as one coherent state.
// This intentionally lives in an already-built browser patch unit so no new
// source entry is required in the Theos Makefile.
@interface FFBrowserViewController (UIConsistencyHostPrivate)
@property(nonatomic) BOOL gridMode;
@property(nonatomic, strong) UIBarButtonItem *moreItem;
- (UIMenu *)moreMenu;
- (UIMenu *)displayModeMenu;
- (void)applyLayoutModeAnimated:(BOOL)animated;
@end

@interface FFBrowserViewController (UIConsistency)
- (void)ff_ui_viewDidAppear:(BOOL)animated;
- (void)ff_ui_viewDidDisappear:(BOOL)animated;
- (void)ff_ui_setEditing:(BOOL)editing animated:(BOOL)animated;
- (UIMenu *)ff_ui_moreMenu;
- (UIMenu *)ff_ui_displayModeMenu;
@end

static void FFSwapBrowserUIConsistencyMethod(Class cls, SEL originalSelector,
                                              SEL replacementSelector)
{
    Method original = class_getInstanceMethod(cls, originalSelector);
    Method replacement = class_getInstanceMethod(cls, replacementSelector);
    if (original && replacement)
        method_exchangeImplementations(original, replacement);
}

@implementation FFBrowserViewController (UIConsistency)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = FFBrowserViewController.class;
        FFSwapBrowserUIConsistencyMethod(cls, @selector(viewDidAppear:),
            @selector(ff_ui_viewDidAppear:));
        FFSwapBrowserUIConsistencyMethod(cls, @selector(viewDidDisappear:),
            @selector(ff_ui_viewDidDisappear:));
        FFSwapBrowserUIConsistencyMethod(cls, @selector(setEditing:animated:),
            @selector(ff_ui_setEditing:animated:));
        FFSwapBrowserUIConsistencyMethod(cls, @selector(moreMenu),
            @selector(ff_ui_moreMenu));
        FFSwapBrowserUIConsistencyMethod(cls, @selector(displayModeMenu),
            @selector(ff_ui_displayModeMenu));
    });
}

- (void)ff_ui_setTabBarHidden:(BOOL)hidden
{
    UITabBarController *tabs = self.tabBarController;
    UITabBar *tabBar = tabs.tabBar;
    if (!tabBar || tabBar.hidden == hidden) return;

    // The navigation-controller toolbar used for batch actions occupies the
    // same bottom region as UITabBar. Never let both exist at once: hide the
    // tab bar before showing the batch toolbar, and restore it after the batch
    // toolbar has gone away.
    tabBar.hidden = hidden;
    [tabs.view setNeedsLayout];
    [self.navigationController.view setNeedsLayout];
    [UIView performWithoutAnimation:^{
        [tabs.view layoutIfNeeded];
        [self.navigationController.view layoutIfNeeded];
    }];
}

- (void)ff_ui_viewDidAppear:(BOOL)animated
{
    [self ff_ui_viewDidAppear:animated];

    // Settings and the in-folder menu now describe the same preference. Any
    // browser that becomes active re-reads it, not only the storage root.
    BOOL preferredGrid = [NSUserDefaults.standardUserDefaults
        boolForKey:@"FFSettingsGridMode"];
    if (self.gridMode != preferredGrid) {
        self.gridMode = preferredGrid;
        [self applyLayoutModeAnimated:NO];
    }

    // StorageRoot historically forced an English "Documents" title. Keep both
    // the navigation title and the persistent tab item in Chinese.
    NSString *root = FFStorageRootPath().stringByStandardizingPath;
    if ([self.currentPath.stringByStandardizingPath isEqualToString:root]) {
        self.title = @"文件";
        self.navigationItem.title = @"文件";
        self.navigationController.tabBarItem.title = @"文件";
    }

    [self ff_ui_setTabBarHidden:self.editing];
    if (self.moreItem) self.moreItem.menu = [self moreMenu];
}

- (void)ff_ui_viewDidDisappear:(BOOL)animated
{
    [self ff_ui_viewDidDisappear:animated];
    // Defensive restore for non-standard/programmatic navigation away from an
    // editing browser. If this controller becomes visible again, viewDidAppear
    // reapplies the editing state.
    if (self.editing) [self ff_ui_setTabBarHidden:NO];
}

- (void)ff_ui_setEditing:(BOOL)editing animated:(BOOL)animated
{
    if (editing) [self ff_ui_setTabBarHidden:YES];
    [self ff_ui_setEditing:editing animated:animated];
    if (!editing) [self ff_ui_setTabBarHidden:NO];

    [self.view setNeedsLayout];
    [self.navigationController.view setNeedsLayout];
}

- (UIMenu *)ff_ui_moreMenu
{
    UIMenu *original = [self ff_ui_moreMenu];
    if (!original) return nil;

    NSMutableArray<UIMenuElement *> *children = [original.children mutableCopy];
    for (NSUInteger index = 0; index < children.count; index++) {
        UIMenuElement *element = children[index];
        if (![element isKindOfClass:UIMenu.class]) continue;
        UIMenu *menu = (UIMenu *)element;
        if (![menu.title isEqualToString:@"视图"]) continue;

        // The screenshot-visible "视图 >" row previously had no leading
        // symbol. Use the current display mode as the visual cue.
        UIImage *image = [UIImage systemImageNamed:self.gridMode
            ? @"square.grid.2x2" : @"list.bullet"];
        children[index] = [UIMenu menuWithTitle:menu.title
            image:image identifier:menu.identifier options:menu.options
            children:menu.children];
        break;
    }

    return [UIMenu menuWithTitle:original.title image:original.image
        identifier:original.identifier options:original.options children:children];
}

- (UIMenu *)ff_ui_displayModeMenu
{
    __weak typeof(self) weakSelf = self;

    void (^setMode)(BOOL) = ^(BOOL grid) {
        typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // Menu choice is no longer a one-page override: it is the same setting
        // shown under Settings -> 默认视图, so both directions stay synchronized.
        [NSUserDefaults.standardUserDefaults setBool:grid
            forKey:@"FFSettingsGridMode"];
        strongSelf.gridMode = grid;
        [strongSelf applyLayoutModeAnimated:YES];
        if (strongSelf.moreItem) strongSelf.moreItem.menu = [strongSelf moreMenu];
    };

    UIAction *list = [UIAction actionWithTitle:@"列表"
        image:[UIImage systemImageNamed:@"list.bullet"] identifier:nil
        handler:^(__unused UIAction *action) { setMode(NO); }];
    UIAction *grid = [UIAction actionWithTitle:@"网格"
        image:[UIImage systemImageNamed:@"square.grid.2x2"] identifier:nil
        handler:^(__unused UIAction *action) { setMode(YES); }];

    list.state = self.gridMode ? UIMenuElementStateOff : UIMenuElementStateOn;
    grid.state = self.gridMode ? UIMenuElementStateOn : UIMenuElementStateOff;

    UIImage *currentImage = [UIImage systemImageNamed:self.gridMode
        ? @"square.grid.2x2" : @"list.bullet"];
    return [UIMenu menuWithTitle:@"显示方式" image:currentImage identifier:nil
        options:0 children:@[list, grid]];
}

@end
