#import "FFLogger.h"

#import <objc/runtime.h>

static NSString *gLogPath;
static dispatch_queue_t gLogQueue;
static NSDateFormatter *gFormatter;
static const unsigned long long kFFLogRotationBytes = 1024 * 1024;

static void FFEnsureState(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gLogQueue = dispatch_queue_create("ff.logger", DISPATCH_QUEUE_SERIAL);
        gFormatter = [NSDateFormatter new];
        gFormatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });
}

// Path redaction: container UUIDs collapse to their first segment and
// the /private/var mount prefix is normalized, so shared logs never
// leak full container identifiers.
static NSString *FFRedactPath(NSString *input)
{
    if (!input.length) return input;
    NSMutableString *result = [input mutableCopy];
    // Full UUIDs (36 hex-dash chars) collapse to their first 8 chars.
    NSRegularExpression *shortUuid = [NSRegularExpression
        regularExpressionWithPattern:@"([0-9A-Fa-f]{8})-[0-9A-Fa-f-]{27}"
        options:0 error:nil];
    [shortUuid replaceMatchesInString:result options:0 range:NSMakeRange(0, result.length)
        withTemplate:@"$1…"];
    [result replaceOccurrencesOfString:@"/private/var" withString:@"/var"
        options:0 range:NSMakeRange(0, result.length)];
    return result;
}

NSString *FFLogPath(void)
{
    FFEnsureState();
    if (!gLogPath) {
        NSString *documents = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        gLogPath = [[documents stringByAppendingPathComponent:@"Device Storage"]
            stringByAppendingPathComponent:@"FuckFile Log.txt"];
    }
    return gLogPath;
}

static void FFAppendLine(NSString *line)
{
    FFEnsureState();
    dispatch_sync(gLogQueue, ^{
        NSString *path = FFLogPath();
        NSString *directory = path.stringByDeletingLastPathComponent;
        [[NSFileManager defaultManager] createDirectoryAtPath:directory
            withIntermediateDirectories:YES attributes:nil error:nil];

        // Rotation: once the log exceeds the cap, the current file is
        // archived to "<name>.old.txt" and a fresh file starts.
        NSNumber *size = [[NSFileManager defaultManager]
            attributesOfItemAtPath:path error:nil][NSFileSize];
        if (size.unsignedLongLongValue > kFFLogRotationBytes) {
            NSString *oldPath = [[path stringByDeletingPathExtension]
                stringByAppendingString:@".old.txt"];
            [[NSFileManager defaultManager] removeItemAtPath:oldPath error:nil];
            [[NSFileManager defaultManager] moveItemAtPath:path toPath:oldPath error:nil];
        }

        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
            if (handle) {
                [handle seekToEndOfFile];
                [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                [handle closeFile];
            }
        }
    });
}

static void FFWriteMessage(NSString *tag, NSString *message)
{
    FFEnsureState();
    NSString *redacted = FFRedactPath(message);
    __block NSString *line = nil;
    dispatch_sync(gLogQueue, ^{
        NSString *stamp = [gFormatter stringFromDate:NSDate.date];
        line = [NSString stringWithFormat:@"[%@] [%@] %@\n",
            stamp, tag ?: @"FuckFile", redacted];
    });
    NSLog(@"[%@] %@", tag ?: @"FuckFile", redacted);
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
