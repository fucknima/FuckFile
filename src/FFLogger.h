#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Path to the on-device step log: <Documents>/Device Storage/FuckFile Log.txt
FOUNDATION_EXPORT NSString *FFLogPath(void);

// Appends a timestamped line to the log file (and mirrors it to NSLog).
// Thread-safe; creates the file/directory as needed.
FOUNDATION_EXPORT void FFLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
FOUNDATION_EXPORT void FFLogTag(NSString *tag, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);

NS_ASSUME_NONNULL_END
