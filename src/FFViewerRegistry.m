#import "FFViewerRegistry.h"

#import "FFPlistEditorViewController.h"
#import "FFTextEditorViewController.h"
#import "FFPdfPreviewViewController.h"
#import "FFQuickLookViewController.h"
#import "FFWebViewerViewController.h"
#import "FFHexEditorViewController.h"
#import "FFSQLiteBrowserViewController.h"
#import "FFArchiveBrowserViewController.h"
#import "FFIPaInstallerViewController.h"
#import "FFPreviewRouter.h"
#import "FFLogger.h"

#import <AVKit/AVKit.h>

// Private readwrite mirrors of the metadata properties.
@interface FFViewerInfo ()
@property(nonatomic, copy, readwrite) NSString *viewerID;
@property(nonatomic, copy, readwrite) NSString *displayName;
@property(nonatomic, copy, readwrite) NSString *iconName;
@property(nonatomic, copy, readwrite) NSString *summary;
@end

@implementation FFViewerInfo
@end

#pragma mark - Image

// Apple PhotoScroller 模式（各开源图片浏览器的通用写法）：
// UIScrollView 捏合缩放 + 双击在 1x/3x 之间切换。
@interface FFImageZoomView : UIView <UIScrollViewDelegate>
@property(nonatomic, strong) UIImageView *imageView;
@property(nonatomic, strong) UIScrollView *scrollViewRef;
- (instancetype)initWithImage:(UIImage *)image;
@end

@implementation FFImageZoomView

- (instancetype)initWithImage:(UIImage *)image
{
    self = [super init];
    if (self) {
        UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:self.bounds];
        scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
            UIViewAutoresizingFlexibleHeight;
        scrollView.backgroundColor = UIColor.systemBackgroundColor;
        scrollView.delegate = self;
        scrollView.minimumZoomScale = 1.0;
        scrollView.maximumZoomScale = 8.0;
        [self addSubview:scrollView];

        _imageView = [[UIImageView alloc] initWithImage:image];
        _imageView.contentMode = UIViewContentModeScaleAspectFit;
        _imageView.frame = scrollView.bounds;
        _imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
            UIViewAutoresizingFlexibleHeight;
        _imageView.userInteractionEnabled = YES;
        [scrollView addSubview:_imageView];

        UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(doubleTapped:)];
        doubleTap.numberOfTapsRequired = 2;
        doubleTap.numberOfTouchesRequired = 1;
        [_imageView addGestureRecognizer:doubleTap];
    }
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    // 首次布局时让图片以 aspect-fit 尺寸充满滚动区。
    UIScrollView *scrollView = (UIScrollView *)self.subviews.firstObject;
    if (scrollView && self.imageView.image) {
        CGSize bounds = scrollView.bounds.size;
        CGSize image = self.imageView.image.size;
        if (bounds.width > 0 && bounds.height > 0 && image.width > 0 && image.height > 0) {
            CGFloat scale = MIN(bounds.width / image.width, bounds.height / image.height);
            self.imageView.frame = CGRectMake(0, 0,
                image.width * scale, image.height * scale);
            scrollView.contentSize = self.imageView.frame.size;
        }
    }
}

- (UIView *)viewForZoomingInScrollView:(__unused UIScrollView *)scrollView
{
    return self.imageView;
}

- (void)doubleTapped:(UITapGestureRecognizer *)gesture
{
    UIScrollView *scrollView = (UIScrollView *)gesture.view.superview;
    if (scrollView.zoomScale > scrollView.minimumZoomScale + 0.01) {
        [scrollView setZoomScale:scrollView.minimumZoomScale animated:YES];
        return;
    }
    CGPoint center = [gesture locationInView:gesture.view];
    CGFloat target = MIN(scrollView.maximumZoomScale, 3.0);
    CGFloat width = scrollView.bounds.size.width / target;
    CGFloat height = scrollView.bounds.size.height / target;
    CGRect zoomRect = CGRectMake(center.x - width / 2, center.y - height / 2,
        width, height);
    [scrollView zoomToRect:zoomRect animated:YES];
}

@end

