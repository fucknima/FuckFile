#import "FFLogger.h"

#import <objc/runtime.h>

static NSString *gLogPath;
static NSLock *gLogLock;
static NSDateFormatter *gFormatter;

static void FFEnsureState(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gLogLock = [NSLock new];
        gFormatter = [NSDateFormatter new];
        gFormatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });
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
    [gLogLock lock];
    NSString *path = FFLogPath();
    NSString *directory = path.stringByDeletingLastPathComponent;
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
        withIntermediateDirectories:YES attributes:nil error:nil];
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
    [gLogLock unlock];
}

static void FFWriteMessage(NSString *tag, NSString *message)
{
    FFEnsureState();
    NSString *stamp = [gFormatter stringFromDate:NSDate.date];
    NSString *line = [NSString stringWithFormat:@"[%@] [%@] %@\n",
        stamp, tag ?: @"FuckFile", message];
    NSLog(@"[%@] %@", tag ?: @"FuckFile", message);
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
