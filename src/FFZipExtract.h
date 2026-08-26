#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const FFZipExtractErrorDomain;

typedef NS_ERROR_ENUM(FFZipExtractErrorDomain, FFZipExtractErrorCode) {
    FFZipExtractErrorInvalidArchive = 1,
    FFZipExtractErrorUnsafeEntry = 2,
    FFZipExtractErrorUnsupportedCompression = 3,
    FFZipExtractErrorPasswordRequired = 4,
    FFZipExtractErrorWrongPassword = 5,
    FFZipExtractErrorTooLarge = 6,
    FFZipExtractErrorIO = 7,
};

// Extracts a ZIP-family archive into destDir. Existing callers keep the
// password-less API; encrypted archives return FFZipExtractErrorPasswordRequired.
BOOL FFZipExtract(NSString *archivePath, NSString *destDir,
                  NSArray<NSString *> * _Nullable * _Nullable entryNames,
                  NSError * _Nullable * _Nullable error);

BOOL FFZipExtractWithProgress(NSString *archivePath, NSString *destDir,
                  NSArray<NSString *> * _Nullable * _Nullable entryNames,
                  void (^ _Nullable progressBlock)(double progress, NSString *entryName),
                  BOOL (^ _Nullable shouldCancel)(void),
                  NSError * _Nullable * _Nullable error);

// Password-aware variant. Password is used only in memory for traditional
// ZipCrypto decryption and is never written to task history or logs.
BOOL FFZipExtractWithProgressPassword(NSString *archivePath, NSString *destDir,
                  NSString * _Nullable password,
                  NSArray<NSString *> * _Nullable * _Nullable entryNames,
                  void (^ _Nullable progressBlock)(double progress, NSString *entryName),
                  BOOL (^ _Nullable shouldCancel)(void),
                  NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
