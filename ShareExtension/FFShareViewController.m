#import "FFShareViewController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString * const kGroupID = @"group.com.apple.mobile.MobileHouseArrest";
static NSString * const kShareFolder = @"SharedInbox";

@implementation FFShareViewController {
    UILabel *_statusLabel;
    UIButton *_doneButton;
    NSUInteger _doneCount;
    NSUInteger _failedCount;
    NSUInteger _totalPending;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    // 诊断：扩展进程启动即写标记，用于真机判断扩展是否进入运行。
    @try {
        NSURL *markerDir = [[NSFileManager defaultManager]
            containerURLForSecurityApplicationGroupIdentifier:kGroupID];
        if (markerDir) {
            NSURL *marker = [markerDir URLByAppendingPathComponent:@"ext-marker.txt"];
            NSString *message = [NSString stringWithFormat:@"viewDidLoad %@\n",
                [NSDate date]];
            [message writeToURL:marker atomically:YES
                       encoding:NSUTF8StringEncoding error:nil];
            NSLog(@"[FFShare] marker written: %@", marker.path);
        } else {
            NSLog(@"[FFShare] group container is NIL");
        }
    } @catch (NSException *e) {
        NSLog(@"[FFShare] exception: %@ %@", e.name, e.reason);
    }

    self.view.backgroundColor = [UIColor systemBackgroundColor];

    // 简短界面：状态标签 + 完成按钮（分享扩展允许自定义 UI）。
    _statusLabel = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 24, 0)];
    _statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;
    _statusLabel.numberOfLines = 0;
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.font = [UIFont systemFontOfSize:15];
    _statusLabel.text = @"正在导入文件…";
    [self.view addSubview:_statusLabel];

    _doneButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_doneButton setTitle:@"完成" forState:UIControlStateNormal];
    _doneButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [_doneButton sizeToFit];
    _doneButton.center = CGPointMake(self.view.bounds.size.width / 2,
        self.view.bounds.size.height - 80);
    _doneButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
        UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin;
    [_doneButton addTarget:self action:@selector(finishTapped)
        forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_doneButton];

    // 系统默认有一个「取消」按钮；自定义 UI 需手动关闭扩展。
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self
        action:@selector(cancelTapped)];

    [self collectAndSave];
}

- (void)finishTapped
{
    [self.extensionContext completeRequestReturningItems:nil completionHandler:nil];
}

- (void)cancelTapped
{
    [self.extensionContext cancelRequestWithError:
        [NSError errorWithDomain:@"FFShare" code:1 userInfo:nil]];
}

#pragma mark - Receiving files

- (void)collectAndSave
{
    NSArray<NSExtensionItem *> *items = self.extensionContext.inputItems;
    if (items.count == 0) {
        _statusLabel.text = @"没有文件";
        return;
    }
    // App Group 共享目录（主 app 可读）。
    NSURL *groupURL = [[NSFileManager defaultManager]
        containerURLForSecurityApplicationGroupIdentifier:kGroupID];
    NSURL *sharedFolder = [groupURL URLByAppendingPathComponent:kShareFolder];
    [[NSFileManager defaultManager] createDirectoryAtURL:sharedFolder
        withIntermediateDirectories:YES attributes:nil error:nil];

    __block NSUInteger done = 0;
    __block NSUInteger failed = 0;
    __block typeof(self) weakSelf = self;
    for (NSExtensionItem *item in items) {
        for (NSItemProvider *provider in item.attachments) {
            _totalPending++;
            NSString *identifier = [self preferredTypeIdentifier:provider];
            if (!identifier) { failed++; [weakSelf updateStatus]; continue; }
            [provider loadFileRepresentationForTypeIdentifier:identifier
                completionHandler:^(NSURL * _Nullable url, NSError * _Nullable error) {
                    if (!url || error) { failed++; [weakSelf updateStatus]; return; }
                    NSString *name = provider.suggestedName ?:
                        url.lastPathComponent ?: [NSString stringWithFormat:@"file-%lu", (unsigned long)done];
                    NSString *destination =
                        [sharedFolder URLByAppendingPathComponent:name].path;
                    // 重名加序号，绝不覆盖。
                    destination = [self uniquePathFor:destination];
                    NSError *moveError = nil;
                    if (destination && [[NSFileManager defaultManager] copyItemAtPath:url.path
                            toPath:destination error:&moveError]) {
                        done++;
                    } else {
                        failed++;
                    }
                    weakSelf->_doneCount = done;
                    weakSelf->_failedCount = failed;
                    [weakSelf updateStatus];
                }];
        }
    }
}

- (NSString *)preferredTypeIdentifier:(NSItemProvider *)provider
{
    // 优先按 UTTypeData 加载（还原为文件）；找不到再退回第一个注册类型。
    if ([provider hasItemConformingToTypeIdentifier:UTTypeData.identifier])
        return UTTypeData.identifier;
    if ([provider hasItemConformingToTypeIdentifier:UTTypeFileURL.identifier])
        return UTTypeFileURL.identifier;
    if (provider.registeredTypeIdentifiers.count > 0)
        return provider.registeredTypeIdentifiers.firstObject;
    return nil;
}

- (NSString *)uniquePathFor:(NSString *)path
{
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return path;
    NSString *base = path.stringByDeletingPathExtension;
    NSString *ext = path.pathExtension.length ?
        [@"." stringByAppendingString:path.pathExtension] : @"";
    for (NSInteger index = 2; index < 1000; index++) {
        NSString *candidate = [NSString stringWithFormat:@"%@ (%ld)%@",
            base, (long)index, ext];
        if (![[NSFileManager defaultManager] fileExistsAtPath:candidate]) return candidate;
    }
    return nil;
}

- (void)updateStatus
{
    __block typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *text;
        if (weakSelf->_doneCount + weakSelf->_failedCount >= weakSelf->_totalPending
            && weakSelf->_totalPending > 0) {
            text = [NSString stringWithFormat:@"已接收 %lu 个文件（失败 %lu）\n\n打开 FuckFile 后自动导入。",
                (unsigned long)weakSelf->_doneCount, (unsigned long)weakSelf->_failedCount];
        } else {
            text = @"请稍候…正在保存文件…";
        }
        weakSelf->_statusLabel.text = text;
    });
}

@end
