#import "FFPreviewRouter.h"
#import "FFBrowserViewController.h"   // FFEntry + plist/text editor VCs
#import "FFPlistEditorViewController.h"
#import "FFTextEditorViewController.h"
#import "FFPdfPreviewViewController.h"
#import "FFLogger.h"

#import <AVKit/AVKit.h>

@interface FFPreviewShareTarget : NSObject
@property(nonatomic, strong) FFEntry *item;
@property(nonatomic, copy) NSString *text;
@property(nonatomic, weak) UINavigationController *nav;
- (void)shareItem:(id)sender;
- (void)shareText:(id)sender;
@end

@implementation FFPreviewRouter

+ (BOOL)previewItem:(FFEntry *)item navigationController:(UINavigationController *)nav
{
    if (!item || !nav) return NO;
    NSString *ext = item.name.pathExtension.lowercaseString;
    static NSSet<NSString *> *images;
    static NSSet<NSString *> *videos;
    static NSSet<NSString *> *audios;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        images = [NSSet setWithArray:@[@"png", @"jpg", @"jpeg", @"gif", @"heic",
            @"webp", @"tiff", @"bmp"]];
        videos = [NSSet setWithArray:@[@"mp4", @"mov", @"m4v", @"avi", @"mkv"]];
        audios = [NSSet setWithArray:@[@"mp3", @"m4a", @"wav", @"aac", @"caf", @"flac"]];
    });

    if ([images containsObject:ext]) {
        [self presentImage:item nav:nav];
        return YES;
    }
    if ([videos containsObject:ext] || [audios containsObject:ext]) {
        [self presentMedia:item nav:nav];
        return YES;
    }
    if ([ext isEqualToString:@"pdf"]) {
        FFPdfPreviewViewController *viewer =
            [[FFPdfPreviewViewController alloc] initWithPath:item.path];
        [nav pushViewController:viewer animated:YES];
        return YES;
    }
    [self presentData:item nav:nav];
    return YES;
}

#pragma mark - Image

+ (void)presentImage:(FFEntry *)item nav:(UINavigationController *)nav
{
    UIImage *image = [UIImage imageWithContentsOfFile:item.path];
    if (!image) {
        [self flash:@"图片解码失败" in:nav];
        return;
    }
    UIViewController *viewer = [UIViewController new];
    viewer.title = item.name;
    UIImageView *imageView = [[UIImageView alloc] initWithFrame:viewer.view.bounds];
    imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    imageView.contentMode = UIViewContentModeScaleAspectFit;
    imageView.backgroundColor = [UIColor systemBackgroundColor];
    imageView.image = image;
    imageView.userInteractionEnabled = YES;
    [viewer.view addSubview:imageView];
    UIBarButtonItem *share = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:nil action:nil];
    FFPreviewShareTarget *target = [self shareTargetForItem:item];
    target.nav = nav;
    share.target = target;
    share.action = @selector(shareItem:);
    viewer.navigationItem.rightBarButtonItem = share;
    [nav pushViewController:viewer animated:YES];
}

#pragma mark - Media

+ (void)presentMedia:(FFEntry *)item nav:(UINavigationController *)nav
{
    NSURL *url = [NSURL fileURLWithPath:item.path];
    AVPlayerViewController *player = [AVPlayerViewController new];
    player.player = [AVPlayer playerWithURL:url];
    [nav pushViewController:player animated:YES];
    [player.player play];
}

#pragma mark - Data (plist / text / hex)

+ (void)presentData:(FFEntry *)item nav:(UINavigationController *)nav
{
    // 大文件不能一次性读入内存：只读前 4MB 用于类型识别与文本采样；
    // 文本预览交给文本编辑器（其自身分段），hex 视图只显示前 1MB。
    unsigned long long fileSize = 0;
    NSDictionary *attrs = [NSFileManager.defaultManager
        attributesOfItemAtPath:item.path error:nil];
    fileSize = [attrs[NSFileSize] unsignedLongLongValue];
    BOOL large = fileSize > 4 * 1024 * 1024;
    NSData *data = nil;
    if (large) {
        NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:item.path];
        data = [handle readDataOfLength:4 * 1024 * 1024];
        [handle closeFile];
    } else {
        data = [NSData dataWithContentsOfFile:item.path];
    }
    if (!data) {
        [self flash:@"读取文件失败" in:nav];
        return;
    }
    NSDictionary *plist = nil;
    if (data.length > 0) {
        NSPropertyListFormat format = NSPropertyListBinaryFormat_v1_0;
        plist = [NSPropertyListSerialization propertyListWithData:data
            options:NSPropertyListImmutable format:&format error:nil];
    }
    if ([plist isKindOfClass:NSDictionary.class] || [plist isKindOfClass:NSArray.class]) {
        FFPlistEditorViewController *editor =
            [[FFPlistEditorViewController alloc] initWithPath:item.path];
        [nav pushViewController:editor animated:YES];
        return;
    }
    NSString *candidate = [self stringFromData:data];
    if (candidate && [self looksTextual:candidate] && !large) {
        FFTextEditorViewController *editor =
            [[FFTextEditorViewController alloc] initWithPath:item.path];
        [nav pushViewController:editor animated:YES];
        return;
    }
    if (candidate && [self looksTextual:candidate] && large) {
        // 大文本：显示前 1MB 的只读文本预览。
        NSString *preview = [candidate substringToIndex:MIN(candidate.length,
            (NSUInteger)1024 * 1024)];
        preview = [preview stringByAppendingFormat:
            @"\n\n… 文件较大（%@），仅显示前 1 MB，只读预览。",
            [NSByteCountFormatter stringFromByteCount:(long long)fileSize
                countStyle:NSByteCountFormatterCountStyleFile]];
        [self presentText:item.name body:preview navigationController:nav];
        return;
    }
    NSString *text = [self hexdump:data maxBytes:data.length <= 1024 * 1024
        ? data.length : 1024 * 1024];
    [self presentText:item.name body:text navigationController:nav];
}

