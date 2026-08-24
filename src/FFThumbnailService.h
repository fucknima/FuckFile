#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, FFThumbnailKind) {
    FFThumbnailKindNone = 0,
    FFThumbnailKindImage,
    FFThumbnailKindVideo,
    FFThumbnailKindPDF,
    FFThumbnailKindIPA,
};

// Async thumbnail generation for images, videos, PDFs and IPA app icons with
// two-level caching and in-flight request coalescing.
@interface FFThumbnailService : NSObject

+ (instancetype)sharedService;

- (void)thumbnailForPath:(NSString *)path
                    size:(CGSize)size
              completion:(void (^)(UIImage * _Nullable image))completion;

- (void)clearCaches;
- (unsigned long long)diskCacheSize;

@end

NS_ASSUME_NONNULL_END
