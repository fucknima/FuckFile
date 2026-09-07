#import "FFWebDAVSettingsViewController.h"

#import "FFStorageEnvironment.h"
#import "FFWebDAVServer.h"

static NSString *const kFFWebDAVUsernameKey = @"FFWebDAVUsername";
static NSString *const kFFWebDAVPortKey = @"FFWebDAVPort";

@implementation FFWebDAVSettingsViewController

- (instancetype)init
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) self.title = @"局域网文件共享";
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(serverChanged:)
        name:FFWebDAVServerDidChangeNotification object:nil];
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)serverChanged:(NSNotification *)note
{
    (void)note;
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    (void)tableView;
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    return section == 0 ? 2 : 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    (void)tableView;
    return section == 0 ? @"服务器" : @"共享范围";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    (void)tableView;
    if (section == 0) {
        return @"仅绑定当前 Wi‑Fi IPv4 地址，关闭后立即停止。WebDAV/浏览器均强制用户名和密码；密码只保存在内存中，不写入磁盘。";
    }
    return @"当前固定共享 FuckFile「文件」根目录，不会通过该服务暴露 App Data 高级访问入口之外的其他路径。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell"];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"Cell"];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.detailTextLabel.numberOfLines = 2;
    cell.imageView.tintColor = UIColor.systemBlueColor;

    FFWebDAVServer *server = FFWebDAVServer.sharedServer;
    if (indexPath.section == 0 && indexPath.row == 0) {
        cell.textLabel.text = @"启用局域网共享";
        cell.detailTextLabel.text = server.running ? @"正在运行" : @"已关闭";
        cell.imageView.image = [UIImage systemImageNamed:server.running ? @"network.badge.shield.half.filled" : @"network"];
        UISwitch *toggle = [UISwitch new];
        toggle.on = server.running;
        [toggle addTarget:self action:@selector(serverToggleChanged:)
           forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    if (indexPath.section == 0 && indexPath.row == 1) {
        cell.textLabel.text = @"访问地址";
        cell.detailTextLabel.text = server.addressString ?: @"启动后显示浏览器 / WebDAV 地址";
        cell.imageView.image = [UIImage systemImageNamed:@"link"];
        cell.accessoryType = server.addressString.length
            ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
        cell.selectionStyle = server.addressString.length
            ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
        return cell;
    }

    if (indexPath.section == 1 && indexPath.row == 0) {
        cell.textLabel.text = @"共享目录";
        cell.detailTextLabel.text = @"文件";
        cell.imageView.image = [UIImage systemImageNamed:@"folder"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *username = [defaults stringForKey:kFFWebDAVUsernameKey] ?: @"fuckfile";
    NSInteger port = [defaults integerForKey:kFFWebDAVPortKey];
    if (port <= 0 || port > 65535) port = 8080;
    cell.textLabel.text = @"连接参数";
    cell.detailTextLabel.text = [NSString stringWithFormat:@"用户名 %@ · 端口 %ld",
        server.running ? (server.username ?: username) : username, (long)port];
    cell.imageView.image = [UIImage systemImageNamed:@"person.badge.key"];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0 && indexPath.row == 1 &&
        FFWebDAVServer.sharedServer.addressString.length) {
        UIPasteboard.generalPasteboard.string = FFWebDAVServer.sharedServer.addressString;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
            message:@"访问地址已复制"
            preferredStyle:UIAlertControllerStyleAlert];
        [self presentViewController:alert animated:YES completion:^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [alert dismissViewControllerAnimated:YES completion:nil];
            });
        }];
    }
}

- (void)serverToggleChanged:(UISwitch *)toggle
{
    if (!toggle.on) {
        [FFWebDAVServer.sharedServer stop];
        [self.tableView reloadData];
        return;
    }

    toggle.on = NO;
    [self promptStartServer];
}

- (void)promptStartServer
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *savedUsername = [defaults stringForKey:kFFWebDAVUsernameKey] ?: @"fuckfile";
    NSInteger savedPort = [defaults integerForKey:kFFWebDAVPortKey];
    if (savedPort <= 0 || savedPort > 65535) savedPort = 8080;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"启动局域网共享"
        message:@"请设置用户名、密码和端口。密码不会保存；App 退出或你关闭共享后需要重新输入。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"用户名";
        field.text = savedUsername;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"密码";
        field.secureTextEntry = YES;
        field.textContentType = UITextContentTypeNewPassword;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"端口";
        field.text = [NSString stringWithFormat:@"%ld", (long)savedPort];
        field.keyboardType = UIKeyboardTypeNumberPad;
    }];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
        style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) {
            [weakSelf.tableView reloadData];
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"启动"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            NSString *username = [alert.textFields[0].text
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            NSString *password = alert.textFields[1].text ?: @"";
            NSInteger portValue = alert.textFields[2].text.integerValue;
            if (!username.length || !password.length ||
                portValue <= 0 || portValue > 65535) {
                [weakSelf showError:@"用户名、密码和端口必须有效"];
                return;
            }

            NSError *error = nil;
            BOOL started = [FFWebDAVServer.sharedServer startWithRoot:FFStorageRootPath()
                username:username password:password port:(uint16_t)portValue error:&error];
            if (!started) {
                [weakSelf showError:error.localizedDescription ?: @"启动局域网共享失败"];
                return;
            }
            [defaults setObject:username forKey:kFFWebDAVUsernameKey];
            [defaults setInteger:portValue forKey:kFFWebDAVPortKey];
            [weakSelf.tableView reloadData];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showError:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法启动"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好"
        style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
