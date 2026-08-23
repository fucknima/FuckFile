#import "FFPathDisplay.h"
#import "MCMManager.h"

static NSDateFormatter *FFDateFormatter(NSString *format)
{
    static NSMutableDictionary<NSString *, NSDateFormatter *> *cached;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cached = [NSMutableDictionary dictionary];
    });
    NSDateFormatter *formatter = cached[format];
    if (!formatter) {
        formatter = [NSDateFormatter new];
        formatter.dateFormat = format;
        cached[format] = formatter;
    }
    return formatter;
}

NSString *FFRelativeTimeString(NSDate *date)
{
    if (!date) return @"";
    NSCalendar *calendar = [NSCalendar currentCalendar];
    if ([calendar isDateInToday:date])
        return [NSString stringWithFormat:@"今天 %@",
            [FFDateFormatter(@"HH:mm") stringFromDate:date]];
    if ([calendar isDateInYesterday:date])
        return [NSString stringWithFormat:@"昨天 %@",
            [FFDateFormatter(@"HH:mm") stringFromDate:date]];
    return [FFDateFormatter(@"yyyy-MM-dd HH:mm") stringFromDate:date];
}

static NSArray<NSString *> *FFCleanComponents(NSString *path)
{
    NSMutableArray<NSString *> *cleaned = [NSMutableArray array];
    NSArray<NSString *> *components = path.pathComponents;
    for (NSString *component in components) {
        if ([component isEqualToString:@"/"]) continue;
        if (cleaned.count == 0 &&
            [@[@"private", @"var", @"mobile", @"Containers", @"Data",
               @"Application"] containsObject:component]) continue;
        [cleaned addObject:component];
    }
    return cleaned;
}

NSString *FFDisplayPathForPath(NSString *path)
{
    if (!path.length) return @"";
    NSString *root = [MCMVirtualRoot() stringByStandardizingPath];
    NSString *standardized = [path stringByStandardizingPath];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if ([standardized isEqualToString:root]) {
        return @"设备存储";
    }
    if ([standardized hasPrefix:[root stringByAppendingString:@"/"]]) {
        NSArray<NSString *> *rest = [[standardized substringFromIndex:root.length + 1]
            pathComponents];
        [parts addObjectsFromArray:rest];
    } else {
        [parts addObjectsFromArray:FFCleanComponents(standardized)];
    }
    if (parts.count > 3)
        parts = [NSMutableArray arrayWithArray:[parts subarrayWithRange:
            NSMakeRange(parts.count - 3, 3)]];
    return [parts componentsJoinedByString:@" › "];
}
