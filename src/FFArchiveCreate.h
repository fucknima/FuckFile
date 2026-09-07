#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, FFArchiveCreateFormat) {
    FFArchiveCreateFormatZIP = 0,
    FFArchiveCreateFormatTAR,
};

typedef NS_ENUM(NSInteger, FFZipCompressionLevel) {
    FFZipCompressionLevelBalanced = 0,
    FFZipCompressionLevelSmallest,
    FFZipCompressionLevelStore,
};

typedef NS_ENUM(NSInteger, FFZipEncryptionMode) {
    FFZipEncryptionModeNone = 0,
    FFZipEncryptionModeAES256,
};

@interface FFArchiveCreateOptions : NSObject <NSCopying>
@property(nonatomic) FFArchiveCreateFormat format;
@property(nonatomic) FFZipCompressionLevel zipCompression;
@property(nonatomic) FFZipEncryptionMode zipEncryption;
@property(nonatomic, copy, nullable) NSString *password;
@end

FOUNDATION_EXPORT BOOL FFArchiveEncryptedZIPWriterAvailable(void);

FOUNDATION_EXPORT BOOL
FFCreateArchive(NSArray<NSString *> *sourcePaths,
                NSString *destinationPath,
                FFArchiveCreateOptions *options,
                void (^ _Nullable progressBlock)(double progress, NSString *entryName),
                BOOL (^ _Nullable shouldCancel)(void),
                NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
