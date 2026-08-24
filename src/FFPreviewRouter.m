#import "FFPreviewRouter.h"

#import "FFBrowserViewController.h"   // FFEntry
#import "FFFileAssociationService.h"
#import "FFViewerRegistry.h"
#import "FFQuickLookViewController.h"
#import "FFHexEditorViewController.h"
#import "FFPlistEditorViewController.h"
#import "FFTextEditorViewController.h"
#import "FFContentProbe.h"
#import "FFTextCodec.h"

#import <objc/runtime.h>
#import "FFLogger.h"

// Retains shared text for the barButtonItem share action. UIBarButtonItem's
// responder chain doesn't reach the presenting VC, so nav is held directly.
@interface FFTextShareTarget : NSObject
@property(nonatomic, copy) NSString *text;
@property(nonatomic, weak) UINavigationController *nav;
- (void)share:(UIBarButtonItem *)sender;
@end

@implementation FFTextShareTarget
- (void)share:(UIBarButtonItem *)sender
{
    if (!self.text) return;
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:@[self.text] applicationActivities:nil];
    activity.popoverPresentationController.barButtonItem = sender;
    UIViewController *presenter = self.nav.topViewController;
    if (presenter)
        [presenter presentViewController:activity animated:YES completion:nil];
}
@end

@implementation FFPreviewRouter

+ (BOOL)previewItem:(FFEntry *)item navigationController:(UINavigationController *)nav
{
    if (!item.path || !nav) return NO;
    NSString *title = item.displayName.length ? item.displayName : item.name;

    // 1/2. 用户覆盖关联 → 内置默认关联（服务内部按最长后缀匹配）。
    // 3.   注册表检查可用性并打开；不可用时给出明确反馈并继续 fallback。
    NSString *viewerID = [[FFFileAssociationService sharedService]
        viewerIDForFileName:item.name];
    if (viewerID) {
        FFLogTag(@"Preview", @"%@ -> viewer=%@", item.name, viewerID);
        if ([[FFViewerRegistry sharedRegistry] openPath:item.path title:title
            viewerID:viewerID navigationController:nav]) return YES;
    }

    // 4. 内容检测兜底：plist / 文本 / Quick Look / Hex。
    [self presentContentFallback:item nav:nav];
    return YES;
}

+ (BOOL)openItem:(FFEntry *)item viewerID:(NSString *)viewerID
navigationController:(UINavigationController *)nav
{
    if (!item.path || !nav || viewerID.length == 0) return NO;
    NSString *title = item.displayName.length ? item.displayName : item.name;
    return [[FFViewerRegistry sharedRegistry] openPath:item.path title:title
        viewerID:viewerID navigationController:nav];
}

#pragma mark - Content-detection fallback

// 未命中任何关联时按内容判断：plist → 文本（大文件只读预览）→
// Quick Look → 十六进制编辑器。只采样 64 KB，绝不整读大文件；
// 文本判定 = FFContentProbe（UTF-8/UTF-16 两路），二进制不再误入
// 文本编辑器（禁止 Latin-1 自动兜底）。
+ (void)presentContentFallback:(FFEntry *)item nav:(UINavigationController *)nav
{
    unsigned long long fileSize = 0;
    NSDictionary *attrs = [NSFileManager.defaultManager
        attributesOfItemAtPath:item.path error:nil];
    fileSize = [attrs[NSFileSize] unsignedLongLongValue];

    FFContentKind kind = [FFContentProbe contentKindOfFile:item.path];

    // 属性表：二进制 plist / XML plist（可靠嗅探命中才进结构化编辑器；
    // 只处理小文件，避免整读）。
    if (kind == FFContentKindPlist) {
        if (fileSize <= 8 * 1024 * 1024) {
            FFPlistEditorViewController *editor =
                [[FFPlistEditorViewController alloc] initWithPath:item.path];
            editor.title = item.displayName.length ? item.displayName : item.name;
            [nav pushViewController:editor animated:YES];
            return;
        }
        // 超大 plist：交给 Quick Look 兜底链。
        [self fallbackToQuickLookOrHex:item nav:nav];
        return;
    }

    // 文本（严格 UTF-8/UTF-16，绝无 Latin-1）或 JSON/XML（结构层已确认是文本）。
    BOOL textLike = (kind == FFContentKindTextUTF8 ||
                     kind == FFContentKindTextUTF16 ||
                     kind == FFContentKindJSON ||
                     kind == FFContentKindXML);
    if (textLike) {
        if (fileSize <= 4 * 1024 * 1024) {
            FFTextEditorViewController *editor =
                [[FFTextEditorViewController alloc] initWithPath:item.path];
            editor.title = item.displayName.length ? item.displayName : item.name;
            [nav pushViewController:editor animated:YES];
            return;
        }
        // 大文本：前 1 MB 只读预览。
        NSString *candidate = [self readFirstText:item.path maxBytes:1024 * 1024];
        if (candidate) {
            NSString *preview = candidate;
            preview = [preview stringByAppendingFormat:
                @"\n\n… 文件较大（%@），仅显示前 1 MB，只读预览。\n要编辑请从「文本编辑器」关联打开（编辑器内为只读模式）。",
                [NSByteCountFormatter stringFromByteCount:(long long)fileSize
                    countStyle:NSByteCountFormatterCountStyleFile]];
            [self presentText:item.name body:preview navigationController:nav];
            return;
        }
        [self fallbackToQuickLookOrHex:item nav:nav];
        return;
    }

    // 已确认二进制：绝不进文本编辑器。
    [self fallbackToQuickLookOrHex:item nav:nav];
}