// Retains a file URL for a barButtonItem share action without needing
// a full view controller subclass.
@interface FFFileShareTarget : NSObject
@property(nonatomic, copy) NSURL *fileURL;
- (void)share:(UIBarButtonItem *)sender;
@end

@implementation FFFileShareTarget
- (void)share:(UIBarButtonItem *)sender
{
    if (!self.fileURL) return;
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:@[self.fileURL] applicationActivities:nil];
    activity.popoverPresentationController.barButtonItem = sender;
    // 沿响应链找到所在视图控制器来呈现。
    UIResponder *responder = sender;
    while (responder && ![responder isKindOfClass:UIViewController.class])
        responder = responder.nextResponder;
    if (responder)
        [(UIViewController *)responder presentViewController:activity
            animated:YES completion:nil];
}
@end

@interface FFViewerRegistry ()
@property(nonatomic, strong) NSArray<FFViewerInfo *> *viewers;
@end

@implementation FFViewerRegistry

+ (instancetype)sharedRegistry
{
    static FFViewerRegistry *registry;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        registry = [FFViewerRegistry new];
    });
    return registry;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        // id / 显示名 / SF Symbol / 能力说明（设置页展示，含不支持格式的诚实标注）
        NSArray *specs = @[
            @[@"image",     @"图片浏览器",     @"photo",                 @"PNG/JPG/GIF/HEIC/WEBP/BMP/TIFF/ICO/CAR"],
            @[@"quicklook", @"快速查看",       @"square.on.square.intersection.dashed", @"系统 Quick Look：无专用查看器文件的兜底预览"],
            @[@"web",       @"Web Viewer",     @"safari",                @"HTML/HTM 本地页面；.url/.webloc 网页快捷方式"],
            @[@"plist",     @"属性表编辑器",   @"list.bullet.rectangle", @"结构化编辑 plist（XML/二进制）"],
            @[@"text",      @"文本编辑器",     @"doc.plaintext",         @"txt/log/md/json/xml/源码等文本；脚本仅按文本打开，不执行"],
            @[@"sqlite",    @"SQLite3 编辑器", @"cylinder.split.1x2",    @"sqlite/sqlite3/sqlitedb/db：表、视图、索引、分页浏览与 SQL 查询（只读）"],
            @[@"installer", @"IPA 安装器",     @"arrow.down.app",        @"解析 IPA 应用信息；能否安装取决于运行环境权限"],
            @[@"archive",   @"ZIP 浏览器",     @"archivebox",            @"ZIP/IPA 包内浏览与提取。部分支持：TAR/GZ/7z/RAR/XZ/BZ2 当前构建无法解析，仅明确提示"],
            @[@"hex",       @"十六进制编辑器", @"waveform.path.ecg",     @"分页式 OFFSET/HEX/ASCII 查看，支持字节修改、保存与取消"],
            @[@"media",     @"媒体播放器",     @"play.circle",           @"AVPlayer 播放音视频（MP3/WAV/FLAC/MOV/MP4/MKV 等）"],
            @[@"pdf",       @"PDF 阅读器",     @"doc.richtext",          @"PDFKit 连续滚动、缩略图侧栏、分享"],
        ];
        NSMutableArray<FFViewerInfo *> *built = [NSMutableArray array];
        for (NSArray *spec in specs) {
            FFViewerInfo *info = [FFViewerInfo new];
            info.viewerID = spec[0];
            info.displayName = spec[1];
            info.iconName = spec[2];
            info.summary = spec[3];
            [built addObject:info];
        }
        _viewers = built;
    }
    return self;
}

#pragma mark - Metadata

- (NSArray<FFViewerInfo *> *)allViewers
{
    return self.viewers;
}

- (FFViewerInfo *)viewerForID:(NSString *)viewerID
{
    for (FFViewerInfo *info in self.viewers)
        if ([info.viewerID isEqualToString:viewerID]) return info;
    return nil;
}

#pragma mark - Availability

- (BOOL)viewerAvailable:(NSString *)viewerID path:(NSString *)path
                 reason:(NSString **)reason
{
    if (![self viewerForID:viewerID]) {
        if (reason) *reason = @"未知查看器";
        return NO;
    }
    if (path && ![NSFileManager.defaultManager fileExistsAtPath:path]) {
        if (reason) *reason = @"文件不存在";
        return NO;
    }
    if (reason) *reason = nil;
    return YES;
}

