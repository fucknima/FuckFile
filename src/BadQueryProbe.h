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

// Re-runs the full probe set (used from the on-device console).
FOUNDATION_EXPORT void BadQueryProbeRunAgain(void);

// Reads the last report written by the probe; returns nil if none exists yet.
FOUNDATION_EXPORT NSDictionary * _Nullable BadQueryProbeLastReport(void);

// Returns the accumulated probe log text ("" if the log file is missing).
FOUNDATION_EXPORT NSString * _Nullable BadQueryProbeLogText(void);

// On-demand bad_query consume for a custom absolute path. Returns a sandbox
// extension handle (>= 0) or one of the bad_query negative error codes.
// Sets *error to a human-readable message for failures.
FOUNDATION_EXPORT int64_t BadQueryConsumePath(NSString *path,
                                               NSString * _Nullable groupIdentifier,
                                               BOOL isGroup,
                                               NSString * _Nullable * _Nullable error);

// Releases a handle returned by BadQueryConsumePath / bad_query().
FOUNDATION_EXPORT void BadQueryReleaseHandle(int64_t handle);

// Consumes escapes for the main container roots, enumerates every child with
// bad_query_list (fsgetpath), reads each container's
// .com.apple.mobile_container_manager.metadata.plist to map UUID -> bundle ID,
// and symlinks them into:
//   Device Storage/[BadQuery] Escaped/<App Data|App Groups|...>/<BundleID>
// Returns a summary plist. iOS 26 App Group roots use the configured
// AppGroupSacrifice route automatically.
FOUNDATION_EXPORT NSDictionary * _Nullable BadQueryEnumerateAllContainers(void);

NS_ASSUME_NONNULL_END
