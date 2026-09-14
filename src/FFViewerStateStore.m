#import "FFViewerStateStore.h"

static NSString * const FFViewerStateStoreKey = @"FFViewerReadingStatesV1";
static const NSUInteger FFViewerStateStoreLimit = 40;

@implementation FFViewerStateStore

+ (NSString *)signatureForFilePath:(NSString *)path
{
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attributes[NSFileSize] unsignedLongLongValue];
    NSTimeInterval modified = [attributes[NSFileModificationDate] timeIntervalSince1970];
    return [NSString stringWithFormat:@"%@|%llu|%.0f", path, size, modified];
}

+ (NSMutableDictionary *)storedEntries
{
    id stored = [NSUserDefaults.standardUserDefaults dictionaryForKey:FFViewerStateStoreKey];
    return [stored isKindOfClass:NSDictionary.class]
        ? [stored mutableCopy] : [NSMutableDictionary dictionary];
}

+ (double)savedAtForEntry:(id)entry
{
    if (![entry isKindOfClass:NSDictionary.class]) return 0;
    id value = entry[@"savedAt"];
    return [value isKindOfClass:NSNumber.class] ? [value doubleValue] : 0;
}

+ (NSDictionary *)stateForFilePath:(NSString *)path
{
    if (!path.length) return nil;
    NSMutableDictionary *entries = [self storedEntries];
    id entry = entries[[self signatureForFilePath:path]];
    if (![entry isKindOfClass:NSDictionary.class]) return nil;
    id state = entry[@"state"];
    return [state isKindOfClass:NSDictionary.class] ? state : nil;
}

+ (void)setState:(NSDictionary *)state forFilePath:(NSString *)path
{
    if (!path.length) return;
    NSMutableDictionary *entries = [self storedEntries];
    NSString *signature = [self signatureForFilePath:path];
    if (!state.count) {
        [entries removeObjectForKey:signature];
    } else {
        entries[signature] = @{ @"state": state, @"savedAt": @(NSDate.date.timeIntervalSince1970) };
    }

    if (entries.count > FFViewerStateStoreLimit) {
        NSArray<NSString *> *keys = [entries.allKeys sortedArrayUsingComparator:
            ^NSComparisonResult(NSString *left, NSString *right) {
                double a = [self savedAtForEntry:entries[left]];
                double b = [self savedAtForEntry:entries[right]];
                if (a < b) return NSOrderedAscending;
                if (a > b) return NSOrderedDescending;
                return NSOrderedSame;
            }];
        for (NSUInteger index = 0; index + FFViewerStateStoreLimit < keys.count; index++)
            [entries removeObjectForKey:keys[index]];
    }

    [NSUserDefaults.standardUserDefaults setObject:entries forKey:FFViewerStateStoreKey];
}

@end
