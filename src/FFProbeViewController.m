#import "FFProbeViewController.h"
#import "BadQueryProbe.h"
#import "MCMManager.h"

#import <sys/utsname.h>

@interface FFProbeViewController ()
@property(nonatomic, strong) NSDictionary *report;
@property(nonatomic) int64_t lastHandle;
@property(nonatomic) BOOL running;
@end

static NSString *const kProbeHelpText =
    @"【沙盒逃逸探针使用说明】\n\n"
    @"1. 首次打开 App 会自动跑一轮探针（约 1 秒）。\n"
    @"   每一步成功/失败都会写进：\n"
    @"   Device Storage/BadQuery Probe Log.txt\n"
    @"   Device Storage/FuckFile Log.txt\n\n"
    @"2. 看结果：\n"
    @"   - 探针列表：绿色=逃逸成功，红色=失败。\n"
    @"   - 变体矩阵：iOS 26.6 上 canonical flags 被拦，"
    @"但矩阵里 TOKEN-OK 的组合仍能签发沙盒 token。\n\n"
    @"3. 枚举容器（关键步骤）：\n"
    @"   - 点“枚举容器”，App 会消费沙盒扩展并列出：\n"
    @"     App Data / InternalDaemon / PluginKitPlugin / "
    @"App Groups / System Groups\n"
    @"   - 结果按 bundle id 建符号链接到：\n"
    @"     Device Storage/[BadQuery] Escaped/<分类>/\n"
    @"   - 然后回首页 → 设备存储 → [BadQuery] Escaped → App Data，"
    @"就能看到其它 App 的 Documents/Library/tmp。\n"
    @"   - 重启 App 后 token 会失效；本版已加自动重连。"
    @"如果仍打不开，回这里再点一次“枚举容器”。\n\n"
    @"4. 设置 App Group 牺牲（可选）：\n"
    @"   - 仅当你用带 App Group entitlement 的证书签名时才需要。\n"
    @"   - 点“设置 App Group 牺牲”，输入你的 group id（如 group.xxx）保存。\n"
    @"   - 重新运行探针 + 枚举容器，App Groups 可列出更多容器；\n"
    @"     没有配置时 class 7 路线会跳过（日志会写明）。\n\n"
    @"5. 消费自定义路径：\n"
    @"   - 对任意绝对路径执行 bad_query，成功后本进程内可访问。\n"
    @"   - “释放扩展”只释放最近一次手动消费的句柄，枚举用的不会释放。\n\n"
    @"6. 导出日志：\n"
    @"   文件 App → 我的 iPhone → FuckFile → Device Storage\n"
    @"   把 FuckFile Log.txt、BadQuery Probe Log.txt、ACCESS MAP.txt、"
    @"BadQuery Probe Results.plist 压缩导出即可。";

@implementation FFProbeViewController

- (instancetype)init
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) self.title = @"bad_query";
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self reloadReport];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self reloadReport];
}

