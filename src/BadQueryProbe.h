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

// Like BadQueryConsumePath, but only accepts a handle after access()/open()
// on the target path actually succeeds. Use this when the caller needs to
// opendir/open the path directly (e.g. the browser opening a real directory
// such as the MobileGestalt Caches folder). Keeps trying matrix combos until
// one grants real access; returns < 0 and sets *error when none does.
FOUNDATION_EXPORT int64_t BadQueryConsumePathForOpen(NSString *path,
                                                      NSString * _Nullable * _Nullable error);

// Lists a directory with bad_query_list (fsgetpath) instead of opendir.
// Some system-group directories (e.g. MobileGestalt Caches on iOS 26.6)
// deny opendir even when the token grants file access; fsgetpath still
// resolves their child paths. Returns direct-child names or nil on failure.
FOUNDATION_EXPORT NSArray<NSString *> * _Nullable BadQueryListDirectory(
    NSString *path, NSString * _Nullable * _Nullable error);

// Canonical bad_query with create=true (skips the existing-path precheck),
// falling back to the variant matrix when the canonical flags are blocked.
// Used by the on-device write-capability test.
FOUNDATION_EXPORT int64_t BadQueryConsumePathCreate(NSString *path,
                                                     NSString * _Nullable * _Nullable error);

// Tries to create and write a probe file under directory, and separately
// probes whether com.apple.MobileGestalt.plist in that directory can be
// opened for writing. Logs every step; returns a result dictionary.
FOUNDATION_EXPORT NSDictionary * _Nullable BadQueryProbeWriteTest(
    NSString *directory, NSString * _Nullable * _Nullable error);

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

// Re-consumes a sandbox extension for every escaped root and keeps the
// handles alive for the process lifetime. Use at startup and after a probe
// re-run so previously created symlinks under
//   Device Storage/[BadQuery] Escaped/
// stay reachable even after the app was restarted.
FOUNDATION_EXPORT NSDictionary * _Nullable BadQueryReconnectEscapedRoots(void);

NS_ASSUME_NONNULL_END
