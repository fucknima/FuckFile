#import "FFTrashViewController.h"

#import "FFLogger.h"
#import "FFTrashService.h"

@interface FFTrashViewController ()
@property(nonatomic, strong) NSArray<FFTrashEntry *> *entries;
@property(nonatomic, strong) UILabel *emptyLabel;
@end

@implementation FFTrashViewController

- (instancetype)init
{
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) self.title = @"回收站";
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64;
    self.emptyLabel = [UILabel new];
    self.emptyLabel.text = @"回收站是空的";
    self.emptyLabel.textColor = UIColor.secondaryLabelColor;
    self.emptyLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.frame = CGRectMake(0, 0, 10, 10);
    self.tableView.backgroundView = self.emptyLabel;
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(reload)
                  forControlEvents:UIControlEventValueChanged];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reload)
        name:FFTrashDidChangeNotification object:nil];
    [self reload];
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)reload
{
    self.entries = [FFTrashService.sharedService entries];
    [self.refreshControl endRefreshing];
    [self.tableView reloadData];
    [self updateEmptyState];
    [self updateBarItems];
}

- (void)updateEmptyState
{
    self.emptyLabel.hidden = self.entries.count > 0;
    self.tableView.backgroundView = self.entries.count ? nil : self.emptyLabel;
}

- (void)updateBarItems
{
    if (self.entries.count == 0) {
        self.navigationItem.rightBarButtonItem = nil;
        return;
    }
    UIAction *empty = [UIAction actionWithTitle:@"清空回收站"
        image:[UIImage systemImageNamed:@"trash.slash"] identifier:nil
        handler:^(__unused UIAction *action) { [self confirmEmpty]; }];
    empty.attributes = UIMenuElementAttributesDestructive;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
        menu:[UIMenu menuWithTitle:@"" children:@[empty]]];
}

- (void)confirmEmpty
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清空回收站"
        message:@"回收站里的项目将被永久删除，无法恢复。"
        preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            NSError *error = nil;
            NSUInteger removed = [FFTrashService.sharedService emptyWithError:&error];
            if (error) [self flash:[NSString stringWithFormat:@"部分失败：%@",
                error.localizedDescription ?: @"未知错误"]];
            else [self flash:[NSString stringWithFormat:@"已永久删除 %lu 项", (unsigned long)removed]];
            [self reload];
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    alert.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)flash:(NSString *)message
{
    UILabel *label = [UILabel new];
    label.text = message;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    label.textColor = UIColor.whiteColor;
    label.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.layer.cornerRadius = 12;
    label.clipsToBounds = YES;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [label.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-24],
        [label.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor constant:-48],
    ]];
    label.alpha = 0;
    [UIView animateWithDuration:0.2 animations:^{ label.alpha = 1; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.2 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.3 animations:^{ label.alpha = 0; }
                completion:^(__unused BOOL finished) { [label removeFromSuperview]; }];
        });
}

#pragma mark - Table

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section
{
    return self.entries.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell"];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"Cell"];
    FFTrashEntry *entry = self.entries[indexPath.row];
    UIListContentConfiguration *config = [cell defaultContentConfiguration];
    config.text = entry.name;
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateStyle = NSDateFormatterMediumStyle;
    formatter.timeStyle = NSDateFormatterShortStyle;
    NSString *size = entry.isDirectory ? @"文件夹" : [NSByteCountFormatter
        stringFromByteCount:(long long)entry.size countStyle:NSByteCountFormatterCountStyleFile];
    config.secondaryText = [NSString stringWithFormat:@"%@ · %@ · 原位置 %@",
        [formatter stringFromDate:entry.deletedAt], size,
        entry.originalPath.stringByDeletingLastPathComponent.lastPathComponent];
    config.secondaryTextProperties.numberOfLines = 1;
    config.image = [UIImage systemImageNamed:entry.isDirectory ? @"folder" : @"doc"];
    cell.contentConfiguration = config;
    return cell;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    FFTrashEntry *entry = self.entries[indexPath.row];
    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"永久删除" handler:^(__unused UIContextualAction *action,
            __unused UIView *sourceView, void (^completion)(BOOL)) {
            NSError *error = nil;
            BOOL ok = [FFTrashService.sharedService removeEntryPermanently:entry error:&error];
            if (!ok) [self flash:error.localizedDescription ?: @"删除失败"];
            completion(ok);
        }];
    return [UISwipeActionsConfiguration configurationWithActions:@[delete]];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    FFTrashEntry *entry = self.entries[indexPath.row];
    UIContextualAction *restore = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
        title:@"恢复" handler:^(__unused UIContextualAction *action,
            __unused UIView *sourceView, void (^completion)(BOOL)) {
            NSString *restored = nil;
            NSError *error = nil;
            BOOL ok = [FFTrashService.sharedService restoreEntry:entry
                restoredPath:&restored error:&error];
            [self flash:ok ? [NSString stringWithFormat:@"已恢复到 %@",
                restored.lastPathComponent] : (error.localizedDescription ?: @"恢复失败")];
            completion(ok);
        }];
    restore.backgroundColor = UIColor.systemGreenColor;
    return [UISwipeActionsConfiguration configurationWithActions:@[restore]];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    // 条目内容不直接打开：先从回收站恢复，避免在只读删除态里产生困惑。
    [self flash:@"左滑可恢复或永久删除"];
}

@end
