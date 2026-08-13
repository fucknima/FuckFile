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

// Variant with progress (0.0-1.0, current entry name) and cancellation
// callbacks; both may be NULL.
BOOL FFZipExtractWithProgress(NSString *archivePath, NSString *destDir,
                  NSArray<NSString *> * _Nullable * _Nullable entryNames,
                  void (^ _Nullable progressBlock)(double progress, NSString *entryName),
                  BOOL (^ _Nullable shouldCancel)(void),
                  NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
