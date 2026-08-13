#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Extracts a zip-family archive (zip/ipa/deb/xcarchive/…) into destDir.
// Handles stored and deflated entries; skips directories automatically,
// sanitizes entry names (rejects ".." and absolute paths), and sets *error
// on failure. Returns YES on success. Extracted entries are returned in
// *entryNames when non-NULL (relative paths, files only).
BOOL FFZipExtract(NSString *archivePath, NSString *destDir,
                  NSArray<NSString *> * _Nullable * _Nullable entryNames,
                  NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