- (void)reloadReport
{
    self.report = BadQueryProbeLastReport();
    [self.tableView reloadData];
}

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case 0: return 5;
        case 1: return 10;
        case 2: {
            NSArray *probes = [self.report[@"Probes"] isKindOfClass:NSArray.class]
                ? self.report[@"Probes"] : @[];
            return probes.count;
        }
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case 0: return @"状态";
        case 1: return @"操作";
        case 2: return @"探针列表";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 2 && [self.report[@"Probes"] isKindOfClass:NSArray.class])
        return @"点击探针查看完整步骤结果。常规探针 0/N 不代表失败：iOS 26.6 上 "
            @"canonical 路线被拦，实际逃逸走“变体矩阵 + 枚举容器”。"
            @"逃逸链接在 设备存储/[BadQuery] Escaped/。";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Status"];
        if (!cell)
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                          reuseIdentifier:@"Status"];
        cell.detailTextLabel.numberOfLines = 0;
        cell.accessoryType = UITableViewCellAccessoryNone;
        NSDictionary *environment = [self.report[@"Environment"] isKindOfClass:NSDictionary.class]
            ? self.report[@"Environment"] : nil;
        switch (indexPath.row) {
            case 0:
                cell.textLabel.text = @"系统";
                cell.detailTextLabel.text = environment
                    ? [NSString stringWithFormat:@"iOS %@ (%@)", environment[@"SystemVersion"], environment[@"Build"]]
                    : [NSString stringWithFormat:@"iOS %@", UIDevice.currentDevice.systemVersion];
                break;
            case 1:
                cell.textLabel.text = @"逃逸状态";
                if (!self.report) {
                    cell.detailTextLabel.text = @"尚未运行";
                } else {
                    NSArray *probes = [self.report[@"Probes"] isKindOfClass:NSArray.class]
                        ? self.report[@"Probes"] : @[];
                    NSUInteger escaped = 0;
                    for (NSDictionary *probe in probes)
                        if ([probe[@"Status"] isKindOfClass:NSString.class] &&
                            [probe[@"Status"] isEqualToString:@"escaped"]) escaped++;
                    NSArray *matrix = [self.report[@"VariantMatrix"] isKindOfClass:NSArray.class]
                        ? self.report[@"VariantMatrix"] : @[];
                    NSUInteger tokenOk = 0;
                    for (NSDictionary *entry in matrix)
                        if ([entry[@"Status"] isKindOfClass:NSString.class] &&
                            [entry[@"Status"] isEqualToString:@"TOKEN-OK"]) tokenOk++;
                    NSMutableArray<NSString *> *parts = [NSMutableArray array];
                    [parts addObject:[NSString stringWithFormat:
                        @"常规探针 %lu/%lu（canonical 被拦时正常）",
                        (unsigned long)escaped, (unsigned long)probes.count]];
                    [parts addObject:[NSString stringWithFormat:
                        @"变体矩阵 %lu/%lu 可签 token",
                        (unsigned long)tokenOk, (unsigned long)matrix.count]];
                    NSString *escapedRoot = [MCMVirtualRoot()
                        stringByAppendingPathComponent:@"[BadQuery] Escaped"];
                    NSDictionary *summary = [NSDictionary dictionaryWithContentsOfFile:
                        [escapedRoot stringByAppendingPathComponent:@"Enumerate Results.plist"]];
                    NSArray *results = [summary[@"Results"] isKindOfClass:NSArray.class]
                        ? summary[@"Results"] : @[];
                    NSMutableArray<NSString *> *counts = [NSMutableArray array];
                    for (NSDictionary *result in results) {
                        NSNumber *count = [result[@"Count"] isKindOfClass:NSNumber.class]
                            ? result[@"Count"] : nil;
                        if (count && count.unsignedIntegerValue > 0)
                            [counts addObject:[NSString stringWithFormat:@"%@ %@",
                                result[@"Name"] ?: @"?", count]];
                    }
                    if (counts.count) {
                        [parts addObject:[NSString stringWithFormat:@"容器枚举：%@",
                            [counts componentsJoinedByString:@"、"]]];
                    }
                    cell.detailTextLabel.text = [parts componentsJoinedByString:@"\n"];
                }
                break;
            case 2:
                cell.textLabel.text = @"最近运行";
                cell.detailTextLabel.text = [self.report[@"CreatedAt"] isKindOfClass:NSDate.class]
                    ? [NSDateFormatter localizedStringFromDate:self.report[@"CreatedAt"]
                        dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterMediumStyle]
                    : @"从未";
                break;
            case 3:
                cell.textLabel.text = @"App Group 牺牲配置";
                cell.detailTextLabel.text = [self.report[@"SacrificeGroupConfigured"] boolValue]
                    ? @"已配置" : @"未配置";
                break;
            case 4:
                cell.textLabel.text = @"变体矩阵";
                {
                    NSArray *matrix = [self.report[@"VariantMatrix"] isKindOfClass:NSArray.class]
                        ? self.report[@"VariantMatrix"] : nil;
                    NSUInteger ok = 0;
                    for (NSDictionary *entry in matrix ?: @[])
                        if ([entry[@"Status"] isKindOfClass:NSString.class] &&
                            [entry[@"Status"] isEqualToString:@"TOKEN-OK"]) ok++;
                    cell.detailTextLabel.text = matrix
                        ? [NSString stringWithFormat:@"%lu/%lu 组合能签发 token",
                            (unsigned long)ok, (unsigned long)matrix.count]
                        : @"未记录";
                }
                break;
        }
        return cell;
    }

    if (indexPath.section == 1) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Action"];
        if (!cell)
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:@"Action"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.textLabel.textColor = [UIColor labelColor];
        cell.textLabel.textAlignment = NSTextAlignmentLeft;
        switch (indexPath.row) {
            case 0: cell.textLabel.text = @"重新运行探针"; break;
            case 1: cell.textLabel.text = @"查看分步日志"; break;
            case 2: cell.textLabel.text = @"查看结果 Plist"; break;
            case 3: cell.textLabel.text = @"消费自定义路径"; break;
            case 4: cell.textLabel.text = self.lastHandle >= 0
                ? [NSString stringWithFormat:@"释放扩展（句柄 %lld）", self.lastHandle]
                : @"释放扩展"; break;
            case 5: cell.textLabel.text = @"枚举容器（UUID → 包名）"; break;
            case 6: cell.textLabel.text = @"设置 App Group 牺牲"; break;
            case 7: cell.textLabel.text = @"查看变体矩阵"; break;
            case 8: cell.textLabel.text = @"使用说明"; break;
            case 9: cell.textLabel.text = @"测试写入权限"; break;
        }
        return cell;
    }

    NSArray *probes = [self.report[@"Probes"] isKindOfClass:NSArray.class]
        ? self.report[@"Probes"] : @[];
    NSDictionary *probe = probes[indexPath.row];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Probe"];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"Probe"];
    cell.textLabel.text = [probe[@"Name"] isKindOfClass:NSString.class] ? probe[@"Name"] : @"Probe";
    NSString *status = [probe[@"Status"] isKindOfClass:NSString.class] ? probe[@"Status"] : @"?";
    NSString *path = [probe[@"Path"] isKindOfClass:NSString.class] ? probe[@"Path"] : @"";
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ — %@", status, path];
    cell.detailTextLabel.numberOfLines = 0;
    cell.imageView.image = [UIImage systemImageNamed:
        [status isEqualToString:@"escaped"] ? @"checkmark.circle.fill" : @"xmark.circle.fill"];
    cell.imageView.tintColor = [status isEqualToString:@"escaped"]
        ? [UIColor systemGreenColor] : [UIColor systemRedColor];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) return;
    if (indexPath.section == 1) {
        switch (indexPath.row) {
            case 0: [self rerunProbe]; break;
            case 1: [self presentText:@"探针日志" body:BadQueryProbeLogText()]; break;
            case 2: [self presentResults]; break;
            case 3: [self consumeCustomPath]; break;
            case 4: [self releaseHandle]; break;
            case 5: [self enumerateContainers]; break;
            case 6: [self setSacrificeGroup]; break;
            case 7: [self presentVariantMatrix]; break;
            case 8: [self presentHelp]; break;
            case 9: [self runWriteTest]; break;
        }
        return;
    }
    NSArray *probes = [self.report[@"Probes"] isKindOfClass:NSArray.class]
        ? self.report[@"Probes"] : @[];
    NSDictionary *probe = probes[indexPath.row];
    [self presentProbeDetail:probe];
}