+ (NSString *)stringFromData:(NSData *)data
{
    NSString *utf8 = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (utf8) return utf8;
    NSString *utf16 = [[NSString alloc] initWithData:data encoding:NSUTF16StringEncoding];
    if (utf16) return utf16;
    NSString *isoLatin1 = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    return isoLatin1;
}

// 文本识别基于采样：只检查前 4096 字节，不拿整个文件长度比较。
+ (BOOL)looksTextual:(NSString *)candidate
{
    if (candidate.length == 0) return YES;
    NSUInteger printable = 0;
    NSUInteger sample = MIN(candidate.length, (NSUInteger)4096);
    for (NSUInteger i = 0; i < sample; i++) {
        unichar c = [candidate characterAtIndex:i];
        if (c >= 0x20 && c != 0x7F) printable++;
    }
    return printable * 10 >= sample * 9;
}

+ (NSString *)hexdump:(NSData *)data maxBytes:(NSUInteger)maxBytes
{
    const uint8_t *bytes = data.bytes;
    NSUInteger count = MIN(data.length, maxBytes);
    NSMutableString *result = [NSMutableString string];
    for (NSUInteger offset = 0; offset < count; offset += 16) {
        [result appendFormat:@"%08lx  ", (unsigned long)offset];
        NSUInteger lineLength = MIN((NSUInteger)16, count - offset);
        for (NSUInteger i = 0; i < 16; i++) {
            if (i < lineLength) [result appendFormat:@"%02x ", bytes[offset + i]];
            else [result appendString:@"   "];
            if (i == 7) [result appendString:@" "];
        }
        [result appendString:@" |"];
        for (NSUInteger i = 0; i < lineLength; i++) {
            uint8_t c = bytes[offset + i];
            [result appendFormat:@"%c", (c >= 0x20 && c != 0x7F) ? c : '.'];
        }
        [result appendString:@"|\n"];
    }
    if (data.length > maxBytes)
        [result appendFormat:@"\n… 已截断：共 %lu 字节，仅显示前 %lu 字节\n",
            (unsigned long)maxBytes, (unsigned long)data.length];
    return result;
}

#pragma mark - Text viewer

+ (void)presentText:(NSString *)title body:(NSString *)body
    navigationController:(UINavigationController *)nav
{
    UIViewController *viewer = [UIViewController new];
    viewer.title = title;
    UITextView *textView = [[UITextView alloc] initWithFrame:viewer.view.bounds];
    textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    textView.editable = NO;
    textView.selectable = YES;
    textView.font = [UIFont fontWithName:@"Menlo" size:12];
    textView.text = body;
    textView.backgroundColor = [UIColor systemBackgroundColor];
    [viewer.view addSubview:textView];
    UIBarButtonItem *share = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:nil action:nil];
    FFPreviewShareTarget *target = [self shareTextTarget:body];
    target.nav = nav;
    share.target = target;
    share.action = @selector(shareText:);
    viewer.navigationItem.rightBarButtonItem = share;
    [nav pushViewController:viewer animated:YES];
}

#pragma mark - Share targets (retain the item/text without a VC)

+ (id)shareTargetForItem:(FFEntry *)item
{
    FFPreviewShareTarget *target = [FFPreviewShareTarget new];
    target.item = item;
    return target;
}

+ (id)shareTextTarget:(NSString *)text
{
    FFPreviewShareTarget *target = [FFPreviewShareTarget new];
    target.text = text;
    return target;
}

+ (void)flash:(NSString *)message in:(UINavigationController *)nav
{
    UIViewController *top = nav.topViewController;
    if (!top) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [top presentViewController:alert animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.2 * NSEC_PER_SEC),
            dispatch_get_main_queue(), ^{
                [alert dismissViewControllerAnimated:YES completion:nil];
            });
    }];
}

@end

#pragma mark - Share target

@implementation FFPreviewShareTarget

- (void)shareItem:(id)sender
{
    if (!self.item.path) return;
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:@[[NSURL fileURLWithPath:self.item.path]]
        applicationActivities:nil];
    activity.popoverPresentationController.barButtonItem =
        (UIBarButtonItem *)sender;
    UIViewController *presenter = self.nav.topViewController;
    if (presenter) [presenter presentViewController:activity animated:YES completion:nil];
}

- (void)shareText:(id)sender
{
    if (!self.text) return;
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:@[self.text] applicationActivities:nil];
    activity.popoverPresentationController.barButtonItem =
        (UIBarButtonItem *)sender;
    UIViewController *presenter = self.nav.topViewController;
    if (presenter) [presenter presentViewController:activity animated:YES completion:nil];
}

@end
