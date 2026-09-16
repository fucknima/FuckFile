#import "FFBatchRename.h"

@implementation FFBatchRename

+ (void)splitName:(NSString *)name stem:(NSString **)stemOut extension:(NSString **)extensionOut
{
    NSString *stem = name;
    NSString *extension = @"";
    NSRange dot = [name rangeOfString:@"." options:NSBackwardsSearch];
    // Leading-dot names like ".Trash" have no extension part.
    if (dot.location != NSNotFound && dot.location > 0) {
        stem = [name substringToIndex:dot.location];
        extension = [name substringFromIndex:dot.location];
    }
    *stemOut = stem;
    *extensionOut = extension;
}

+ (BOOL)isValidNameComponent:(NSString *)name
{
    if (!name.length) return NO;
    if ([name containsString:@"/"] || [name containsString:@"\0"]) return NO;
    if ([name isEqualToString:@"."] || [name isEqualToString:@".."]) return NO;
    return [name lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= 255;
}

+ (nullable NSArray<NSString *> *)newNamesForNames:(NSArray<NSString *> *)names
    mode:(FFBatchRenameMode)mode
    find:(nullable NSString *)find
    replace:(nullable NSString *)replace
    caseSensitive:(BOOL)caseSensitive
    prefix:(nullable NSString *)prefix
    suffix:(nullable NSString *)suffix
    sequencePrefix:(nullable NSString *)sequencePrefix
    start:(NSInteger)start
    digits:(NSInteger)digits
    error:(NSString * _Nullable * _Nullable)errorMessage
{
    if (!names.count) {
        if (errorMessage) *errorMessage = @"没有可重命名的项目。";
        return nil;
    }
    if (mode == FFBatchRenameModeReplace && !find.length) {
        if (errorMessage) *errorMessage = @"请填写要查找的文字。";
        return nil;
    }
    if (mode == FFBatchRenameModeAffix && !prefix.length && !suffix.length) {
        if (errorMessage) *errorMessage = @"请至少填写前缀或后缀。";
        return nil;
    }

    NSInteger width = MAX(1, MIN(9, digits));
    NSMutableArray<NSString *> *result = [NSMutableArray arrayWithCapacity:names.count];
    for (NSUInteger index = 0; index < names.count; index++) {
        NSString *name = names[index];
        NSString *stem = name;
        NSString *extension = @"";
        [self splitName:name stem:&stem extension:&extension];

        NSString *newStem = stem;
        switch (mode) {
            case FFBatchRenameModeReplace: {
                NSStringCompareOptions options = caseSensitive ? 0 : NSCaseInsensitiveSearch;
                newStem = [stem stringByReplacingOccurrencesOfString:find
                    withString:(replace ?: @"") options:options range:NSMakeRange(0, stem.length)];
                break;
            }
            case FFBatchRenameModeAffix:
                newStem = [(prefix ?: @"") stringByAppendingFormat:@"%@%@",
                    stem, (suffix ?: @"")];
                break;
            case FFBatchRenameModeSequence: {
                NSInteger number = start + (NSInteger)index;
                NSString *padded = [NSString stringWithFormat:@"%0*ld", (int)width, (long)number];
                newStem = [(sequencePrefix ?: @"") stringByAppendingString:padded];
                break;
            }
        }

        NSString *candidate = [newStem stringByAppendingString:extension];
        if (![self isValidNameComponent:candidate]) {
            if (errorMessage) *errorMessage = [NSString stringWithFormat:
                @"“%@”不是有效的文件名。", candidate];
            return nil;
        }
        [result addObject:candidate];
    }

    // Case-insensitive duplicate check matches how the filesystem treats names.
    NSMutableSet<NSString *> *seen = [NSMutableSet setWithCapacity:result.count];
    for (NSString *name in result) {
        NSString *key = name.lowercaseString;
        if ([seen containsObject:key]) {
            if (errorMessage) *errorMessage = [NSString stringWithFormat:
                @"重命名后出现重名：“%@”。", name];
            return nil;
        }
        [seen addObject:key];
    }

    // A no-op rename of every item is almost certainly a mistake.
    BOOL changed = NO;
    for (NSUInteger index = 0; index < names.count; index++)
        if (![names[index] isEqualToString:result[index]]) { changed = YES; break; }
    if (!changed) {
        if (errorMessage) *errorMessage = @"没有项目需要重命名。";
        return nil;
    }
    return result;
}

@end