#pragma mark - Actions

- (void)rerunProbe
{
    if (self.running) return;
    self.running = YES;
    [self flash:@"探针正在后台运行…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BadQueryProbeRunAgain();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.running = NO;
            [self reloadReport];
            [self flash:@"探针完成"];
        });
    });
}

- (void)consumeCustomPath
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"消费自定义路径"
        message:@"对绝对路径执行 bad_query，成功后保留沙箱扩展句柄。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = @"/var/mobile/Containers/Data/Application";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.keyboardType = UIKeyboardTypeURL;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"执行" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            NSString *path = alert.textFields.firstObject.text;
            [weakSelf runConsume:path];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)runConsume:(NSString *)path
{
    if (!path.length) return;
    [self flash:@"正在消费沙箱扩展…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error = nil;
        int64_t handle = BadQueryConsumePath(path, nil, NO, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (handle >= 0) {
                self.lastHandle = handle;
                [self flash:[NSString stringWithFormat:@"逃逸成功！句柄=%lld（%@）", handle, path]];
            } else {
                [self flash:error ?: [NSString stringWithFormat:@"失败（错误码 %lld）", handle]];
            }
            [self.tableView reloadData];
        });
    });
}

- (void)releaseHandle
{
    if (self.lastHandle < 0) {
        [self flash:@"没有活动的句柄"];
        return;
    }
    BadQueryReleaseHandle(self.lastHandle);
    self.lastHandle = -1;
    [self flash:@"扩展已释放"];
    [self.tableView reloadData];
}

- (void)enumerateContainers
{
    if (self.running) return;
    self.running = YES;
    [self flash:@"正在用 bad_query_list 枚举容器…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *summary = BadQueryEnumerateAllContainers();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.running = NO;
            NSUInteger total = 0;
            for (NSDictionary *result in [summary[@"Results"] isKindOfClass:NSArray.class]
                ? summary[@"Results"] : @[]) {
                NSNumber *count = [result[@"Count"] isKindOfClass:NSNumber.class]
                    ? result[@"Count"] : nil;
                total += count ? count.unsignedIntegerValue : 0;
            }
            [self reloadReport];
            [self flash:[NSString stringWithFormat:
                @"已映射 %lu 个容器到 设备存储/[BadQuery] Escaped/", total]];
        });
    });
}

