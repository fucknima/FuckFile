#import "FFBrowserViewController.h"

#import <objc/runtime.h>

// Browser search is intentionally local to the entries already visible in the
// current folder.  The home/global search remains FFSearchService-based.
//
// Some visible rows do not display FFEntry.name directly (AppData/container
// rows use displayName), so searching only name/path makes a row visible on
// screen but impossible to find by its displayed name.  Also, matching the
// full path makes a parent-folder keyword match every child.
@interface FFBrowserViewController (LocalSearchFix)
- (void)ff_applyLocalSearchFilter;
@end

@implementation FFBrowserViewController (LocalSearchFix)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method original = class_getInstanceMethod(self, NSSelectorFromString(@"applyFilter"));
        Method replacement = class_getInstanceMethod(self, @selector(ff_applyLocalSearchFilter));
        if (original && replacement)
            method_exchangeImplementations(original, replacement);
    });
}

- (void)ff_applyLocalSearchFilter
{
    NSString *query = [self valueForKey:@"searchText"];
    if (![query isKindOfClass:NSString.class] || query.length == 0) {
        // After swizzling this selector points to FFBrowserViewController's
        // original applyFilter implementation.
        [self ff_applyLocalSearchFilter];
        return;
    }

    // Let the original implementation apply the current type filter first,
    // but prevent its old name/path search predicate from discarding rows.
    [self setValue:@"" forKey:@"searchText"];
    [self ff_applyLocalSearchFilter];
    NSArray<FFEntry *> *source = [self valueForKey:@"filteredEntries"] ?: @[];
    [self setValue:query forKey:@"searchText"];

    NSStringCompareOptions options =
        NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch;
    NSMutableArray<FFEntry *> *matches = [NSMutableArray array];

    for (FFEntry *item in source) {
        NSArray<NSString *> *fields = @[
            item.displayName ?: @"",
            item.name ?: @"",
            item.containerIdentifier ?: @"",
        ];
        for (NSString *field in fields) {
            if ([field rangeOfString:query options:options].location != NSNotFound) {
                [matches addObject:item];
                break;
            }
        }
    }

    [self setValue:matches.copy forKey:@"filteredEntries"];
}

@end
