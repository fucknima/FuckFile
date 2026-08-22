#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// One entry inside an archive listing.
@interface FFArchiveEntry : NSObject
@property(nonatomic, copy) NSString *entryPath;   // full path within the archive
@property(nonatomic) BOOL isDirectory;
@property(nonatomic) unsigned long long size;
@property(nonatomic) unsigned long long compressedSize;
@end

// Read-only zip central-directory access for FFArchiveBrowserViewController:
// list entries, extract a single entry to a file, and report format
// capability honestly.
//
// Supported backend: zip-family containers parsed via their EOCD/central
// directory (store + deflate, CRC-checked, ZIP64/symlink/unsafe names
// rejected). tar/gz/7z/rar/xz/bz2 are NOT parseable by this build —
// callers must surface "暂不支持" instead of pretending success; .deb is
// deliberately excluded everywhere.
@interface FFArchiveService : NSObject

// Extensions whose content is a real zip container this service can open.
+ (BOOL)isZipFamilyExtension:(NSString *)extension;

// Extensions routed to the archive viewer by default association but not
// parseable here (shown as unsupported).
+ (BOOL)isKnownButUnsupportedExtension:(NSString *)extension;

- (nullable NSArray<FFArchiveEntry *> *)listEntries:(NSString *)archivePath
    error:(NSError **)error;

// Extracts one file entry to an existing destination directory, keeping
// its basename. Returns the created file path on success.
- (nullable NSString *)extractEntry:(NSString *)entryName
                        fromArchive:(NSString *)archivePath
                         toDirectory:(NSString *)destinationDirectory
                              error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