- (void)setSacrificeGroup
{
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [documents stringByAppendingPathComponent:@"AppGroupSacrifice.plist"];
    NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:path];
    NSString *current = [existing[@"GroupId"] isKindOfClass:NSString.class]
        ? existing[@"GroupId"] : @"";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"App Group 牺牲"
        message:@"iOS 26 访问 App Group 需要一个你签名身份拥有的 group。输入 group id，并确保它已写入 entitlements。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = current;
        field.placeholder = @"group.your.own.group";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            NSString *groupId = alert.textFields.firstObject.text;
            groupId = [groupId stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!groupId.length) {
                [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            } else {
                [@{@"GroupId": groupId} writeToFile:path atomically:YES];
            }
            [weakSelf reloadReport];
            [weakSelf flash:@"已保存。重新运行探针和容器枚举即可使用 group 路线。"];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)presentResults
{
    if (!self.report) {
        [self flash:@"还没有结果"];
        return;
    }
    NSError *error = nil;
    NSData *xml = [NSPropertyListSerialization dataWithPropertyList:self.report
        format:NSPropertyListXMLFormat_v1_0 options:0 error:&error];
    NSString *text = xml ? [[NSString alloc] initWithData:xml encoding:NSUTF8StringEncoding]
        : (error.localizedDescription ?: @"Serialization failed");
    [self presentText:@"探针结果" body:text];
}

- (void)presentVariantMatrix
{
    NSArray *matrix = [self.report[@"VariantMatrix"] isKindOfClass:NSArray.class]
        ? self.report[@"VariantMatrix"] : nil;
    if (!matrix.count) {
        [self flash:@"还没有变体矩阵结果"];
        return;
    }
    NSMutableString *text = [NSMutableString string];
    NSUInteger ok = 0;
    for (NSDictionary *entry in matrix) {
        NSString *status = [entry[@"Status"] isKindOfClass:NSString.class]
            ? entry[@"Status"] : @"?";
        if ([status isEqualToString:@"TOKEN-OK"]) ok++;
        [text appendFormat:@"group=%@ flags=%@ part=%@ traversal=%@ status=%@\n",
            entry[@"Group"] ?: @"?", entry[@"Flags"] ?: @"?",
            entry[@"Part"] ?: @"?", entry[@"Traversal"] ?: @"?", status];
    }
    [self presentText:[NSString stringWithFormat:@"变体矩阵（%lu/%lu 可用）",
        (unsigned long)ok, (unsigned long)matrix.count] body:text];
}

- (void)presentHelp
{
    [self presentText:@"使用说明" body:kProbeHelpText];
}

- (void)runWriteTest
{
    if (self.running) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"测试写入权限"
        message:@"在目标目录创建并写入一个测试文件，同时测试 com.apple.MobileGestalt.plist 能否以写方式打开。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = @"/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.keyboardType = UIKeyboardTypeURL;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
        style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"开始测试"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            NSString *directory = alert.textFields.firstObject.text;
            [weakSelf startWriteTest:directory];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)startWriteTest:(NSString *)directory
{
    if (!directory.length || self.running) return;
    self.running = YES;
    [self flash:@"写入测试进行中（会尝试多组组合）…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error = nil;
        NSDictionary *result = BadQueryProbeWriteTest(directory, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.running = NO;
            NSMutableString *text = [NSMutableString string];
            for (NSString *key in @[@"Directory", @"ProbePath", @"ConsumeHandle",
                                    @"CreateOpenOK", @"CreateOpenErrno", @"WriteOK",
                                    @"WriteErrno", @"PlistOpenWriteOK",
                                    @"PlistOpenWriteErrno", @"Status", @"Error"]) {
                id value = result[key];
                if (value) [text appendFormat:@"%@: %@\n", key, value];
            }
            if (error) [text appendFormat:@"Error: %@\n", error];
            [self presentText:@"写入权限测试" body:text];
        });
    });
}

- (void)presentProbeDetail:(NSDictionary *)probe
{
    NSMutableString *text = [NSMutableString string];
    for (NSString *key in @[@"Name", @"Path", @"Status", @"Stage", @"Error", @"Class",
                            @"GroupIdentifier", @"Traversal", @"Flags", @"Handle",
                            @"Readable", @"Openable", @"StatOk", @"IsDirectory", @"ChildCount"]) {
        id value = probe[key];
        if (value) [text appendFormat:@"%@: %@\n", key, value];
    }
    [self presentText:probe[@"Name"] ?: @"Probe" body:text];
}

#pragma mark - Helpers

- (void)presentText:(NSString *)title body:(NSString *)body
{
    UIViewController *viewer = [UIViewController new];
    viewer.title = title;
    UITextView *textView = [[UITextView alloc] initWithFrame:viewer.view.bounds];
    textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    textView.editable = NO;
    textView.selectable = YES;
    textView.font = [UIFont fontWithName:@"Menlo" size:12];
    textView.text = body;
    [viewer.view addSubview:textView];
    [self.navigationController pushViewController:viewer animated:YES];
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
