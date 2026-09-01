#import "FFThumbnailService.h"
#import "FFIPAMetadataService.h"
#import "FFLogger.h"

#import <AVFoundation/AVFoundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <ImageIO/ImageIO.h>
#import <PDFKit/PDFKit.h>
#import <UIKit/UIKit.h>

static const unsigned long long kFFThumbnailDiskSoftLimit = 256ULL * 1024ULL * 1024ULL;
static const unsigned long long kFFThumbnailDiskHardLimit = 512ULL * 1024ULL * 1024ULL;

@interface FFThumbnailService ()
@property(nonatomic, strong) NSCache<NSString *, UIImage *> *memoryCache;
@property(nonatomic, strong) dispatch_queue_t workQueue;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray *> *inFlight;
@property(nonatomic, strong) NSLock *lock;
@end

@implementation FFThumbnailService

+ (instancetype)sharedService
{
    static FFThumbnailService *service;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ service = [FFThumbnailService new]; });
    return service;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _memoryCache = [NSCache new];
        _memoryCache.countLimit = 600;
        _memoryCache.totalCostLimit = 48 * 1024 * 1024;
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        _workQueue = dispatch_queue_create("ff.thumbnails", attr);
        _inFlight = [NSMutableDictionary dictionary];
        _lock = [NSLock new];
        dispatch_async(_workQueue, ^{ [self trimDiskCacheIfNeeded]; });
    }
    return self;
}

static NSString *FFThumbnailKey(NSString *path, CGSize size)
{
    NSString *fingerprint = @"?";
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    if (attrs) {
        NSDate *mtime = attrs[NSFileModificationDate];
        NSNumber *fileSize = attrs[NSFileSize];
        fingerprint = [NSString stringWithFormat:@"%@-%@",
            mtime ? @((long long)mtime.timeIntervalSince1970) : @"-", fileSize ?: @"-"];
    }
    return [NSString stringWithFormat:@"%@#%.0fx%.0f#%@", path, size.width, size.height, fingerprint];
}

static NSString *FFThumbnailSHA1(NSString *input)
{
    NSData *data = [input dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t digest[CC_SHA1_DIGEST_LENGTH] = {0};
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *result = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA1_DIGEST_LENGTH; index++) [result appendFormat:@"%02x", digest[index]];
    return result;
}

static NSString *FFThumbnailDiskRoot(void)
{
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return [caches stringByAppendingPathComponent:@"Thumbnails"];
}

