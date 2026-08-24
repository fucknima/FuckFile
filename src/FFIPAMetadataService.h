#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface FFIPAMetadata : NSObject
@property(nonatomic, copy) NSString *displayName;
@property(nonatomic, copy) NSString *bundleIdentifier;
@property(nonatomic, copy) NSString *version;
@property(nonatomic, copy) NSString *build;
@property(nonatomic, copy) NSString *minimumOS;
@property(nonatomic, copy) NSString *appBundlePath;
@property(nonatomic, copy, nullable) NSString *executableName;
@property(nonatomic, strong, nullable) UIImage *icon;
@end

@interface FFIPAMetadataService : NSObject
+ (instancetype)sharedService;

// Worker-queue API. Do not call from the main thread for large IPAs.
- (nullable FFIPAMetadata *)metadataForIPAAtPath:(NSString *)path
                                           error:(NSError **)error;

// UI convenience API. Completion is always delivered on the main queue.
- (void)metadataForIPAAtPath:(NSString *)path
                  completion:(void (^)(FFIPAMetadata * _Nullable metadata,
                                       NSError * _Nullable error))completion;

- (void)iconForIPAAtPath:(NSString *)path
              completion:(void (^)(UIImage * _Nullable icon))completion;

- (void)clearCache;
@end

NS_ASSUME_NONNULL_END
