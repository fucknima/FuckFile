#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FFImportResult : NSObject
@property(nonatomic, readonly) BOOL success;
@property(nonatomic, readonly, copy) NSString *sourcePath;
@property(nonatomic, readonly, copy, nullable) NSString *destinationPath;
@property(nonatomic, readonly, copy, nullable) NSError *error;
@property(nonatomic, readonly) BOOL usedSecurityScope;
@property(nonatomic, readonly) BOOL coordinated;
@end

@interface FFImportService : NSObject

// Synchronous primitive. Call from a background queue for large files.
// displayName lets shared-inbox payloads keep the sender's original name.
+ (FFImportResult *)importURL:(NSURL *)url
                 displayName:(nullable NSString *)displayName
                 toDirectory:(NSString *)directory;

+ (NSArray<FFImportResult *> *)importURLs:(NSArray<NSURL *> *)urls
                             toDirectory:(NSString *)directory;

@end

NS_ASSUME_NONNULL_END
