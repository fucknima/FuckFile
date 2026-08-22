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

- (void)installTapped
{
    // 真实环境检查：FuckFile 是免越狱容器应用（MHA 身份访问）。容器内进程
    // 无法访问 installd/MobileInstallation，也没有任何可用的安装后端。
    // 明确告知原因，绝不假装安装成功。
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法安装"
        message:[NSString stringWithFormat:
            @"当前构建为免越狱环境，系统不允许第三方容器内进程调用安装服务（installd），"
            "因此没有可用的 IPA 安装后端。\n\n"
            "替代方案：\n• 使用「ZIP 浏览器」查看包内容\n"
            "• 「分享」导出 IPA 到支持安装的工具\n"
            "• 解压后直接查看 Payload 内容\n\n%@",
            self.bundleID ?: @""]
        preferredStyle:UIAlertControllerStyleAlert];
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
    FFLogTag(@"IPA", @"install REJECTED env=jailed path=%@", self.ipaPath);
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
