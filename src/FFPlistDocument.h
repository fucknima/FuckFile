#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const FFPlistDocumentDidChangeNotification;
FOUNDATION_EXPORT NSString * const FFPlistDocumentErrorDomain;

typedef NS_ENUM(NSInteger, FFPlistDocumentErrorCode) {
    FFPlistDocumentErrorUnreadable = 1,
    FFPlistDocumentErrorTooLarge,
    FFPlistDocumentErrorInvalidPropertyList,
    FFPlistDocumentErrorUnsupportedRoot,
    FFPlistDocumentErrorSerialization,
    FFPlistDocumentErrorExternalModification,
    FFPlistDocumentErrorPathRejected,
    FFPlistDocumentErrorWriteFailed,
    FFPlistDocumentErrorVerificationFailed,
};

@interface FFPlistDocument : NSObject

@property(nonatomic, copy, readonly) NSString *filePath;
@property(nonatomic, strong, readonly, nullable) id rootObject;
@property(nonatomic, readonly) NSPropertyListFormat format;
@property(nonatomic, readonly, getter=isLoaded) BOOL loaded;
@property(nonatomic, readonly, getter=isDirty) BOOL dirty;
@property(nonatomic, readonly) unsigned long long fileSize;

- (instancetype)initWithPath:(NSString *)path;

// Synchronous by design; callers load on a background queue. maxBytes == 0 disables
// the limit, though the structured editor always supplies its public 8 MB ceiling.
- (BOOL)loadWithMaximumBytes:(unsigned long long)maxBytes error:(NSError **)error;

// Marks a mutation performed on rootObject (containers are intentionally mutable).
- (void)markChanged;

// Serialize using the exact format reported by NSPropertyListSerialization at load.
- (nullable NSData *)serializedData:(NSError **)error;

// Returns YES when the on-disk bytes no longer match the bytes this document was
// opened/successfully saved from. A missing/unreadable original also counts as a
// conflict so a stale editor never silently recreates or overwrites it.
- (BOOL)hasExternalModification:(NSError **)error;

// Normal save refuses an external modification. force:YES is only for the explicit
// user "overwrite" path after the conflict prompt.
- (BOOL)saveForcingExternalOverwrite:(BOOL)force error:(NSError **)error;

// Save a copy without changing filePath or clearing dirty state.
- (BOOL)saveCopyToPath:(NSString *)copyPath error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
