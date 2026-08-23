#import "FFIPaInstallerViewController.h"

#import "FFArchiveService.h"
#import "FFArchiveBrowserViewController.h"
#import "FFLogger.h"

@interface FFIPaInstallerViewController ()
@property(nonatomic, copy) NSString *ipaPath;
@property(nonatomic, copy) NSString *appName;
@property(nonatomic, copy) NSString *bundleID;
@property(nonatomic, copy) NSString *version;
@property(nonatomic, copy) NSString *build;
@property(nonatomic, copy) NSString *minimumOS;
@property(nonatomic, copy) NSString *payloadPath;   // Payload/X.app inside the ipa
@property(nonatomic, strong) UIImage *icon;
@property(nonatomic, copy) NSString *failureMessage;
@property(nonatomic) BOOL loading;
@end

@implementation FFIPaInstallerViewController

- (instancetype)initWithIpaPath:(NSString *)path
{
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return nil;
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _ipaPath = [path copy];
        self.title = path.lastPathComponent;
        self.navigationItem.largeTitleDisplayMode =
            UINavigationItemLargeTitleDisplayModeNever;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"Cell"];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"安装"
        style:UIBarButtonItemStyleDone target:self action:@selector(installTapped)];
    [self parse];
}

#pragma mark - Parsing

- (void)parse
{
    self.loading = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSArray<FFArchiveEntry *> *entries =
            [[FFArchiveService new] listEntries:self->_ipaPath error:&error];
        if (!entries && error) {
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf parseFailed:error.localizedDescription]; });
            return;
        }

        // 找 Payload/*.app（取第一个 .app 目录）。
        NSString *appRoot = nil;
        for (FFArchiveEntry *entry in entries) {
            if (!entry.isDirectory) continue;
            NSRange payload = [entry.entryPath rangeOfString:@"Payload/"];
            if (payload.location != 0) continue;
            if ([entry.entryPath.pathExtension.lowercaseString isEqualToString:@"app"]) {
                appRoot = entry.entryPath;
                break;
            }
        }
        if (!appRoot) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf parseFailed:@"归档中找不到 Payload/*..app，不是有效的 IPA"];
            });
            return;
        }

        // 提取 Info.plist 到临时目录解析。
        NSString *infoEntry = [appRoot stringByAppendingPathComponent:@"Info.plist"];
        NSError *extractError = nil;
        NSString *tempDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [[[NSUUID UUID] UUIDString] substringToIndex:8]];
        [[NSFileManager defaultManager] createDirectoryAtPath:tempDir
            withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *infoFile = [[FFArchiveService new] extractEntry:infoEntry
            fromArchive:self->_ipaPath toDirectory:tempDir error:&extractError];
        if (!infoFile) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf parseFailed:[NSString stringWithFormat:@"读取 Info.plist 失败：%@",
                    extractError.localizedDescription ?: @"未知错误"]];
            });
            return;
        }
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoFile];

        // 图标：CFBundleIconFiles 取最后一个（通常最大），失败不阻塞。
        UIImage *icon = nil;
        NSMutableArray<NSString *> *icons = [NSMutableArray array];
        id iconFiles = info[@"CFBundleIconFiles"];
        if ([iconFiles isKindOfClass:NSArray.class]) [icons addObjectsFromArray:iconFiles];
        else if ([iconFiles isKindOfClass:NSString.class]) [icons addObject:iconFiles];
        NSString *primaryIcon = info[@"CFBundlePrimaryIcon"][@"CFBundleIconFiles"];
        if ([primaryIcon isKindOfClass:NSArray.class])
            [icons addObjectsFromArray:primaryIcon];
        for (NSString *iconName in [icons reverseObjectEnumerator]) {
            for (NSString *candidate in @[iconName,
                [iconName stringByAppendingString:@"@2x"],
                [NSString stringWithFormat:@"%@@3x", iconName],
                [NSString stringWithFormat:@"%@.png", iconName]]) {
                NSString *entryPath = [appRoot stringByAppendingPathComponent:candidate];
                NSString *file = [[FFArchiveService new] extractEntry:entryPath
                    fromArchive:self->_ipaPath toDirectory:tempDir error:nil];
                if (file) icon = [UIImage imageWithContentsOfFile:file];
                if (icon) break;
            }
            if (icon) break;
        }

        NSDictionary *parsed = @{
            @"name": info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"]
                     ?: appRoot.lastPathComponent.stringByDeletingPathExtension ?: @"?",
            @"bundleID": info[@"CFBundleIdentifier"] ?: @"?",
            @"version": info[@"CFBundleShortVersionString"] ?: @"?",
            @"build": info[@"CFBundleVersion"] ?: @"?",
            @"minOS": info[@"MinimumOSVersion"] ?: @"?",
            @"payload": appRoot,
        };
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.loading = NO;
            weakSelf.appName = parsed[@"name"];
            weakSelf.bundleID = parsed[@"bundleID"];
            weakSelf.version = parsed[@"version"];
            weakSelf.build = parsed[@"build"];
            weakSelf.minimumOS = parsed[@"minOS"];
            weakSelf.payloadPath = parsed[@"payload"];
            weakSelf.icon = icon;
            [weakSelf.tableView reloadData];
        });
    });
}

- (void)parseFailed:(NSString *)message
{
    self.loading = NO;
    self.failureMessage = message;
    self.navigationItem.rightBarButtonItem.enabled = NO;
    [self.tableView reloadData];
}

#pragma mark - Install

