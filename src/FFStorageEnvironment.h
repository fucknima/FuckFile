#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *FFStorageRootPath(void);
FOUNDATION_EXPORT NSString *FFImportedDirectoryPath(void);
FOUNDATION_EXPORT NSString *FFAppDataVirtualPath(void);
FOUNDATION_EXPORT BOOL FFPathRequiresSystemAccess(NSString *path);
FOUNDATION_EXPORT NSArray<NSString *> *FFManagedSystemEntryNames(void);
FOUNDATION_EXPORT void FFPrepareStorageRootForNormalMode(void);

NS_ASSUME_NONNULL_END
