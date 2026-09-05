#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class FFArchiveEntry;

// Runtime bridge to Apple's system libarchive. FuckFile is a sideloaded research
// app, so using the system dylib is acceptable here and avoids replacing the
// stable ZIP/minizip implementation or bundling a second large decompressor.
FOUNDATION_EXPORT BOOL FFLibArchiveBackendAvailable(void);

FOUNDATION_EXPORT nullable NSArray<FFArchiveEntry *> *
FFLibArchiveListEntries(NSString *archivePath,
                        nullable NSString *password,
                        NSError * _Nullable * _Nullable error);

FOUNDATION_EXPORT nullable NSString *
FFLibArchiveExtractEntry(NSString *entryName,
                         NSString *archivePath,
                         NSString *destinationDirectory,
                         nullable NSString *password,
                         NSError * _Nullable * _Nullable error);

FOUNDATION_EXPORT BOOL
FFLibArchiveExtractAll(NSString *archivePath,
                       NSString *destinationDirectory,
                       nullable NSString *password,
                       NSArray<NSString *> * _Nullable * _Nullable entryNames,
                       void (^ _Nullable progressBlock)(double progress, NSString *entryName),
                       BOOL (^ _Nullable shouldCancel)(void),
                       NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
