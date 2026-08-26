#import "FFViewerRegistry.h"

#import "FFPlistEditorViewController.h"
#import "FFTextEditorViewController.h"
#import "FFPdfPreviewViewController.h"
#import "FFPdfReaderViewController.h"
#import "FFQuickLookViewController.h"
#import "FFDocxViewerViewController.h"
#import "FFWebViewerViewController.h"
#import "FFHexEditorViewController.h"
#import "FFSQLiteBrowserViewController.h"
#import "FFArchiveBrowserViewController.h"
#import "FFIPaInstallerViewController.h"
#import "FFPreviewRouter.h"
#import "FFLogger.h"

#import <objc/runtime.h>
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>

@interface FFViewerInfo ()
@property(nonatomic, copy, readwrite) NSString *viewerID;
@property(nonatomic, copy, readwrite) NSString *displayName;
@property(nonatomic, copy, readwrite) NSString *iconName;
@property(nonatomic, copy, readwrite) NSString *summary;
@end
@implementation FFViewerInfo
@end

#pragma mark - Image

@interface FFImageZoomView : UIView <UIScrollViewDelegate>
@property(nonatomic, strong) UIImageView *imageView;
- (instancetype)initWithImage:(UIImage *)image;
@end

@implementation FFImageZoomView
- (instancetype)initWithImage:(UIImage *)image
{
    self = [super init];
    if (self) {
        UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:self.bounds];
        scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        scrollView.backgroundColor = UIColor.systemBackgroundColor;
        scrollView.delegate = self;
        scrollView.minimumZoomScale = 1.0;
        scrollView.maximumZoomScale = 8.0;
        [self addSubview:scrollView];

        _imageView = [[UIImageView alloc] initWithImage:image];
        _imageView.contentMode = UIViewContentModeScaleAspectFit;
        _imageView.frame = scrollView.bounds;
        _imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _imageView.userInteractionEnabled = YES;
        [scrollView addSubview:_imageView];

        UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(doubleTapped:)];
        doubleTap.numberOfTapsRequired = 2;
        [_imageView addGestureRecognizer:doubleTap];
    }
    return self;
}
- (void)layoutSubviews
{
    [super layoutSubviews];
    UIScrollView *scrollView = (UIScrollView *)self.subviews.firstObject;
    if (scrollView && self.imageView.image) {
        CGSize bounds = scrollView.bounds.size, image = self.imageView.image.size;
        if (bounds.width > 0 && bounds.height > 0 && image.width > 0 && image.height > 0) {
            CGFloat scale = MIN(bounds.width / image.width, bounds.height / image.height);
            self.imageView.frame = CGRectMake(0, 0, image.width * scale, image.height * scale);
            scrollView.contentSize = self.imageView.frame.size;
        }
    }
}
- (UIView *)viewForZoomingInScrollView:(__unused UIScrollView *)scrollView { return self.imageView; }
- (void)doubleTapped:(UITapGestureRecognizer *)gesture
{
    UIScrollView *scrollView = (UIScrollView *)gesture.view.superview;
    if (scrollView.zoomScale > scrollView.minimumZoomScale + 0.01) {
        [scrollView setZoomScale:scrollView.minimumZoomScale animated:YES];
        return;
    }
    CGPoint center = [gesture locationInView:gesture.view];
    CGFloat target = MIN(scrollView.maximumZoomScale, 3.0);
    CGRect rect = CGRectMake(center.x - scrollView.bounds.size.width / target / 2,
                             center.y - scrollView.bounds.size.height / target / 2,
                             scrollView.bounds.size.width / target,
                             scrollView.bounds.size.height / target);
    [scrollView zoomToRect:rect animated:YES];
}
@end

@interface FFFileShareTarget : NSObject
@property(nonatomic, copy) NSURL *fileURL;
@property(nonatomic, weak) UINavigationController *nav;
- (void)share:(UIBarButtonItem *)sender;
@end
@implementation FFFileShareTarget
- (void)share:(UIBarButtonItem *)sender
{
    if (!self.fileURL) return;
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[self.fileURL] applicationActivities:nil];
    activity.popoverPresentationController.barButtonItem = sender;
    UIViewController *presenter = self.nav.topViewController;
    if (presenter) [presenter presentViewController:activity animated:YES completion:nil];
}
@end