+ (void)fallbackToQuickLookOrHex:(FFEntry *)item nav:(UINavigationController *)nav
{
    UIViewController *quickLook =
        [[FFQuickLookViewController alloc] initWithFilePath:item.path];
    if (quickLook) {
        quickLook.title = item.displayName.length ? item.displayName : item.name;
        [nav pushViewController:quickLook animated:YES];
        return;
    }
    UIViewController *hex =
        [[FFHexEditorViewController alloc] initWithFilePath:item.path];
    if (hex) {
        hex.title = item.displayName.length ? item.displayName : item.name;
        [nav pushViewController:hex animated:YES];
        return;
    }
    FFLogTag(@"Preview", @"no fallback possible path=%@", item.path);
    [self alertOnNav:nav title:nil message:@"无法预览该文件"];
}

// 以 FFTextCodec 严格解码读取前 maxBytes（UTF-8/UTF-16 自动识别）。
// 返回 nil 表示该前缀不是合法文本（无法解码）。
+ (NSString *)readFirstText:(NSString *)path maxBytes:(NSUInteger)maxBytes
{
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return nil;
    NSData *data = [handle readDataOfLength:maxBytes];
    [handle closeFile];
    if (data.length == 0) return @"";
    FFTextEncoding encoding = FFTextEncodingUTF8;
    BOOL bom = NO;
    FFLineEnding lineEnding = FFLineEndingLF;
    NSString *text = [FFTextCodec decodeData:data encoding:&encoding
                                          bom:&bom lineEnding:&lineEnding];
    if (!text) {
        // 单通道失败：如果是 UTF-16 半字符截断，去掉奇数字节重试。
        if (data.length % 2 == 1) {
            NSData *trimmed = [data subdataWithRange:
                NSMakeRange(0, data.length - 1)];
            text = [FFTextCodec decodeData:trimmed encoding:&encoding
                                       bom:&bom lineEnding:&lineEnding];
        }
    }
    return text;
}

#pragma mark - Text viewer

+ (void)presentText:(NSString *)title body:(NSString *)body
    navigationController:(UINavigationController *)nav
{
    UIViewController *viewer = [UIViewController new];
    viewer.title = title;
    UITextView *textView = [[UITextView alloc] initWithFrame:viewer.view.bounds];
    textView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;
    textView.editable = NO;
    textView.selectable = YES;
    textView.font = [UIFont fontWithName:@"Menlo" size:12];
    textView.text = body;
    textView.backgroundColor = [UIColor systemBackgroundColor];
    [viewer.view addSubview:textView];

    FFTextShareTarget *target = [FFTextShareTarget new];
    target.text = body;
    target.nav = nav;
    UIBarButtonItem *share = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                             target:target action:@selector(share:)];
    // UIBarButtonItem target 是弱引用：关联对象强持有，防止点击无反应。
    objc_setAssociatedObject(share, "textShareTarget", target,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    viewer.navigationItem.rightBarButtonItem = share;
    [nav pushViewController:viewer animated:YES];
}

#pragma mark - Feedback

+ (void)alertOnNav:(UINavigationController *)nav title:(NSString *)title
           message:(NSString *)message
{
    UIViewController *top = nav.topViewController;
    if (!top) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好"
        style:UIAlertActionStyleDefault handler:nil]];
    [top presentViewController:alert animated:YES completion:nil];
}

+ (void)toastOnNav:(UINavigationController *)nav message:(NSString *)message
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
