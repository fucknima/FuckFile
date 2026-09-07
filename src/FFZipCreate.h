#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Same writer with an explicit zlib level (0 = store, 1-9 = deflate).
// Existing callers keep FFCreateZipArchive and therefore preserve the old
// default compression behaviour.
BOOL FFCreateZipArchiveWithLevel(NSArray<NSString *> *sourcePaths,
                                 NSString *destinationPath,
                                 NSInteger compressionLevel,
                                 void (^ _Nullable progressBlock)(double progress, NSString *entryName),
                                 BOOL (^ _Nullable shouldCancel)(void),
                                 NSError * _Nullable * _Nullable error);

// Creates a zip archive from files and folders (recursive, symlinks
// skipped, UTF-8 names). Small or already-compressed files are stored
// uncompressed; everything else is deflated. Progress reports
// (0.0-1.0, current entry name); cancellation is checked between
// entries. Returns YES on success, sets *error otherwise.
BOOL FFCreateZipArchive(NSArray<NSString *> *sourcePaths,
                        NSString *destinationPath,
                        void (^ _Nullable progressBlock)(double progress, NSString *entryName),
                        BOOL (^ _Nullable shouldCancel)(void),
                        NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