#pragma mark - Open

- (BOOL)openPath:(NSString *)path title:(NSString *)title
        viewerID:(NSString *)viewerID
navigationController:(UINavigationController *)nav
{
    if (!nav) return NO;
    NSString *unavailable = nil;
    if (![[FFViewerRegistry sharedRegistry] viewerAvailable:viewerID path:path reason:&unavailable]) {
        FFLogTag(@"Viewer", @"unavailable viewer=%@ path=%@ (%@)",
            viewerID, path, unavailable ?: @"?");
        [FFPreviewRouter toastOnNav:nav message:unavailable ?: @"该查看器不可用"];
        return NO;
    }
    UIViewController *viewer = [self viewControllerForViewerID:viewerID path:path title:title];
    if (!viewer) {
        // 例：图片解码失败 —— 让调用方走 fallback 而不是推入空页面。
        FFLogTag(@"Viewer", @"build FAILED viewer=%@ path=%@", viewerID, path);
        return NO;
    }
    viewer.title = title.length ? title : path.lastPathComponent;
    [nav pushViewController:viewer animated:YES];
    FFLogTag(@"Viewer", @"open viewer=%@ path=%@", viewerID, path);
    return YES;
}

// Builds the concrete view controller for a viewer ID. Image/media are
// inline; everything else delegates to its own module, which owns loading,
// paging and error reporting.
- (nullable UIViewController *)viewControllerForViewerID:(NSString *)viewerID
                                                    path:(NSString *)path
                                                   title:(__unused NSString *)title
{
    if ([viewerID isEqualToString:@"image"])     return [self imageViewerAtPath:path];
    if ([viewerID isEqualToString:@"media"])     return [self mediaViewerAtPath:path];
    if ([viewerID isEqualToString:@"plist"])     return [[FFPlistEditorViewController alloc] initWithPath:path];
    if ([viewerID isEqualToString:@"text"])      return [[FFTextEditorViewController alloc] initWithPath:path];
    if ([viewerID isEqualToString:@"pdf"])       return [[FFPdfPreviewViewController alloc] initWithPath:path];
    if ([viewerID isEqualToString:@"quicklook"]) return [[FFQuickLookViewController alloc] initWithFilePath:path];
    if ([viewerID isEqualToString:@"web"])       return [[FFWebViewerViewController alloc] initWithFilePath:path];
    if ([viewerID isEqualToString:@"sqlite"])    return [[FFSQLiteBrowserViewController alloc] initWithDatabasePath:path];
    if ([viewerID isEqualToString:@"hex"])       return [[FFHexEditorViewController alloc] initWithFilePath:path];
    if ([viewerID isEqualToString:@"archive"])   return [[FFArchiveBrowserViewController alloc] initWithArchivePath:path];
    if ([viewerID isEqualToString:@"installer"]) return [[FFIPaInstallerViewController alloc] initWithIpaPath:path];
    return nil;
}

#pragma mark - Image

- (UIViewController *)imageViewerAtPath:(NSString *)path
{
    UIImage *image = [UIImage imageWithContentsOfFile:path];
    if (!image) return nil; // caller falls back (e.g. Quick Look)

    UIViewController *viewer = [UIViewController new];
    FFImageZoomView *zoomView = [[FFImageZoomView alloc] initWithImage:image];
    zoomView.frame = viewer.view.bounds;
    zoomView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;
    [viewer.view addSubview:zoomView];

    FFFileShareTarget *target = [FFFileShareTarget new];
    target.fileURL = [NSURL fileURLWithPath:path];
    UIBarButtonItem *share = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                             target:target action:@selector(share:)];
    viewer.navigationItem.rightBarButtonItem = share;
    return viewer;
}

#pragma mark - Media

- (UIViewController *)mediaViewerAtPath:(NSString *)path
{
    AVPlayerViewController *player = [AVPlayerViewController new];
    player.player = [AVPlayer playerWithURL:[NSURL fileURLWithPath:path]];
    return player;
}

@end
