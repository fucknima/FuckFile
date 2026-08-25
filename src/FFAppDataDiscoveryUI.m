#import "FFHomeViewController.h"
#import "FFSettingsViewController.h"
#import "FFAppDataScanCoordinator.h"
#import "FFSystemAccessManager.h"

#import <objc/runtime.h>

#pragma mark - Home scan status

@implementation FFHomeViewController (FFAppDataDiscoveryUI)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method original = class_getInstanceMethod(self,
            @selector(tableView:cellForRowAtIndexPath:));
        Method replacement = class_getInstanceMethod(self,
            @selector(ff_discovery_tableView:cellForRowAtIndexPath:));
        if (original && replacement) method_exchangeImplementations(original, replacement);
    });
}

- (UITableViewCell *)ff_discovery_tableView:(UITableView *)tableView
                      cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [self ff_discovery_tableView:tableView
                                  cellForRowAtIndexPath:indexPath];
    if (indexPath.section == 0 && indexPath.row == 0 &&
        FFSystemAccessManager.sharedManager.ready) {
        FFAppDataScanCoordinator *scan = FFAppDataScanCoordinator.sharedCoordinator;
        if (scan.scanning && scan.deepScanning) {
            cell.detailTextLabel.text = [NSString stringWithFormat:
                @"高级访问已就绪 · 已发现 %lu 个 App · 后台补漏扫描中…",
                (unsigned long)scan.linked];
        }
    }
    return cell;
}

@end

#pragma mark - Explicit exhaustive rediscovery

@implementation FFSettingsViewController (FFAppDataDiscoveryUI)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method cellOriginal = class_getInstanceMethod(self,
            @selector(tableView:cellForRowAtIndexPath:));
        Method cellReplacement = class_getInstanceMethod(self,
            @selector(ff_discovery_settingsTableView:cellForRowAtIndexPath:));
        if (cellOriginal && cellReplacement)
            method_exchangeImplementations(cellOriginal, cellReplacement);

        Method selectOriginal = class_getInstanceMethod(self,
            @selector(tableView:didSelectRowAtIndexPath:));
        Method selectReplacement = class_getInstanceMethod(self,
            @selector(ff_discovery_settingsTableView:didSelectRowAtIndexPath:));
        if (selectOriginal && selectReplacement)
            method_exchangeImplementations(selectOriginal, selectReplacement);
    });
}

- (UITableViewCell *)ff_discovery_settingsTableView:(UITableView *)tableView
                              cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [self ff_discovery_settingsTableView:tableView
                                          cellForRowAtIndexPath:indexPath];
    if (indexPath.section != 4 || indexPath.row != 0) return cell;

    FFAppDataScanCoordinator *scan = FFAppDataScanCoordinator.sharedCoordinator;
    BOOL ready = FFSystemAccessManager.sharedManager.ready;
    BOOL enabled = ready && !scan.scanning;
    cell.textLabel.text = @"完整重新发现 App Data";
    cell.detailTextLabel.text = scan.scanning ? @"扫描进行中，请稍候"
        : (ready ? @"清空补漏缓存并重新验证全部候选" : @"高级系统访问就绪后可用");
    cell.imageView.image = [UIImage systemImageNamed:@"arrow.triangle.2.circlepath"];
    cell.accessoryType = enabled ? UITableViewCellAccessoryDisclosureIndicator
                                 : UITableViewCellAccessoryNone;
    cell.selectionStyle = enabled ? UITableViewCellSelectionStyleDefault
                                  : UITableViewCellSelectionStyleNone;
    cell.textLabel.enabled = enabled;
    cell.detailTextLabel.enabled = enabled;
    return cell;
}

- (void)ff_discovery_settingsTableView:(UITableView *)tableView
               didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section != 4 || indexPath.row != 0) {
        [self ff_discovery_settingsTableView:tableView didSelectRowAtIndexPath:indexPath];
        return;
    }

    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    FFAppDataScanCoordinator *scan = FFAppDataScanCoordinator.sharedCoordinator;
    if (!FFSystemAccessManager.sharedManager.ready || scan.scanning) return;

    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"完整重新发现 App Data？"
        message:@"会清空补漏失败缓存，重新解析 LaunchServices 并验证全部候选。不会删除或修改任何 App 容器里的真实文件。"
        preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"取消"
        style:UIAlertActionStyleCancel handler:nil]];

    __weak typeof(self) weakSelf = self;
    [confirm addAction:[UIAlertAction actionWithTitle:@"开始完整扫描"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [weakSelf.tableView reloadData];
            [scan fullRescanWithCompletion:^{
                [weakSelf.tableView reloadData];
                UIAlertController *done = [UIAlertController alertControllerWithTitle:@"完整扫描完成"
                    message:@"App Data 已完成一次不使用负缓存的全量重新发现。"
                    preferredStyle:UIAlertControllerStyleAlert];
                [done addAction:[UIAlertAction actionWithTitle:@"好"
                    style:UIAlertActionStyleDefault handler:nil]];
                if (weakSelf.view.window)
                    [weakSelf presentViewController:done animated:YES completion:nil];
            }];
        }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

@end
