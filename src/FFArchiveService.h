#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FFArchiveEntry : NSObject
@property(nonatomic, copy) NSString *entryPath;
@property(nonatomic) BOOL isDirectory;
@property(nonatomic) BOOL encrypted;
@property(nonatomic) unsigned long long size;
@property(nonatomic) unsigned long long compressedSize;
@end

// Read-only ZIP access for FFArchiveBrowserViewController, built on vendored
// minizip. Passwords are supported for traditional ZipCrypto archives and are
// cached only in process memory; they are never written to disk or logs.
@interface FFArchiveService : NSObject

+ (BOOL)isZipFamilyExtension:(NSString *)extension;
+ (BOOL)isKnownButUnsupportedExtension:(NSString *)extension;

+ (nullable NSString *)cachedPasswordForArchivePath:(NSString *)archivePath;
+ (void)cachePassword:(NSString *)password forArchivePath:(NSString *)archivePath;
+ (void)clearCachedPasswordForArchivePath:(NSString *)archivePath;

- (nullable NSArray<FFArchiveEntry *> *)listEntries:(NSString *)archivePath
    error:(NSError **)error;

- (nullable NSString *)extractEntry:(NSString *)entryName
                        fromArchive:(NSString *)archivePath
                       toDirectory:(NSString *)destinationDirectory
                              error:(NSError **)error;

- (nullable NSString *)extractEntry:(NSString *)entryName
                        fromArchive:(NSString *)archivePath
                       toDirectory:(NSString *)destinationDirectory
                           password:(nullable NSString *)password
                              error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
