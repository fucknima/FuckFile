#import "FFBrowserViewController.h"

#import <objc/runtime.h>

// Fixes only the browser's current-directory search. The home/global search
// remains untouched.
@interface FFBrowserViewController (LocalSearchFix)
- (void)ff_applyLocalSearchFix;
@end

@implementation FFBrowserViewController (LocalSearchFix)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method original = class_getInstanceMethod(self, NSSelectorFromString(@"applyFilter"));
        Method replacement = class_getInstanceMethod(self, @selector(ff_applyLocalSearchFix));
        if (original && replacement)
            method_exchangeImplementations(original, replacement);
    });
}

- (void)ff_applyLocalSearchFix
{
    NSString *query = [self valueForKey:@"searchText"];
    if (![query isKindOfClass:NSString.class] || query.length == 0) {
        // After swizzling this selector points to the original applyFilter.
        [self ff_applyLocalSearchFix];
        return;
    }

    // Run the original type/category filter first, but prevent its old
    // name/path search predicate from discarding display-name matches.
    [self setValue:@"" forKey:@"searchText"];
    [self ff_applyLocalSearchFix];
    NSArray<FFEntry *> *source = [self valueForKey:@"filteredEntries"] ?: @[];
    [self setValue:query forKey:@"searchText"];

    NSStringCompareOptions options =
        NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
    NSMutableArray<FFEntry *> *matches = [NSMutableArray array];

    for (FFEntry *item in source) {
        // Search what the user can identify on screen. Do not search the full
        // absolute path: every child shares the parent path and that creates
        // false positives in a "current folder" search.
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
