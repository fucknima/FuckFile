// BadQueryProbe — step-by-step capability probe for the bad_query sandbox
// escape (https://github.com/forcequitOS/bad_query) on iOS 26.x.
// Logs every step to the system log AND to:
//   <Documents>/Device Storage/BadQuery Probe Log.txt
// Results are written to:
//   <Documents>/Device Storage/BadQuery Probe Results.plist
// Successful paths are symlinked into:
//   <Documents>/Device Storage/[BadQuery] Escaped/
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void BadQueryProbeRun(void);

NS_ASSUME_NONNULL_END