- (void)thumbnailForPath:(NSString *)path size:(CGSize)size completion:(void (^)(UIImage *))completion
{
    if (!path.length || !completion) return;
    NSString *key = FFThumbnailKey(path, size);
    UIImage *cached = [self.memoryCache objectForKey:key];
    if (cached) { completion(cached); return; }

    [self.lock lock];
    NSMutableArray *pending = self.inFlight[key];
    if (pending) {
        [pending addObject:[completion copy]];
        [self.lock unlock];
        return;
    }
    self.inFlight[key] = [NSMutableArray arrayWithObject:[completion copy]];
    [self.lock unlock];

    NSString *ext = path.pathExtension.lowercaseString;
    FFThumbnailKind kind = FFThumbnailKindNone;
    if ([@[@"png", @"jpg", @"jpeg", @"gif", @"heic", @"webp", @"tiff", @"bmp"] containsObject:ext]) kind = FFThumbnailKindImage;
    else if ([@[@"mp4", @"mov", @"m4v", @"avi", @"mkv"] containsObject:ext]) kind = FFThumbnailKindVideo;
    else if ([ext isEqualToString:@"pdf"]) kind = FFThumbnailKindPDF;
    else if ([ext isEqualToString:@"ipa"]) kind = FFThumbnailKindIPA;
    else { [self finishForKey:key image:nil]; return; }

    dispatch_async(self.workQueue, ^{
        BOOL preserveAlpha = kind == FFThumbnailKindIPA;
        NSString *diskExt = preserveAlpha ? @"png" : @"jpg";
        NSString *diskPath = [[[FFThumbnailDiskRoot() stringByAppendingPathComponent:FFThumbnailSHA1(key)]
            stringByAppendingPathExtension:diskExt] copy];
        UIImage *image = [UIImage imageWithContentsOfFile:diskPath];
        if (image) {
            [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate: NSDate.date}
                ofItemAtPath:diskPath error:nil];
        } else {
            image = [self generateForPath:path kind:kind size:size];
            if (image) {
                NSData *encoded = preserveAlpha ? UIImagePNGRepresentation(image) : UIImageJPEGRepresentation(image, 0.8);
                [NSFileManager.defaultManager createDirectoryAtPath:FFThumbnailDiskRoot()
                    withIntermediateDirectories:YES attributes:nil error:nil];
                [encoded writeToFile:diskPath atomically:YES];
                [self trimDiskCacheIfNeeded];
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
    for (void (^completion)(UIImage *) in pending) if (completion) completion(image);
}

- (UIImage *)generateForPath:(NSString *)path kind:(FFThumbnailKind)kind size:(CGSize)size
{
    @autoreleasepool {
        CGFloat scale = MAX(UIScreen.mainScreen.scale, 2.0);
        NSInteger pixels = (NSInteger)MAX(size.width, size.height) * scale;
        switch (kind) {
            case FFThumbnailKindImage: return [self imageThumbnail:path pixels:pixels];
            case FFThumbnailKindVideo: return [self videoThumbnail:path pixels:pixels];
            case FFThumbnailKindPDF: return [self pdfThumbnail:path size:size];
            case FFThumbnailKindIPA: {
                NSError *error = nil;
                FFIPAMetadata *metadata = [[FFIPAMetadataService sharedService]
                    metadataForIPAAtPath:path error:&error];
                if (!metadata.icon && error) FFLogTag(@"Thumbnail", @"ipa icon FAIL path=%@ error=%@", path, error);
                return metadata.icon;
            }
            case FFThumbnailKindNone: return nil;
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
    CGImageRef frame = [generator copyCGImageAtTime:kCMTimeZero actualTime:NULL error:&error];
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
    return [[document pageAtIndex:0] thumbnailOfSize:size forBox:kPDFDisplayBoxMediaBox];
}

- (void)trimDiskCacheIfNeeded
{
    NSString *root = FFThumbnailDiskRoot();
    NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil];
    if (!names.count) return;

    NSMutableArray<NSDictionary *> *files = [NSMutableArray arrayWithCapacity:names.count];
    unsigned long long total = 0;
    for (NSString *name in names) {
        NSString *path = [root stringByAppendingPathComponent:name];
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        NSNumber *size = attrs[NSFileSize];
        if (!size) continue;
        unsigned long long bytes = size.unsignedLongLongValue;
        total += bytes;
        [files addObject:@{
            @"path": path,
            @"size": @(bytes),
            @"date": attrs[NSFileModificationDate] ?: attrs[NSFileCreationDate] ?: NSDate.distantPast,
        }];
    }
    if (total <= kFFThumbnailDiskHardLimit) return;

    [files sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"date"] compare:b[@"date"]];
    }];
    NSUInteger removed = 0;
    for (NSDictionary *row in files) {
        if (total <= kFFThumbnailDiskSoftLimit) break;
        NSError *error = nil;
        if ([NSFileManager.defaultManager removeItemAtPath:row[@"path"] error:&error]) {
            unsigned long long bytes = [row[@"size"] unsignedLongLongValue];
            total = bytes > total ? 0 : total - bytes;
            removed++;
        } else {
            FFLogTag(@"Thumbnail", @"disk trim FAIL path=%@ error=%@", row[@"path"], error);
        }
    }
    FFLogTag(@"Thumbnail", @"disk trim removed=%lu remaining=%llu",
        (unsigned long)removed, total);
}

- (void)clearCaches
{
    [self.memoryCache removeAllObjects];
    [[FFIPAMetadataService sharedService] clearCache];
    dispatch_async(self.workQueue, ^{
        NSString *root = FFThumbnailDiskRoot();
        BOOL isDirectory = NO;
        if (![NSFileManager.defaultManager fileExistsAtPath:root isDirectory:&isDirectory]) return;
        NSError *error = nil;
        [NSFileManager.defaultManager removeItemAtPath:root error:&error];
        if (error) FFLogTag(@"Thumbnail", @"cache clear FAIL error=%@", error);
    });
}

- (unsigned long long)diskCacheSize
{
    NSFileManager *manager = NSFileManager.defaultManager;
    NSArray *children = [manager contentsOfDirectoryAtPath:FFThumbnailDiskRoot() error:nil];
    unsigned long long total = 0;
    for (NSString *name in children ?: @[]) {
        NSString *path = [FFThumbnailDiskRoot() stringByAppendingPathComponent:name];
        NSNumber *size = [manager attributesOfItemAtPath:path error:nil][NSFileSize];
        if (size) total += size.unsignedLongLongValue;
    }
    return total;
}

@end