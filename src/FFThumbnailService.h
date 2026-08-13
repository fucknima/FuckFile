#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, FFThumbnailKind) {
    FFThumbnailKindNone = 0,
    FFThumbnailKindImage,
    FFThumbnailKindVideo,
    FFThumbnailKindPDF,
};

// Async thumbnail generation for images, videos and PDFs with a
// two-level cache (memory NSCache + disk JPEG cache) and in-flight
// request coalescing so scrolling a large directory never re-generates
// the same thumbnail.
@interface FFThumbnailService : NSObject

+ (instancetype)sharedService;

// Requests a thumbnail. Completion is called on an arbitrary queue;
// nil means "no thumbnail for this file". Failures are never cached.
- (void)thumbnailForPath:(NSString *)path
                    size:(CGSize)size
              completion:(void (^)(UIImage * _Nullable image))completion;

// Drops the memory cache and deletes the on-disk cache directory.
- (void)clearCaches;

// Total bytes of the on-disk thumbnail cache (for storage reporting).
- (unsigned long long)diskCacheSize;

@end

NS_ASSUME_NONNULL_END
