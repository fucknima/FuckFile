#import "FFIPaInstallerViewController.h"

#import "FFArchiveBrowserViewController.h"
#import "FFIPAMetadataService.h"
#import "FFLogger.h"

@interface FFIPaInstallerViewController ()
@property(nonatomic, copy) NSString *ipaPath;
@property(nonatomic, strong) FFIPAMetadata *metadata;
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
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"安装" style:UIBarButtonItemStyleDone
        target:self action:@selector(installTapped)];
    self.navigationItem.rightBarButtonItem.enabled = NO;
    [self parse];
}

- (void)parse
{
    self.loading = YES;
    __weak typeof(self) weakSelf = self;
    [[FFIPAMetadataService sharedService] metadataForIPAAtPath:self.ipaPath
        completion:^(FFIPAMetadata *metadata, NSError *error) {
            typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self.loading = NO;
            if (!metadata) {
                self.failureMessage = error.localizedDescription ?: @"无法解析 IPA";
                self.navigationItem.rightBarButtonItem.enabled = NO;
            } else {
                self.metadata = metadata;
                self.navigationItem.rightBarButtonItem.enabled = YES;
            }
            [self.tableView reloadData];
        }];
}

- (void)installTapped
{
    if (!self.metadata) return;
    BOOL hasTrollStore = [[UIApplication sharedApplication]
        canOpenURL:[NSURL URLWithString:@"applestore://"]];

    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    id workspace = workspaceClass ? [workspaceClass performSelector:@selector(defaultWorkspace)] : nil;
    BOOL hasWorkspaceAPI = [workspace respondsToSelector:NSSelectorFromString(@"installApplication:withOptions:")];

    NSMutableString *report = [NSMutableString stringWithString:@"环境探测：\n"];
    [report appendFormat:@"• TrollStore：%@\n", hasTrollStore ? @"已检测到" : @"未检测到"];
    [report appendFormat:@"• 系统安装通道：%@", hasWorkspaceAPI ? @"API 存在，可尝试" : @"不可用"];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"安装 IPA"
        message:report preferredStyle:UIAlertControllerStyleAlert];
    if (hasTrollStore) {
        [alert addAction:[UIAlertAction actionWithTitle:@"用 TrollStore 安装"
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                NSString *encoded = [self.ipaPath stringByAddingPercentEncodingWithAllowedCharacters:
                    NSCharacterSet.URLQueryAllowedCharacterSet];
                NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"applestore://install?url=%@", encoded]];
                [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
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
            FFArchiveBrowserViewController *browser =
                [[FFArchiveBrowserViewController alloc] initWithArchivePath:self.ipaPath];
            [self.navigationController pushViewController:browser animated:YES];
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)attemptWorkspaceInstall:(id)workspace
{
    NSURL *fileURL = [NSURL fileURLWithPath:self.ipaPath];
    BOOL installed = NO;
    NSString *detail = nil;
    @try {
        installed = (BOOL)[workspace performSelector:@selector(installApplication:withOptions:)
            withObject:fileURL withObject:@{}];
        if (!installed) detail = @"installApplication 返回 NO（系统拒绝了本次安装请求）";
    } @catch (NSException *exception) {
        detail = [NSString stringWithFormat:@"%@：%@", exception.name, exception.reason];
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:
        installed ? @"安装成功" : @"系统通道安装失败"
        message:installed ? [NSString stringWithFormat:@"已提交安装：%@", self.metadata.bundleIdentifier]
                          : (detail ?: @"未知原因")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section == 0 ? 1 : 6; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell" forIndexPath:indexPath];
    UIListContentConfiguration *config = [cell defaultContentConfiguration];
    config.secondaryTextProperties.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    cell.accessoryType = UITableViewCellAccessoryNone;

    if (indexPath.section == 0) {
        config.image = self.metadata.icon ?: [UIImage systemImageNamed:@"app"];
        config.imageProperties.maximumSize = CGSizeMake(64, 64);
        config.imageProperties.cornerRadius = 13;
        if (self.metadata.icon) config.imageProperties.tintColor = nil;
        config.text = self.loading ? @"正在解析…" : (self.failureMessage ?: self.metadata.displayName);
        config.secondaryText = self.failureMessage ? nil : self.metadata.appBundlePath;
        cell.contentConfiguration = config;
        return cell;
    }

    if (self.failureMessage || self.loading || !self.metadata) {
        config.text = self.failureMessage ?: @"解析中…";
        cell.contentConfiguration = config;
        return cell;
    }
    switch (indexPath.row) {
        case 0: config.text = @"App 名称"; config.secondaryText = self.metadata.displayName; break;
        case 1: config.text = @"Bundle ID"; config.secondaryText = self.metadata.bundleIdentifier; break;
        case 2: config.text = @"Version"; config.secondaryText = self.metadata.version; break;
        case 3: config.text = @"Build"; config.secondaryText = self.metadata.build; break;
        case 4: config.text = @"最低系统"; config.secondaryText = self.metadata.minimumOS; break;
        default:
            config.text = @"安装";
            config.secondaryText = @"点击右上角「安装」按钮";
            config.image = [UIImage systemImageNamed:@"arrow.down.circle"];
            break;
    }
    cell.contentConfiguration = config;
    return cell;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return section == 0 ? nil : @"应用信息";
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1 && indexPath.row == 5 && self.metadata) [self installTapped];
}

@end
