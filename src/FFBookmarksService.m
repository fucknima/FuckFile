#import "FFBookmarksService.h"

static NSString *const kFFRecentKey = @"FFRecentPaths";
static const NSUInteger kFFRecentLimit = 50;

@implementation FFBookmark
@end

#pragma mark - Favorites

@implementation FFFavoritesService

+ (instancetype)sharedService
{
    static FFFavoritesService *service;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ service = [FFFavoritesService new]; });
    return service;
}

static NSString *FFFavoritesPath(void)
{
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [[documents stringByAppendingPathComponent:@"Device Storage"]
        stringByAppendingPathComponent:@"Favorites.plist"];
}

- (NSArray<FFBookmark *> *)bookmarks
{
    NSArray *entries = [NSArray arrayWithContentsOfFile:FFFavoritesPath()];
    if (![entries isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<FFBookmark *> *result = [NSMutableArray arrayWithCapacity:entries.count];
    for (NSDictionary *dict in entries) {
        if (![dict isKindOfClass:NSDictionary.class]) continue;
        if (![dict[@"Path"] isKindOfClass:NSString.class]) continue;
        FFBookmark *bookmark = [FFBookmark new];
        bookmark.name = [dict[@"Name"] isKindOfClass:NSString.class] ? dict[@"Name"] : @"";
        bookmark.path = dict[@"Path"];
        bookmark.isDirectory = [dict[@"IsDirectory"] boolValue];
        bookmark.addedDate = [dict[@"Added"] isKindOfClass:NSDate.class] ? dict[@"Added"] : NSDate.date;
        [result addObject:bookmark];
    }
    return result;
}

- (void)saveBookmarks:(NSArray<FFBookmark *> *)bookmarks
{
    NSMutableArray *entries = [NSMutableArray arrayWithCapacity:bookmarks.count];
    for (FFBookmark *bookmark in bookmarks)
        [entries addObject:@{
            @"Name": bookmark.name ?: @"",
            @"Path": bookmark.path ?: @"",
            @"IsDirectory": @(bookmark.isDirectory),
            @"Added": bookmark.addedDate ?: NSDate.date,
        }];
    [entries writeToFile:FFFavoritesPath() atomically:YES];
}

- (BOOL)isFavoritePath:(NSString *)path
{
    for (FFBookmark *bookmark in [self bookmarks])
        if ([bookmark.path isEqualToString:path]) return YES;
    return NO;
}

- (void)togglePath:(NSString *)path name:(NSString *)name isDirectory:(BOOL)isDirectory
{
    NSMutableArray<FFBookmark *> *bookmarks = [[self bookmarks] mutableCopy];
    for (FFBookmark *bookmark in bookmarks)
        if ([bookmark.path isEqualToString:path]) {
            [bookmarks removeObject:bookmark];
            [self saveBookmarks:bookmarks];
            return;
        }
    FFBookmark *bookmark = [FFBookmark new];
    bookmark.name = name;
    bookmark.path = path;
    bookmark.isDirectory = isDirectory;
    bookmark.addedDate = NSDate.date;
    [bookmarks insertObject:bookmark atIndex:0];
    [self saveBookmarks:bookmarks];
}

- (void)removePath:(NSString *)path
{
    NSMutableArray<FFBookmark *> *bookmarks = [[self bookmarks] mutableCopy];
    for (FFBookmark *bookmark in bookmarks)
        if ([bookmark.path isEqualToString:path]) {
            [bookmarks removeObject:bookmark];
            [self saveBookmarks:bookmarks];
            return;
        }
}

@end

#pragma mark - Recent

@implementation FFRecentService

+ (instancetype)sharedService
{
    static FFRecentService *service;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ service = [FFRecentService new]; });
    return service;
}

- (NSArray<FFBookmark *> *)entries
{
    NSArray *entries = [NSUserDefaults.standardUserDefaults arrayForKey:kFFRecentKey];
    if (![entries isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<FFBookmark *> *result = [NSMutableArray arrayWithCapacity:entries.count];
    for (NSDictionary *dict in entries) {
        if (![dict isKindOfClass:NSDictionary.class]) continue;
        if (![dict[@"Path"] isKindOfClass:NSString.class]) continue;
        FFBookmark *bookmark = [FFBookmark new];
        bookmark.name = [dict[@"Name"] isKindOfClass:NSString.class] ? dict[@"Name"] : @"";
        bookmark.path = dict[@"Path"];
        bookmark.isDirectory = [dict[@"IsDirectory"] boolValue];
        bookmark.addedDate = [dict[@"LastOpened"] isKindOfClass:NSDate.class]
            ? dict[@"LastOpened"] : NSDate.date;
        [result addObject:bookmark];
    }
    return result;
}

- (void)recordPath:(NSString *)path name:(NSString *)name isDirectory:(BOOL)isDirectory
{
    NSMutableArray *entries = [[NSUserDefaults.standardUserDefaults
        arrayForKey:kFFRecentKey] mutableCopy];
    if (!entries) entries = [NSMutableArray array];
    for (NSDictionary *dict in entries)
        if ([dict[@"Path"] isEqualToString:path]) {
            [entries removeObject:dict];
            break;
        }
    [entries insertObject:@{
        @"Name": name ?: @"",
        @"Path": path ?: @"",
        @"IsDirectory": @(isDirectory),
        @"LastOpened": NSDate.date,
    } atIndex:0];
    while (entries.count > kFFRecentLimit) [entries removeLastObject];
    [NSUserDefaults.standardUserDefaults setObject:entries forKey:kFFRecentKey];
}

- (void)removePath:(NSString *)path
{
    NSMutableArray *entries = [[NSUserDefaults.standardUserDefaults
        arrayForKey:kFFRecentKey] mutableCopy];
    for (NSDictionary *dict in entries)
        if ([dict[@"Path"] isEqualToString:path]) {
            [entries removeObject:dict];
            break;
        }
    [NSUserDefaults.standardUserDefaults setObject:entries forKey:kFFRecentKey];
}

- (void)clear
{
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kFFRecentKey];
}

@end
