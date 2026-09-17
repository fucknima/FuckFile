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
+ (BOOL)isGenericArchivePath:(NSString *)archivePath;
+ (BOOL)isArchivePathSupported:(NSString *)archivePath;
+ (BOOL)genericArchiveBackendAvailable;
+ (BOOL)isKnownButUnsupportedExtension:(NSString *)extension;
+ (NSString *)archiveStemForPath:(NSString *)archivePath;

// 解压目标唯一化：目标已存在时依次尝试 "xxx 2"、"xxx 3"…，
// 避免静默替换/删除上一次解压出来的同名目录（含用户改动）。
+ (nullable NSString *)uniqueDirectoryInParent:(NSString *)parent baseName:(NSString *)base;

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

+ (BOOL)extractArchiveAtPath:(NSString *)archivePath
                 toDirectory:(NSString *)destinationDirectory
                    password:(nullable NSString *)password
                  entryNames:(NSArray<NSString *> * _Nullable * _Nullable)entryNames
                    progress:(void (^ _Nullable)(double progress, NSString *entryName))progressBlock
                shouldCancel:(BOOL (^ _Nullable)(void))shouldCancel
                       error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
