#import "FFBrowserViewController.h"
#import "FFSearchService.h"

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
