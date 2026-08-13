#import "FFThumbnailService.h"
#import "FFLogger.h"

#import <AVFoundation/AVFoundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <ImageIO/ImageIO.h>
#import <PDFKit/PDFKit.h>
#import <UIKit/UIKit.h>

@interface FFThumbnailService ()
@property(nonatomic, strong) NSCache<NSString *, UIImage *> *memoryCache;
@property(nonatomic, strong) dispatch_queue_t workQueue;
// key -> array of pending completions, coalescing concurrent requests.
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray *> *inFlight;
@property(nonatomic, strong) NSLock *lock;
@end

@implementation FFThumbnailService

+ (instancetype)sharedService
{
    static FFThumbnailService *service;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        service = [FFThumbnailService new];
    });
    return service;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _memoryCache = [NSCache new];
        _memoryCache.countLimit = 600;
        _memoryCache.totalCostLimit = 48 * 1024 * 1024;
        _workQueue = dispatch_queue_create("ff.thumbnails", DISPATCH_QUEUE_SERIAL);
        _inFlight = [NSMutableDictionary dictionary];
        _lock = [NSLock new];
    }
    return self;
}

static NSString *FFThumbnailKey(NSString *path, CGSize size)
{
    // 缓存键包含修改时间与大小：文件被替换后（路径不变）也重新生成，
    // 避免展示旧缩略图。
    NSString *fingerprint = @"?";
    NSDictionary *attrs = [NSFileManager.defaultManager
        attributesOfItemAtPath:path error:nil];
    if (attrs) {
        NSDate *mtime = attrs[NSFileModificationDate];
        NSNumber *fileSize = attrs[NSFileSize];
        fingerprint = [NSString stringWithFormat:@"%@-%@",
            mtime ? @((long long)mtime.timeIntervalSince1970) : @"-",
            fileSize ?: @"-"];
    }
    return [NSString stringWithFormat:@"%@#%.0fx%.0f#%@",
        path, size.width, size.height, fingerprint];
}

static NSString *FFThumbnailSHA1(NSString *input)
{
    NSData *data = [input dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t digest[CC_SHA1_DIGEST_LENGTH] = {0};
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *result = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA1_DIGEST_LENGTH; index++)
        [result appendFormat:@"%02x", digest[index]];
    return result;
}

static NSString *FFThumbnailDiskRoot(void)
{
    NSString *caches = NSSearchPathForDirectoriesInDomains(
        NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return [caches stringByAppendingPathComponent:@"Thumbnails"];
}

- (void)thumbnailForPath:(NSString *)path
                    size:(CGSize)size
              completion:(void (^)(UIImage *))completion
{
    if (!path.length || !completion) return;
    NSString *key = FFThumbnailKey(path, size);
    UIImage *cached = [self.memoryCache objectForKey:key];
    if (cached) {
        completion(cached);
        return;
    }
    [self.lock lock];
    NSMutableArray *pending = self.inFlight[key];
    if (pending) {
        [pending addObject:[completion copy]];
        [self.lock unlock];
        return;
    }
    pending = [NSMutableArray arrayWithObject:[completion copy]];
    self.inFlight[key] = pending;
    [self.lock unlock];

    NSString *ext = path.pathExtension.lowercaseString;
    FFThumbnailKind kind;
    if ([@[@"png", @"jpg", @"jpeg", @"gif", @"heic", @"webp", @"tiff", @"bmp"] containsObject:ext])
        kind = FFThumbnailKindImage;
    else if ([@[@"mp4", @"mov", @"m4v", @"avi", @"mkv"] containsObject:ext])
        kind = FFThumbnailKindVideo;
    else if ([ext isEqualToString:@"pdf"])
        kind = FFThumbnailKindPDF;
    else {
        kind = FFThumbnailKindNone;
        [self finishForKey:key image:nil];
        return;
    }

    dispatch_async(self.workQueue, ^{
        // Disk cache first: cheaper than re-generating.
        NSString *diskPath = [[FFThumbnailDiskRoot()
            stringByAppendingPathComponent:FFThumbnailSHA1(key)]
            stringByAppendingPathExtension:@"jpg"];
        UIImage *image = [UIImage imageWithContentsOfFile:diskPath];
        if (!image) {
            image = [self generateForPath:path kind:kind size:size];
            if (image) {
                NSData *jpeg = UIImageJPEGRepresentation(image, 0.8);
                [[NSFileManager defaultManager] createDirectoryAtPath:FFThumbnailDiskRoot()
                    withIntermediateDirectories:YES attributes:nil error:nil];
                [jpeg writeToFile:diskPath atomically:YES];
            }
        }
        if (image) [self.memoryCache setObject:image forKey:key];
        [self finishForKey:key image:image];
    });
}

- (void)finishForKey:(NSString *)key image:(UIImage *)image
{
    [self.lock lock];
    NSArray *pending = [self.inFlight[key] copy];
    [self.inFlight removeObjectForKey:key];
    [self.lock unlock];
    for (void (^completion)(UIImage *) in pending) {
        if (completion) completion(image);
    }
}

- (UIImage *)generateForPath:(NSString *)path kind:(FFThumbnailKind)kind size:(CGSize)size
{
    @autoreleasepool {
        CGFloat scale = MAX(UIScreen.mainScreen.scale, 2.0);
        NSInteger pixels = (NSInteger)MAX(size.width, size.height) * scale;
        switch (kind) {
            case FFThumbnailKindImage:
                return [self imageThumbnail:path pixels:pixels];
            case FFThumbnailKindVideo:
                return [self videoThumbnail:path pixels:pixels];
            case FFThumbnailKindPDF:
                return [self pdfThumbnail:path size:size];
            case FFThumbnailKindNone:
                return nil;
        }
    }
    return nil;
}

- (UIImage *)imageThumbnail:(NSString *)path pixels:(NSInteger)pixels
{
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!source) return nil;
    NSDictionary *options = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize: @(pixels),
        (id)kCGImageSourceShouldCacheImmediately: @YES,
    };
    CGImageRef thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!thumbnail) return nil;
    UIImage *image = [UIImage imageWithCGImage:thumbnail];
    CGImageRelease(thumbnail);
    return image;
}

