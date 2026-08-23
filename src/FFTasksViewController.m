#import "FFTasksViewController.h"
#import "FFFileTask.h"
#import "FFFileTaskManager.h"
#import "FFTypography.h"

#import <objc/runtime.h>

@interface FFTasksViewController ()
@property(nonatomic, strong) NSArray<FFFileTask *> *tasks;
@end

@implementation FFTasksViewController

- (instancetype)init
{
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        self.title = @"任务中心";
        self.navigationItem.largeTitleDisplayMode =
            UINavigationItemLargeTitleDisplayModeNever;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 88;

    __weak typeof(self) weakSelf = self;
    [[NSNotificationCenter defaultCenter]
        addObserverForName:FFFileTaskManagerDidChangeNotification object:nil
        queue:[NSOperationQueue mainQueue]
        usingBlock:^(__unused NSNotification *note) {
            [weakSelf reloadTasks];
        }];
    [self reloadTasks];
}

- (void)reloadTasks
{
    self.tasks = [FFFileTaskManager sharedManager].tasks;
    [self.tableView reloadData];
}

#pragma mark - Table view

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)self.tasks.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Task"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"Task"];
    }
    FFFileTask *task = self.tasks[indexPath.row];
    UIListContentConfiguration *config = [cell defaultContentConfiguration];
    config.text = task.displayName;
    config.textProperties.font = FFPreferredFont(UIFontTextStyleBody, UIFontWeightMedium);
    config.textProperties.numberOfLines = 2;
    // 两行信息层级：主行 = 状态/文件/总量；副行 = 速度/ETA 或完成结果。
    NSMutableString *detail = [NSMutableString string];
    if (task.state == FFFileTaskStateRunning) {
        if (task.detailName.length)
            [detail appendString:task.detailName];
        NSString *progressText = task.totalBytes > 0
            ? [NSString stringWithFormat:@"%@ / %@",
                [self formatSize:task.completedBytes], [self formatSize:task.totalBytes]]
            : @"进行中";
        if (detail.length) [detail appendString:@"\n"];
        [detail appendString:progressText];
        if (task.averageBytesPerSecond > 0) {
            [detail appendFormat:@"  ·  %@/s", [self formatSize:(unsigned long long)
                task.averageBytesPerSecond]];
            if (task.estimatedRemainingSeconds > 0) {
                NSTimeInterval seconds = task.estimatedRemainingSeconds;
                [detail appendFormat:@"  ·  剩余 %d 秒", (int)seconds];
            }
        }
    } else if (task.state == FFFileTaskStateCompleted) {
        [detail appendString:@"已完成"];
        if (task.totalBytes > 0)
            [detail appendFormat:@"  ·  %@", [self formatSize:task.completedBytes]];
        [detail appendFormat:@"  ·  %lu 项", (unsigned long)MAX(task.succeededCount, 1u)];
        if (task.failedCount > 0)
            [detail appendFormat:@"  ·  失败 %lu", (unsigned long)task.failedCount];
    } else if (task.state == FFFileTaskStateFailed) {
        [detail appendString:@"失败"];
        if (task.error.localizedDescription.length)
            [detail appendFormat:@"  ·  %@", task.error.localizedDescription];
    } else if (task.state == FFFileTaskStateCancelled) {
        [detail appendString:@"已取消"];
    } else {
        [detail appendString:@"等待中"];
    }
    config.secondaryText = detail;
    config.secondaryTextProperties.font = FFPreferredFont(UIFontTextStyleSubheadline, UIFontWeightRegular);
    config.secondaryTextProperties.numberOfLines = 2;
    cell.contentConfiguration = config;

    BOOL active = task.state == FFFileTaskStateRunning || task.state == FFFileTaskStateQueued;
    cell.selectionStyle = active ? UITableViewCellSelectionStyleNone
                                 : UITableViewCellSelectionStyleDefault;
    if (active) {
        UIProgressView *progress = (UIProgressView *)[cell.contentView viewWithTag:77];
        if (!progress) {
            progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
            progress.tag = 77;
            progress.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:progress];
            [NSLayoutConstraint activateConstraints:@[
                [progress.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
                [progress.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
                [progress.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
            ]];
        }
        progress.hidden = NO;
        progress.progress = (float)task.progress;
        cell.accessoryView = [self cancelButtonForTask:task];
    } else {
        UIProgressView *progress = (UIProgressView *)[cell.contentView viewWithTag:77];
        progress.hidden = YES;
        cell.accessoryView = nil;
    }
    return cell;
}

- (UIButton *)cancelButtonForTask:(FFFileTask *)task
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(0, 0, 44, 32);
    [button setTitle:@"取消" forState:UIControlStateNormal];
    [button addTarget:self action:@selector(cancelTapped:)
      forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(button, "ff.task", task, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return button;
}

- (void)cancelTapped:(UIButton *)button
{
    FFFileTask *task = objc_getAssociatedObject(button, "ff.task");
    if (task) [[FFFileTaskManager sharedManager] cancelTask:task];
}

- (void)tableView:(UITableView *)tableView
    commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
    forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    FFFileTask *task = self.tasks[indexPath.row];
    [[FFFileTaskManager sharedManager] removeTask:task];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    FFFileTask *task = self.tasks[indexPath.row];
    return task.state != FFFileTaskStateRunning && task.state != FFFileTaskStateQueued;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    FFFileTask *task = self.tasks[indexPath.row];
    if (task.state != FFFileTaskStateFailed && task.state != FFFileTaskStateCancelled)
        return nil;
    UIContextualAction *retry = [UIContextualAction contextualActionWithStyle:
        UIContextualActionStyleNormal title:@"重试"
        handler:^(__unused UIContextualAction *action, __unused UIView *sourceView,
            void (^completionHandler)(BOOL)) {
            [[FFFileTaskManager sharedManager] retryTask:task];
            completionHandler(YES);
        }];
    retry.image = [UIImage systemImageNamed:@"arrow.clockwise"];
    retry.backgroundColor = [UIColor systemBlueColor];
    return [UISwipeActionsConfiguration configurationWithActions:@[retry]];
}

- (NSString *)formatSize:(unsigned long long)bytes
{
    return [NSByteCountFormatter stringFromByteCount:(long long)bytes
        countStyle:NSByteCountFormatterCountStyleFile];
}

@end