#pragma mark - Media

@interface FFMediaPlayerViewController : AVPlayerViewController
@end
@implementation FFMediaPlayerViewController
- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSError *error = nil;
    if (![session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeMoviePlayback options:0 error:&error]) {
        FFLogTag(@"Media", @"audio session category failed: %@", error.localizedDescription ?: @"unknown");
        return;
    }
    error = nil;
    if (![session setActive:YES error:&error]) FFLogTag(@"Media", @"audio session activate failed: %@", error.localizedDescription ?: @"unknown");
}
- (void)dealloc
{
    NSError *error = nil;
    [AVAudioSession.sharedInstance setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&error];
    if (error) FFLogTag(@"Media", @"audio session deactivate failed: %@", error.localizedDescription ?: @"unknown");
}
@end

@interface FFViewerRegistry ()
@property(nonatomic, strong) NSArray<FFViewerInfo *> *viewers;
@property(nonatomic, weak) UINavigationController *currentNav;
@end

@implementation FFViewerRegistry
+ (instancetype)sharedRegistry
{
    static FFViewerRegistry *registry;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ registry = [FFViewerRegistry new]; });
    return registry;
}
- (instancetype)init
{
    self = [super init];
    if (self) {
        NSArray *specs = @[
            @[@"image", @"图片浏览器", @"photo", @"PNG/JPG/GIF/HEIC/WEBP/BMP/TIFF/ICO/CAR"],
            @[@"quicklook", @"快速查看", @"square.on.square.intersection.dashed", @"系统 Quick Look：Office、PDF、iWork 与无专用查看器文件的首选预览"],
            @[@"docx", @"Word 阅读器", @"doc.text", @"DOCX/DOCM/DOTX/DOTM 专用阅读；其余办公文件使用系统 Quick Look"],
            @[@"web", @"Web Viewer", @"safari", @"HTML/HTM 本地页面；.url/.webloc 网页快捷方式"],
            @[@"plist", @"属性表编辑器", @"list.bullet.rectangle", @"结构化编辑 plist（XML/二进制）"],
            @[@"text", @"文本编辑器", @"doc.plaintext", @"txt/log/md/json/xml/源码等文本；脚本仅按文本打开，不执行"],
            @[@"sqlite", @"SQLite3 编辑器", @"cylinder.split.1x2", @"sqlite/sqlite3/sqlitedb/db：表、视图、索引、分页浏览与 SQL 查询（只读）"],
            @[@"installer", @"IPA 安装器", @"arrow.down.app", @"解析 IPA 应用信息；能否安装取决于运行环境权限"],
            @[@"archive", @"ZIP 浏览器", @"archivebox", @"ZIP/IPA 包内浏览与提取。部分支持：TAR/GZ/7z/RAR/XZ/BZ2 当前构建无法解析，仅明确提示"],
            @[@"hex", @"十六进制编辑器", @"waveform.path.ecg", @"分页式 OFFSET/HEX/ASCII 查看，支持字节修改、保存与取消"],
            @[@"media", @"媒体播放器", @"play.circle", @"AVPlayer 播放音视频（MP3/WAV/FLAC/MOV/MP4/MKV 等）"],
            @[@"pdf", @"PDF 阅读器", @"doc.richtext", @"PDFKit 阅读器（可手动关联；默认 PDF 使用系统 Quick Look）"],
        ];
        NSMutableArray *built = [NSMutableArray array];
        for (NSArray *spec in specs) {
            FFViewerInfo *info = [FFViewerInfo new];
            info.viewerID = spec[0]; info.displayName = spec[1]; info.iconName = spec[2]; info.summary = spec[3];
            [built addObject:info];
        }
        _viewers = built;
    }
    return self;
}
- (NSArray<FFViewerInfo *> *)allViewers { return self.viewers; }
- (FFViewerInfo *)viewerForID:(NSString *)viewerID
{
    for (FFViewerInfo *info in self.viewers) if ([info.viewerID isEqualToString:viewerID]) return info;
    return nil;
}
- (BOOL)viewerAvailable:(NSString *)viewerID path:(NSString *)path reason:(NSString **)reason
{
    if (![self viewerForID:viewerID]) { if (reason) *reason = @"未知查看器"; return NO; }
    if (path && ![NSFileManager.defaultManager fileExistsAtPath:path]) { if (reason) *reason = @"文件不存在"; return NO; }
    if (reason) *reason = nil;
    return YES;
}
- (BOOL)openPath:(NSString *)path title:(NSString *)title viewerID:(NSString *)viewerID navigationController:(UINavigationController *)nav
{
    if (!nav) return NO;
    NSString *unavailable = nil;
    if (![self viewerAvailable:viewerID path:path reason:&unavailable]) {
        FFLogTag(@"Viewer", @"unavailable viewer=%@ path=%@ (%@)", viewerID, path, unavailable ?: @"?");
        [FFPreviewRouter toastOnNav:nav message:unavailable ?: @"该查看器不可用"];
        return NO;
    }
    self.currentNav = nav;
    UIViewController *viewer = [self viewControllerForViewerID:viewerID path:path title:title];
    if (!viewer) { FFLogTag(@"Viewer", @"build FAILED viewer=%@ path=%@", viewerID, path); return NO; }
    viewer.title = title.length ? title : path.lastPathComponent;
    [nav pushViewController:viewer animated:YES];
    FFLogTag(@"Viewer", @"open viewer=%@ path=%@", viewerID, path);
    return YES;
}
- (nullable UIViewController *)viewControllerForViewerID:(NSString *)viewerID path:(NSString *)path title:(NSString *)title
{
    if ([viewerID isEqualToString:@"image"]) return [self imageViewerAtPath:path title:title];
    if ([viewerID isEqualToString:@"media"]) return [self mediaViewerAtPath:path];
    if ([viewerID isEqualToString:@"plist"]) return [[FFPlistEditorViewController alloc] initWithPath:path];
    if ([viewerID isEqualToString:@"text"]) return [[FFTextEditorViewController alloc] initWithPath:path];
    if ([viewerID isEqualToString:@"pdf"]) return [[FFPdfReaderViewController alloc] initWithPath:path];
    if ([viewerID isEqualToString:@"quicklook"]) return [[FFQuickLookViewController alloc] initWithFilePath:path];
    if ([viewerID isEqualToString:@"docx"]) return [[FFDocxViewerViewController alloc] initWithFilePath:path];
    if ([viewerID isEqualToString:@"web"]) return [[FFWebViewerViewController alloc] initWithFilePath:path];
    if ([viewerID isEqualToString:@"sqlite"]) return [[FFSQLiteBrowserViewController alloc] initWithDatabasePath:path];
    if ([viewerID isEqualToString:@"hex"]) return [[FFHexEditorViewController alloc] initWithFilePath:path];
    if ([viewerID isEqualToString:@"archive"]) return [[FFArchiveBrowserViewController alloc] initWithArchivePath:path];
    if ([viewerID isEqualToString:@"installer"]) return [[FFIPaInstallerViewController alloc] initWithIpaPath:path];
    return nil;
}
- (UIViewController *)imageViewerAtPath:(NSString *)path title:(NSString *)title
{
    UIImage *image = [UIImage imageWithContentsOfFile:path];
    if (!image) return nil;
    UIViewController *viewer = [UIViewController new];
    FFImageZoomView *zoomView = [[FFImageZoomView alloc] initWithImage:image];
    zoomView.frame = viewer.view.bounds;
    zoomView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [viewer.view addSubview:zoomView];
    FFFileShareTarget *target = [FFFileShareTarget new];
    target.fileURL = [NSURL fileURLWithPath:path]; target.nav = self.currentNav;
    UIBarButtonItem *share = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:target action:@selector(share:)];
    objc_setAssociatedObject(share, "shareTarget", target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    viewer.navigationItem.rightBarButtonItem = share;
    return viewer;
}
- (UIViewController *)mediaViewerAtPath:(NSString *)path
{
    FFMediaPlayerViewController *player = [FFMediaPlayerViewController new];
    player.player = [AVPlayer playerWithURL:[NSURL fileURLWithPath:path]];
    return player;
}
@end
