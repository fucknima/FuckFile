#import "FFLogger.h"

static NSString *gLogPath;
static dispatch_queue_t gLogQueue;
static NSDateFormatter *gFormatter;

static NSString *const kFFLogEnabledKey = @"FFLogFileEnabledV1";
static NSString *const kFFLogMaxBytesKey = @"FFLogMaxBytesV1";
static NSString *const kFFLogMaxAgeDaysKey = @"FFLogMaxAgeDaysV1";
static NSString *const kFFLogEpochKey = @"FFLogEpochV1";
static const unsigned long long kFFDefaultLogMaxBytes = 5ULL * 1024ULL * 1024ULL;
static const NSUInteger kFFDefaultLogMaxAgeDays = 30;

static void FFEnsureState(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gLogQueue = dispatch_queue_create("ff.logger", DISPATCH_QUEUE_SERIAL);
        gFormatter = [NSDateFormatter new];
        gFormatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });
}

static NSUserDefaults *FFLogDefaults(void)
{
    return NSUserDefaults.standardUserDefaults;
}

BOOL FFLogFileEnabled(void)
{
    id value = [FFLogDefaults() objectForKey:kFFLogEnabledKey];
    return value == nil ? YES : [value boolValue];
}

void FFSetLogFileEnabled(BOOL enabled)
{
    [FFLogDefaults() setBool:enabled forKey:kFFLogEnabledKey];
}

unsigned long long FFLogMaxBytes(void)
{
    id value = [FFLogDefaults() objectForKey:kFFLogMaxBytesKey];
    return value == nil ? kFFDefaultLogMaxBytes : [value unsignedLongLongValue];
}

void FFSetLogMaxBytes(unsigned long long bytes)
{
    [FFLogDefaults() setObject:@(bytes) forKey:kFFLogMaxBytesKey];
    FFPerformLogCleanup();
}

NSUInteger FFLogMaxAgeDays(void)
{
    id value = [FFLogDefaults() objectForKey:kFFLogMaxAgeDaysKey];
    return value == nil ? kFFDefaultLogMaxAgeDays : [value unsignedIntegerValue];
}

void FFSetLogMaxAgeDays(NSUInteger days)
{
    [FFLogDefaults() setObject:@(days) forKey:kFFLogMaxAgeDaysKey];
    FFPerformLogCleanup();
}

// Path redaction: container UUIDs collapse to their first segment and
// the /private/var mount prefix is normalized, so shared logs never
// leak full container identifiers.
static NSString *FFRedactPath(NSString *input)
{
    if (!input.length) return input;
    NSMutableString *result = [input mutableCopy];
    NSRegularExpression *shortUuid = [NSRegularExpression
        regularExpressionWithPattern:@"([0-9A-Fa-f]{8})-[0-9A-Fa-f-]{27}"
        options:0 error:nil];
    [shortUuid replaceMatchesInString:result options:0 range:NSMakeRange(0, result.length)
        withTemplate:@"$1…"];
    [result replaceOccurrencesOfString:@"/private/var" withString:@"/var"
        options:0 range:NSMakeRange(0, result.length)];
    return result;
}

static void FFMigrateLegacyLogIfNeeded(NSString *documents, NSString *newPath)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *oldPath = [[documents stringByAppendingPathComponent:@"Device Storage"]
        stringByAppendingPathComponent:@"FuckFile Log.txt"];
    NSString *oldRotated = [[[oldPath stringByDeletingPathExtension]
        stringByAppendingString:@".old"] stringByAppendingPathExtension:@"txt"];

    if ([fm fileExistsAtPath:oldPath]) {
        if (![fm fileExistsAtPath:newPath]) {
            NSError *moveError = nil;
            if (![fm moveItemAtPath:oldPath toPath:newPath error:&moveError])
                [fm removeItemAtPath:oldPath error:nil];
        } else {
            [fm removeItemAtPath:oldPath error:nil];
        }
    }
    // Old builds could leave a rotated file in Device Storage. It is diagnostic
    // state, not user content, so remove it during migration rather than exposing
    // a second generated file in the browser.
    [fm removeItemAtPath:oldRotated error:nil];
}