- (UIImage *)videoThumbnail:(NSString *)path pixels:(NSInteger)pixels
{
    AVURLAsset *asset = [AVURLAsset assetWithURL:[NSURL fileURLWithPath:path]];
    AVAssetImageGenerator *generator = [[AVAssetImageGenerator alloc] initWithAsset:asset];
    generator.appliesPreferredTrackTransform = YES;
    generator.maximumSize = CGSizeMake(pixels, pixels);
    NSError *error = nil;
    CGImageRef frame = [generator copyCGImageAtTime:kCMTimeZero
        actualTime:NULL error:&error];
    if (!frame) {
        FFLogTag(@"Thumbnail", @"video frame FAIL path=%@ error=%@", path, error);
        return nil;
    }
    UIImage *image = [UIImage imageWithCGImage:frame];
    CGImageRelease(frame);
    return image;
}

- (UIImage *)pdfThumbnail:(NSString *)path size:(CGSize)size
{
    PDFDocument *document = [[PDFDocument alloc] initWithURL:[NSURL fileURLWithPath:path]];
    if (!document || document.pageCount == 0) return nil;
    PDFPage *page = [document pageAtIndex:0];
    // Size in points; PDF page thumbnails are retina-independent.
    return [page thumbnailOfSize:size forBox:kPDFDisplayBoxMediaBox];
}

- (void)clearCaches
{
    [self.memoryCache removeAllObjects];
    dispatch_async(self.workQueue, ^{
        NSError *error = nil;
        [[NSFileManager defaultManager] removeItemAtPath:FFThumbnailDiskRoot() error:&error];
        if (error)
            FFLogTag(@"Thumbnail", @"cache clear FAIL error=%@", error);
        else
            FFLogTag(@"Thumbnail", @"cache cleared");
    });
}

- (unsigned long long)diskCacheSize
{
    NSFileManager *manager = NSFileManager.defaultManager;
    NSArray *children = [manager contentsOfDirectoryAtPath:FFThumbnailDiskRoot() error:nil];
    unsigned long long total = 0;
    for (NSString *name in children ?: @[]) {
        NSString *path = [FFThumbnailDiskRoot() stringByAppendingPathComponent:name];
        NSNumber *size = [[manager attributesOfItemAtPath:path error:nil] objectForKey:NSFileSize];
        if (size) total += size.unsignedLongLongValue;
    }
    return total;
}

@end
