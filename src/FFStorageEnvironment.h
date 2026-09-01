#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// User-visible file root. This is the app's real Documents directory; there is
// no extra "Device Storage" container directory anymore.
FOUNDATION_EXPORT NSString *FFStorageRootPath(void);
FOUNDATION_EXPORT NSString *FFImportedDirectoryPath(void);
FOUNDATION_EXPORT NSString *FFAppDataVirtualPath(void);

// Ephemeral diagnostics live under the app container's tmp directory so they
// never appear as user documents / Files.app content.
FOUNDATION_EXPORT NSString *FFDiagnosticsDirectoryPath(void);

// Rewrites absolute paths persisted by old builds from
// Documents/Device Storage/... to Documents/... . Non-legacy paths are returned
// unchanged (after standardization).
FOUNDATION_EXPORT NSString *FFCanonicalStoragePath(NSString *path);

FOUNDATION_EXPORT BOOL FFPathRequiresSystemAccess(NSString *path);
FOUNDATION_EXPORT NSArray<NSString *> *FFManagedSystemEntryNames(void);

// Internal generated files that must never be presented as normal Documents
// content. This is presentation/search policy only; persistent caches retain
// their existing backing paths until their owning subsystem is migrated.
FOUNDATION_EXPORT BOOL FFIsInternalStorageEntry(NSString *parentPath, NSString *name);

FOUNDATION_EXPORT void FFPrepareStorageRootForNormalMode(void);

NS_ASSUME_NONNULL_END