NSString *FFLogPath(void)
{
    FFEnsureState();
    static dispatch_once_t pathOnce;
    dispatch_once(&pathOnce, ^{
        NSString *documents = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSHomeDirectory();
        gLogPath = [documents stringByAppendingPathComponent:@"FuckFile Log.txt"];
        FFMigrateLegacyLogIfNeeded(documents, gLogPath);
    });
    return gLogPath;
}

static BOOL FFLogShouldResetLocked(NSString *path)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:path]) {
        [FFLogDefaults() setObject:@(NSDate.date.timeIntervalSince1970) forKey:kFFLogEpochKey];
        return NO;
    }

    unsigned long long maxBytes = FFLogMaxBytes();
    if (maxBytes > 0) {
        NSNumber *size = [fm attributesOfItemAtPath:path error:nil][NSFileSize];
        if (size.unsignedLongLongValue >= maxBytes) return YES;
    }

    NSUInteger maxDays = FFLogMaxAgeDays();
    if (maxDays > 0) {
        NSTimeInterval epoch = [[FFLogDefaults() objectForKey:kFFLogEpochKey] doubleValue];
        if (epoch <= 0) {
            NSDate *created = [fm attributesOfItemAtPath:path error:nil][NSFileCreationDate];
            epoch = created ? created.timeIntervalSince1970 : NSDate.date.timeIntervalSince1970;
            [FFLogDefaults() setObject:@(epoch) forKey:kFFLogEpochKey];
        }
        NSTimeInterval maxAge = (NSTimeInterval)maxDays * 24.0 * 60.0 * 60.0;
        if (NSDate.date.timeIntervalSince1970 - epoch >= maxAge) return YES;
    }
    return NO;
}

static void FFResetLogLocked(NSString *path)
{
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    [FFLogDefaults() setObject:@(NSDate.date.timeIntervalSince1970) forKey:kFFLogEpochKey];
}

void FFPerformLogCleanup(void)
{
    FFEnsureState();
    dispatch_sync(gLogQueue, ^{
        NSString *path = FFLogPath();
        if (FFLogShouldResetLocked(path)) FFResetLogLocked(path);
    });
}

unsigned long long FFLogFileSize(void)
{
    NSNumber *size = [NSFileManager.defaultManager
        attributesOfItemAtPath:FFLogPath() error:nil][NSFileSize];
    return size.unsignedLongLongValue;
}

static void FFAppendLine(NSString *line)
{
    if (!FFLogFileEnabled() || !line.length) return;
    FFEnsureState();
    dispatch_sync(gLogQueue, ^{
        NSString *path = FFLogPath();
        if (FFLogShouldResetLocked(path)) FFResetLogLocked(path);

        NSString *directory = path.stringByDeletingLastPathComponent;
        [NSFileManager.defaultManager createDirectoryAtPath:directory
            withIntermediateDirectories:YES attributes:nil error:nil];

        if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
            [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [FFLogDefaults() setObject:@(NSDate.date.timeIntervalSince1970) forKey:kFFLogEpochKey];
            return;
        }
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!handle) return;
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    });
}

static void FFWriteMessage(NSString *tag, NSString *message)
{
    FFEnsureState();
    NSString *redacted = FFRedactPath(message);
    NSLog(@"[%@] %@", tag ?: @"FuckFile", redacted);
    if (!FFLogFileEnabled()) return;

    __block NSString *line = nil;
    dispatch_sync(gLogQueue, ^{
        NSString *stamp = [gFormatter stringFromDate:NSDate.date];
        line = [NSString stringWithFormat:@"[%@] [%@] %@\n",
            stamp, tag ?: @"FuckFile", redacted];
    });
    FFAppendLine(line);
}

void FFLogTag(NSString *tag, NSString *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    FFWriteMessage(tag, message);
}

void FFLog(NSString *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    FFWriteMessage(@"FuckFile", message);
}
