#import "FFViewerRegistry.h"

#import "FFImageViewerViewController.h"
#import "FFViewerActions.h"
#import "FFPlistEditorViewController.h"
#import "FFTextEditorViewController.h"
#import "FFPdfReaderViewController.h"
#import "FFQuickLookViewController.h"
#import "FFSpreadsheetViewController.h"
#import "FFOfficeDocumentViewController.h"
#import "FFWebViewerViewController.h"
#import "FFHexEditorViewController.h"
#import "FFMachOInspectorViewController.h"
#import "FFSQLiteBrowserViewController.h"
#import "FFArchiveBrowserViewController.h"
#import "FFPreviewRouter.h"
#import "FFLogger.h"

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

#pragma mark - Media

@interface FFMediaPlayerViewController : AVPlayerViewController
@property(nonatomic, copy) NSString *filePath;
@end
@implementation FFMediaPlayerViewController
- (void)viewDidLoad
{
    [super viewDidLoad];
    if (self.filePath.length)
        self.navigationItem.rightBarButtonItem = [FFViewerActions actionsItemForPath:self.filePath
            title:nil icon:nil presenter:self allowTrash:YES];
}
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
            @[@"image", @"图片浏览器", @"photo", @"PNG/JPG/GIF/HEIC/WEBP/BMP/TIFF/ICO/CAR 等；缩放、左右切换、分享、删除、文件信息"],
            @[@"quicklook", @"快速查看", @"square.on.square.intersection.dashed", @"系统 Quick Look：仅作为无专用查看器格式与失败场景的手动兜底"],
            @[@"office-document", @"Office 阅读器", @"doc.text.magnifyingglass", @"离线查看 DOC/DOCX/PPT/PPTX/RTF/ODF/iWork/WPS 等办公文档；不上传文件"],
            @[@"spreadsheet", @"电子表格", @"tablecells", @"Univer + SheetJS 离线查看 XLS/XLSX/XLSB/XLSM/CSV/TSV/ODS 等，不上传文件"],
            @[@"web", @"Web Viewer", @"safari", @"HTML/HTM 本地页面；.url/.webloc 网页快捷方式"],
            @[@"plist", @"属性表编辑器", @"list.bullet.rectangle", @"结构化编辑 plist（XML/二进制）"],
            @[@"text", @"文本编辑器", @"doc.plaintext", @"txt/log/md/json/xml/源码等文本；脚本仅按文本打开，不执行"],
            @[@"sqlite", @"SQLite3 编辑器", @"cylinder.split.1x2", @"sqlite/sqlite3/sqlitedb/db：表、视图、索引、分页浏览与 SQL 查询（只读）"],
            @[@"archive", @"压缩包浏览器", @"archivebox", @"ZIP/IPA、7Z、RAR/RAR5、TAR、TGZ/TBZ/TXZ、GZ/BZ2/XZ 包内浏览与安全提取"],
            @[@"hex", @"十六进制编辑器", @"waveform.path.ecg", @"分页式 OFFSET/HEX/ASCII 查看，支持字节修改、保存与取消"],
            @[@"macho", @"Mach-O 检查器", @"cpu", @"架构切片、Load Commands、段/节、动态库、UUID、签名、Entitlements 与加密信息"],
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
    if (!viewer) {
        // A viewer can pass the availability check yet fail to build for this
        // file (e.g. an undecodable image). Never fail silently.
        FFLogTag(@"Viewer", @"build FAILED viewer=%@ path=%@", viewerID, path);
        [FFPreviewRouter toastOnNav:nav message:@"该文件无法用所选查看器打开"];
        return NO;
    }
    viewer.title = title.length ? title : path.lastPathComponent;
    [nav pushViewController:viewer animated:YES];
    FFLogTag(@"Viewer", @"open viewer=%@ path=%@", viewerID, path);
    return YES;
}
- (nullable UIViewController *)viewControllerForViewerID:(NSString *)viewerID path:(NSString *)path title:(NSString *)title
{
    if ([viewerID isEqualToString:@"image"]) return [[FFImageViewerViewController alloc] initWithPath:path];
    if ([viewerID isEqualToString:@"media"]) return [self mediaViewerAtPath:path];
    if ([viewerID isEqualToString:@"plist"]) return [[FFPlistEditorViewController alloc] initWithPath:path];
    if ([viewerID isEqualToString:@"text"]) return [[FFTextEditorViewController alloc] initWithPath:path];
    if ([viewerID isEqualToString:@"pdf"]) return [[FFPdfReaderViewController alloc] initWithPath:path];
    if ([viewerID isEqualToString:@"quicklook"]) return [[FFQuickLookViewController alloc] initWithFilePath:path];
    if ([viewerID isEqualToString:@"office-document"]) return [[FFOfficeDocumentViewController alloc] initWithFilePath:path];
    if ([viewerID isEqualToString:@"spreadsheet"]) return [[FFSpreadsheetViewController alloc] initWithFilePath:path];
    if ([viewerID isEqualToString:@"web"]) return [[FFWebViewerViewController alloc] initWithFilePath:path];
    if ([viewerID isEqualToString:@"sqlite"]) return [[FFSQLiteBrowserViewController alloc] initWithDatabasePath:path];
    if ([viewerID isEqualToString:@"hex"]) return [[FFHexEditorViewController alloc] initWithFilePath:path];
    if ([viewerID isEqualToString:@"macho"]) return [[FFMachOInspectorViewController alloc] initWithFilePath:path];
    if ([viewerID isEqualToString:@"archive"]) return [[FFArchiveBrowserViewController alloc] initWithArchivePath:path];
    return nil;
}
- (UIViewController *)mediaViewerAtPath:(NSString *)path
{
    FFMediaPlayerViewController *player = [FFMediaPlayerViewController new];
    player.filePath = path;
    player.player = [AVPlayer playerWithURL:[NSURL fileURLWithPath:path]];
    return player;
}
@end