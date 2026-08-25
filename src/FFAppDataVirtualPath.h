#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

BOOL FFAppDataIsVirtualRootPath(NSString *path);
BOOL FFAppDataExtractLogicalIdentifier(NSString *path,
                                       NSString * _Nullable * _Nullable identifierOut,
                                       NSString * _Nullable * _Nullable relativePathOut);

// Ensures the logical AppData/<bundle-id> node has a current-process MCM lease
// and a session-only compatibility symlink. The symlink is an implementation
// detail for legacy file-operation code; the persistent source of truth remains
// the registry.
BOOL FFAppDataEnsureLogicalPathMaterialized(NSString *logicalPath,
                                            NSError * _Nullable * _Nullable error);

// Returns the real current-process path for a logical AppData path. Non-AppData
// paths are returned unchanged. Acquires the lease lazily when needed.
NSString * _Nullable FFAppDataResolveLogicalPath(NSString *logicalPath,
                                                  NSError * _Nullable * _Nullable error);

// Materializes all currently known registry entries with bounded concurrency.
// Used only for explicit recursive search; normal browsing stays fully lazy.
void FFAppDataMaterializeKnownForTraversal(NSUInteger maxConcurrency);

NS_ASSUME_NONNULL_END
