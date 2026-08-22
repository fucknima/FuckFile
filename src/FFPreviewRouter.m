#import "FFPreviewRouter.h"

#import "FFBrowserViewController.h"   // FFEntry
#import "FFFileAssociationService.h"
#import "FFViewerRegistry.h"
#import "FFQuickLookViewController.h"
#import "FFHexEditorViewController.h"
#import "FFPlistEditorViewController.h"
#import "FFTextEditorViewController.h"
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

// 未命中任何关联时按内容判断：属性表 → 文本（大文件分段只读）→
// Quick Look → 十六进制编辑器。只采样前 4MB，绝不整读大文件。
+ (void)presentContentFallback:(FFEntry *)item nav:(UINavigationController *)nav
{
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
        [self alertOnNav:nav title:nil message:@"读取文件失败"];
        return;
    }

    // 二进制 plist 嗅探：内容是字典/数组就走结构化编辑器。
    if (data.length > 0 && !large) {
        NSPropertyListFormat format = NSPropertyListBinaryFormat_v1_0;
        id plist = [NSPropertyListSerialization propertyListWithData:data
            options:NSPropertyListImmutable format:&format error:nil];
        if ([plist isKindOfClass:NSDictionary.class] ||
            [plist isKindOfClass:NSArray.class]) {
            FFPlistEditorViewController *editor =
                [[FFPlistEditorViewController alloc] initWithPath:item.path];
            editor.title = item.displayName.length ? item.displayName : item.name;
            [nav pushViewController:editor animated:YES];
            return;
        }
    }

    // 文本嗅探（采样前 4096 字节）。
    NSString *candidate = [self stringFromData:data];
    if (candidate && [self looksTextual:candidate]) {
        if (!large) {
            FFTextEditorViewController *editor =
                [[FFTextEditorViewController alloc] initWithPath:item.path];
            editor.title = item.displayName.length ? item.displayName : item.name;
            [nav pushViewController:editor animated:YES];
            return;
        }
        // 大文本：前 1MB 只读预览。
        NSString *preview = [candidate substringToIndex:
            MIN(candidate.length, (NSUInteger)1024 * 1024)];
        preview = [preview stringByAppendingFormat:
            @"\n\n… 文件较大（%@），仅显示前 1 MB，只读预览。",
            [NSByteCountFormatter stringFromByteCount:(long long)fileSize
                countStyle:NSByteCountFormatterCountStyleFile]];
        [self presentText:item.name body:preview navigationController:nav];
        return;
    }

    // Quick Look：系统认识但 FuckFile 无专用查看器的格式。
    UIViewController *quickLook =
        [[FFQuickLookViewController alloc] initWithFilePath:item.path];
    if (quickLook) {
        quickLook.title = item.displayName.length ? item.displayName : item.name;
        [nav pushViewController:quickLook animated:YES];
        return;
    }

    // 最后兜底：真正的分页十六进制编辑器。
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

+ (NSString *)stringFromData:(NSData *)data
{
    NSString *utf8 = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (utf8) return utf8;
    NSString *utf16 = [[NSString alloc] initWithData:data encoding:NSUTF16StringEncoding];
    if (utf16) return utf16;
    return [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
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
