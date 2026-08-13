#import "FFTasksViewController.h"
#import "FFFileTask.h"
#import "FFFileTaskManager.h"

#import <objc/runtime.h>

@interface FFTasksViewController ()
@property(nonatomic, strong) NSArray<FFFileTask *> *tasks;
@end

@implementation FFTasksViewController

- (instancetype)init
{
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) self.title = @"任务中心";
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 72;

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
    config.textProperties.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    NSMutableString *detail = [NSMutableString stringWithFormat:@"%@ · %@",
        task.kindText, task.stateText];
    if (task.state == FFFileTaskStateRunning) {
        [detail appendFormat:@" · %@", task.detailName ?: @""];
        if (task.totalBytes > 0)
            [detail appendFormat:@" · %@ / %@",
                [self formatSize:task.completedBytes], [self formatSize:task.totalBytes]];
        if (task.averageBytesPerSecond > 0) {
            [detail appendFormat:@" · %@/s",
                [self formatSize:(unsigned long long)task.averageBytesPerSecond]];
            if (task.estimatedRemainingSeconds > 0) {
                NSTimeInterval seconds = task.estimatedRemainingSeconds;
                if (seconds < 60)
                    [detail appendFormat:@" · 剩余 %d 秒", (int)seconds];
                else
                    [detail appendFormat:@" · 剩余 %d 分", (int)(seconds / 60)];
            }
        }
    } else if (task.state == FFFileTaskStateCompleted || task.state == FFFileTaskStateFailed) {
        [detail appendFormat:@" · 成功 %lu 失败 %lu 跳过 %lu",
            (unsigned long)task.succeededCount, (unsigned long)task.failedCount,
            (unsigned long)task.skippedCount];
        if (task.state == FFFileTaskStateFailed && task.error)
            [detail appendFormat:@"\n%@", task.error.localizedDescription];
    }
    config.secondaryText = detail;
    config.secondaryTextProperties.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    config.secondaryTextProperties.numberOfLines = 0;
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
