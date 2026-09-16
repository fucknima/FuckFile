#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// User-visible file root. This is the app's real Documents directory.
FOUNDATION_EXPORT NSString *FFStorageRootPath(void);
FOUNDATION_EXPORT NSString *FFImportedDirectoryPath(void);

// Ephemeral diagnostics live under the app container's tmp directory so they
// never appear as user documents / Files.app content.
FOUNDATION_EXPORT NSString *FFDiagnosticsDirectoryPath(void);

// Rewrites absolute paths persisted by old builds from
// Documents/Device Storage/... to Documents/... . Non-legacy paths are returned
// unchanged (after standardization).
FOUNDATION_EXPORT NSString *FFCanonicalStoragePath(NSString *path);

// Internal generated files that must never be presented as normal Documents
// content. This is presentation/search policy only.
FOUNDATION_EXPORT BOOL FFIsInternalStorageEntry(NSString *parentPath, NSString *name);

NS_ASSUME_NONNULL_END
