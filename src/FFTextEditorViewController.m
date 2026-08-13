#import "FFTextEditorViewController.h"
#import "FFLogger.h"
#import "FFPathPolicy.h"

@interface FFTextEditorViewController () <UITextViewDelegate>
@property(nonatomic, copy) NSString *filePath;
@property(nonatomic, strong) UITextView *textView;
@property(nonatomic) BOOL changed;
@end

@implementation FFTextEditorViewController

- (instancetype)initWithPath:(NSString *)path
{
    self = [super init];
    if (self) {
        _filePath = path;
        self.title = path.lastPathComponent;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.textView = [UITextView new];
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    self.textView.font = [UIFont fontWithName:@"Menlo" size:13];
    self.textView.autocorrectionType = UITextAutocorrectionTypeNo;
    self.textView.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.textView.smartQuotesType = UITextSmartQuotesTypeNo;
    self.textView.smartDashesType = UITextSmartDashesTypeNo;
    self.textView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.textView.delegate = self;
    [self.view addSubview:self.textView];
    [NSLayoutConstraint activateConstraints:@[
        [self.textView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.textView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
    ]];

    UIBarButtonItem *save = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:
        UIBarButtonSystemItemSave target:self action:@selector(save)];
    save.enabled = NO;
    self.navigationItem.rightBarButtonItem = save;

    // 自定义返回键：有未保存修改时先询问，而不是直接丢失。
    UIBarButtonItem *back = [[UIBarButtonItem alloc] initWithTitle:@"返回"
        style:UIBarButtonItemStylePlain target:self action:@selector(backTapped)];
    self.navigationItem.leftBarButtonItem = back;
    self.navigationController.interactivePopGestureRecognizer.delegate =
        (id<UIGestureRecognizerDelegate>)self;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // 大文件不能一次全部读入内存：>4MB 只读，仅加载前 256KB。
        unsigned long long fileSize = 0;
        NSDictionary *attrs = [NSFileManager.defaultManager
            attributesOfItemAtPath:self.filePath error:nil];
        fileSize = [attrs[NSFileSize] unsignedLongLongValue];
        BOOL large = fileSize > 4 * 1024 * 1024;
        NSData *data = nil;
        if (large) {
            NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:self.filePath];
            data = [handle readDataOfLength:256 * 1024];
            [handle closeFile];
        } else {
            data = [NSData dataWithContentsOfFile:self.filePath];
        }
        NSString *text = data
            ? [self stringFromData:data] ?: @"（二进制内容，不能编辑）"
            : @"（读取失败）";
        if (large && text)
            text = [text stringByAppendingFormat:
                @"\n\n… 文件较大（%@），仅显示前 256 KB，只读预览。",
                [NSByteCountFormatter stringFromByteCount:(long long)fileSize
                    countStyle:NSByteCountFormatterCountStyleFile]];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.textView.text = text;
            if (data.length < 4 * 1024 * 1024) self.textView.editable = YES;
            else self.textView.editable = NO;
        });
    });
}

// 返回时若存在未保存内容，提示保存 / 放弃 / 取消。
- (void)backTapped
{
    if (!self.changed) {
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"未保存的修改"
        message:@"是否保存对此文件的修改？"
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf save]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"放弃" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            [weakSelf.navigationController popViewControllerAnimated:YES];
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// 拦截左滑返回：有未保存修改时走确认弹窗。
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer
{
    if (self.changed && gestureRecognizer ==
        self.navigationController.interactivePopGestureRecognizer) {
        [self backTapped];
        return NO;
    }
    return YES;
}

- (NSString *)stringFromData:(NSData *)data
{
    NSString *utf8 = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (utf8) return utf8;
    NSString *utf16 = [[NSString alloc] initWithData:data encoding:NSUTF16StringEncoding];
    if (utf16) return utf16;
    NSString *latin1 = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    if (latin1) return latin1;
    return nil;
}

- (void)textViewDidChange:(__unused UITextView *)textView
{
    self.changed = YES;
    self.navigationItem.rightBarButtonItem.enabled = YES;
}

- (void)save
{
    NSData *data = [self.textView.text dataUsingEncoding:NSUTF8StringEncoding];
    // 写入前统一路径校验，避免符号链接竞态越界写入。
    NSString *detail = nil;
    NSString *finalName = nil;
    if (![FFPathPolicy resolveParentForMutation:self.filePath
        finalName:&finalName errorMessage:&detail]) {
        [self flash:[NSString stringWithFormat:@"无法保存：%@",
            detail ?: @"路径不合法"]];
        return;
    }
    NSError *error = nil;
    if ([data writeToFile:self.filePath options:NSDataWritingAtomic error:&error]) {
        [self flash:@"已保存"];
        self.changed = NO;
        self.navigationItem.rightBarButtonItem.enabled = NO;
        return;
    }
    FFLogTag(@"TextEditor", @"save FAIL path=%@ error=%@", self.filePath, error);
    [self offerCopyOnFailure:data];
}

// Escaped read-only paths deny writes: offer to save a copy inside the
// app's own Documents so nothing is lost.
- (void)offerCopyOnFailure:(NSData *)data
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法写入"
        message:@"该位置不可写（沙盒只读扩展）。\n保存副本到 FuckFile 文档？"
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存副本" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            NSString *documents = NSSearchPathForDirectoriesInDomains(
                NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            NSString *folder = [documents stringByAppendingPathComponent:@"Edited Copies"];
            [[NSFileManager defaultManager] createDirectoryAtPath:folder
                withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *copyPath = [folder stringByAppendingPathComponent:
                weakSelf.filePath.lastPathComponent];
            NSError *error = nil;
            if ([data writeToFile:copyPath options:NSDataWritingAtomic error:&error]) {
                [weakSelf flash:[NSString stringWithFormat:@"已保存副本：\n%@", copyPath]];
            } else {
                [weakSelf flash:[NSString stringWithFormat:@"副本保存失败：%@", error.localizedDescription]];
            }
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)flash:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.5 * NSEC_PER_SEC),
            dispatch_get_main_queue(), ^{
                [alert dismissViewControllerAnimated:YES completion:nil];
            });
    }];
}

@end
