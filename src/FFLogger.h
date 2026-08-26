#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Diagnostic log lives one level above Device Storage so it is not exposed as
// a normal user file in FuckFile's browser.
FOUNDATION_EXPORT NSString *FFLogPath(void);

// File logging controls. NSLog mirroring remains available even when file
// logging is disabled, so disabling the on-disk log does not hide diagnostics
// from a debugger/console session.
FOUNDATION_EXPORT BOOL FFLogFileEnabled(void);
FOUNDATION_EXPORT void FFSetLogFileEnabled(BOOL enabled);
FOUNDATION_EXPORT unsigned long long FFLogMaxBytes(void);   // 0 = unlimited
FOUNDATION_EXPORT void FFSetLogMaxBytes(unsigned long long bytes);
FOUNDATION_EXPORT NSUInteger FFLogMaxAgeDays(void);        // 0 = unlimited
FOUNDATION_EXPORT void FFSetLogMaxAgeDays(NSUInteger days);
FOUNDATION_EXPORT unsigned long long FFLogFileSize(void);
FOUNDATION_EXPORT void FFPerformLogCleanup(void);

// Appends a timestamped line to the log file (when enabled) and mirrors it to
// NSLog. Thread-safe; creates the file/directory as needed.
FOUNDATION_EXPORT void FFLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
FOUNDATION_EXPORT void FFLogTag(NSString *tag, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);

NS_ASSUME_NONNULL_END