// 分级探测当前环境的可用安装通道，逐层如实反馈结果，绝不假装成功。
//  1) TrollStore（applestore:// scheme）：检测到则提供一键跳转安装
//  2) LSApplicationWorkspace 私有通道：探测 API 是否存在；存在则尝试，
//     失败给出具体异常/返回值
//  3) 均不可用 → 明确列出每层探测结果与替代方案
- (void)installTapped
{
    BOOL hasTrollStore = [[UIApplication sharedApplication]
        canOpenURL:[NSURL URLWithString:@"applestore://"]];

    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    id workspace = workspaceClass ?
        [workspaceClass performSelector:@selector(defaultWorkspace)] : nil;
    BOOL hasWorkspaceAPI = [workspace respondsToSelector:
        NSSelectorFromString(@"installApplication:withOptions:")];

    NSMutableString *report = [NSMutableString string];
    [report appendString:@"环境探测：\n"];
    [report appendFormat:@"• TrollStore：%@（可一键跳转安装）\n",
        hasTrollStore ? @"已检测到" : @"未检测到"];
    if (hasWorkspaceAPI) {
        [report appendString:@"• 系统安装通道：API 存在，可尝试（新系统大概率拒绝）"];
    } else {
        [report appendString:@"• 系统安装通道：不可用（免越狱容器内无法调用 installd）"];
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"安装 IPA"
        message:report preferredStyle:UIAlertControllerStyleAlert];

    if (hasTrollStore) {
        [alert addAction:[UIAlertAction actionWithTitle:@"用 TrollStore 安装"
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                NSString *encoded = [self.ipaPath stringByAddingPercentEncodingWithAllowedCharacters:
                    [NSCharacterSet URLQueryAllowedCharacterSet]];
                NSURL *trollURL = [NSURL URLWithString:
                    [NSString stringWithFormat:@"applestore://install?url=%@", encoded]];
                [[UIApplication sharedApplication] openURL:trollURL options:@{} completionHandler:nil];
                FFLogTag(@"IPA", @"hand-off to TrollStore path=%@", self.ipaPath);
            }]];
    }
    if (hasWorkspaceAPI) {
        [alert addAction:[UIAlertAction actionWithTitle:@"尝试系统通道"
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                [self attemptWorkspaceInstall:workspace];
            }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"浏览压缩包"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            UINavigationController *nav = self.navigationController;
            if (!nav) return;
            FFArchiveBrowserViewController *browser =
                [[FFArchiveBrowserViewController alloc] initWithArchivePath:self.ipaPath];
            [nav pushViewController:browser animated:YES];
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"好"
        style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// 私有通道尝试：包一层 @try，任何异常都转成明确的失败原因展示。
- (void)attemptWorkspaceInstall:(id)workspace
{
    NSURL *fileURL = [NSURL fileURLWithPath:self.ipaPath];
    BOOL installed = NO;
    NSString *detail = nil;
    @try {
        installed = (BOOL)[workspace
            performSelector:@selector(installApplication:withOptions:)
                  withObject:fileURL
                  withObject:@{}];
        if (!installed)
            detail = @"installApplication 返回 NO（系统拒绝了本次安装请求）";
    } @catch (NSException *exception) {
        detail = [NSString stringWithFormat:@"%@：%@",
            exception.name, exception.reason];
    }
    FFLogTag(@"IPA", @"workspace install %@ (%@)",
        installed ? @"OK" : @"FAIL", detail ?: @"");
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:
        installed ? @"安装成功" : @"系统通道安装失败"
        message:installed
            ? [NSString stringWithFormat:@"已提交安装：%@\n\n请到主屏幕确认。", self.bundleID]
            : [NSString stringWithFormat:@"%@\n\n该通道在免越狱设备上通常被系统拒绝，"
               "建议使用 TrollStore 或其他工具完成安装。", detail ?: @"未知原因"]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好"
        style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView
{
    return 2;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return section == 0 ? 1 : 6;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell"
        forIndexPath:indexPath];
    UIListContentConfiguration *config = [cell defaultContentConfiguration];
    config.secondaryTextProperties.font =
        [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    cell.accessoryType = UITableViewCellAccessoryNone;

    if (indexPath.section == 0) {
        config.image = self.icon ?: [UIImage systemImageNamed:@"app"];
        config.imageProperties.maximumSize = CGSizeMake(60, 60);
        config.imageProperties.cornerRadius = 12;
        config.text = self.loading ? @"正在解析…" :
            (self.failureMessage ?: self.appName);
        config.secondaryText = self.failureMessage ? nil : self.payloadPath;
        cell.contentConfiguration = config;
        return cell;
    }

    if (self.failureMessage || self.loading) {
        config.text = self.failureMessage ?: @"解析中…";
        cell.contentConfiguration = config;
        return cell;
    }
    switch (indexPath.row) {
        case 0: config.text = @"App 名称";   config.secondaryText = self.appName; break;
        case 1: config.text = @"Bundle ID";  config.secondaryText = self.bundleID; break;
        case 2: config.text = @"Version";    config.secondaryText = self.version; break;
        case 3: config.text = @"Build";      config.secondaryText = self.build; break;
        case 4: config.text = @"最低系统";   config.secondaryText = self.minimumOS; break;
        default: config.text = @"安装";      config.secondaryText = @"点击右上角「安装」按钮";
                 config.image = [UIImage systemImageNamed:@"arrow.down.circle"]; break;
    }
    cell.contentConfiguration = config;
    return cell;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return section == 0 ? nil : @"应用信息";
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1 && indexPath.row == 5 && !self.failureMessage && !self.loading)
        [self installTapped];
}

@end
