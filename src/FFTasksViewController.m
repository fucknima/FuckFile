#import "FFTasksViewController.h"
#import "FFFileTask.h"
#import "FFFileTaskManager.h"

#import <objc/runtime.h>

@interface FFTasksViewController ()
@property(nonatomic, strong) NSArray<FFFileTask *> *tasks;
@property(nonatomic, strong) NSArray<FFFileTask *> *activeTasks;
@property(nonatomic, strong) NSArray<FFFileTask *> *historyTasks;
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
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"清除已完成" style:UIBarButtonItemStylePlain
        target:self action:@selector(clearCompletedTapped)];

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
    NSMutableArray<FFFileTask *> *active = [NSMutableArray array];
    NSMutableArray<FFFileTask *> *history = [NSMutableArray array];
    for (FFFileTask *task in self.tasks) {
        if (task.state == FFFileTaskStateRunning || task.state == FFFileTaskStateQueued)
            [active addObject:task];
        else
            [history addObject:task];
    }
    self.activeTasks = active;
    self.historyTasks = history;
    self.navigationItem.rightBarButtonItem.enabled = history.count > 0;
    [self updateEmptyState];
    [self.tableView reloadData];
}

- (void)clearCompletedTapped
{
    if (self.historyTasks.count == 0) return;
    [[FFFileTaskManager sharedManager] removeTasks:self.historyTasks];
}

- (void)updateEmptyState
{
    BOOL empty = self.activeTasks.count == 0 && self.historyTasks.count == 0;
    if (!empty) {
        self.tableView.backgroundView = nil;
        return;
    }

    UIView *container = [UIView new];
    container.backgroundColor = UIColor.clearColor;

    UIImageView *imageView = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:@"clock.arrow.circlepath"]];
    imageView.translatesAutoresizingMaskIntoConstraints = NO;
    imageView.tintColor = UIColor.secondaryLabelColor;
    imageView.contentMode = UIViewContentModeScaleAspectFit;

    UILabel *titleLabel = [UILabel new];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = @"还没有任务";
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    titleLabel.adjustsFontForContentSizeCategory = YES;

    UILabel *detailLabel = [UILabel new];
    detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    detailLabel.text = @"复制、移动、压缩、解压等操作会显示在这里";
    detailLabel.textAlignment = NSTextAlignmentCenter;
    detailLabel.numberOfLines = 0;
    detailLabel.textColor = UIColor.secondaryLabelColor;
    detailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    detailLabel.adjustsFontForContentSizeCategory = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        imageView, titleLabel, detailLabel
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 10;
    [container addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [imageView.widthAnchor constraintEqualToConstant:44],
        [imageView.heightAnchor constraintEqualToConstant:44],
        [detailLabel.widthAnchor constraintLessThanOrEqualToConstant:360],
        [stack.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:container.centerYAnchor constant:-40],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:container.leadingAnchor constant:32],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor constant:-32],
    ]];
    self.tableView.backgroundView = container;
}

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return 2; }

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return section == 0 ? (NSInteger)self.activeTasks.count : (NSInteger)self.historyTasks.count;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0) return self.activeTasks.count ? @"进行中" : nil;
    return self.historyTasks.count ? @"历史" : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Task"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"Task"];
    FFFileTask *task = indexPath.section == 0 ? self.activeTasks[indexPath.row] : self.historyTasks[indexPath.row];
    cell.accessoryView = nil;
    UIListContentConfiguration *config = [cell defaultContentConfiguration];
    config.text = task.displayName;
    config.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    config.textProperties.adjustsFontForContentSizeCategory = YES;
    config.textProperties.numberOfLines = 1;

    NSMutableString *detail = [NSMutableString string];
    if (task.state == FFFileTaskStateRunning) [detail appendString:(task.detailName.length ? task.detailName : @"…")];
    else if (task.state == FFFileTaskStateCompleted)
        [detail appendFormat:@"已完成 · 成功 %lu 失败 %lu 跳过 %lu", (unsigned long)task.succeededCount,
            (unsigned long)task.failedCount, (unsigned long)task.skippedCount];
    else if (task.state == FFFileTaskStateFailed) [detail appendString:task.error.localizedDescription ?: @"失败"];
    else [detail appendString:task.stateText];

    NSMutableString *metrics = [NSMutableString stringWithFormat:@"%@", task.kindText];
    if (task.state == FFFileTaskStateRunning) {
        if (task.totalBytes > 0)
            [metrics appendFormat:@" · %@ / %@", [self formatSize:task.completedBytes], [self formatSize:task.totalBytes]];
        if (task.averageBytesPerSecond > 0) {
            [metrics appendFormat:@" · %@/s", [self formatSize:(unsigned long long)task.averageBytesPerSecond]];
            NSTimeInterval seconds = task.estimatedRemainingSeconds;
            if (seconds > 0)
                [metrics appendFormat:seconds < 60 ? @" · 剩余 %d 秒" : @" · 剩余 %d 分",
                    seconds < 60 ? (int)seconds : (int)(seconds / 60)];
        }
    }
    config.secondaryText = metrics.length ? [NSString stringWithFormat:@"%@\n%@", detail, metrics] : detail;
    config.secondaryTextProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    config.secondaryTextProperties.adjustsFontForContentSizeCategory = YES;
    config.secondaryTextProperties.numberOfLines = 2;
    cell.contentConfiguration = config;

    BOOL active = task.state == FFFileTaskStateRunning || task.state == FFFileTaskStateQueued;
    cell.selectionStyle = active ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
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
    }
    return cell;
}

- (UIButton *)cancelButtonForTask:(FFFileTask *)task
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(0, 0, 44, 32);
    [button setTitle:@"取消" forState:UIControlStateNormal];
    [button addTarget:self action:@selector(cancelTapped:) forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(button, "ff.task", task, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return button;
}

- (void)cancelTapped:(UIButton *)button
{
    FFFileTask *task = objc_getAssociatedObject(button, "ff.task");
    if (task) [[FFFileTaskManager sharedManager] cancelTask:task];
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    FFFileTask *task = indexPath.section == 0 ? self.activeTasks[indexPath.row] : self.historyTasks[indexPath.row];
    [[FFFileTaskManager sharedManager] removeTask:task];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    FFFileTask *task = indexPath.section == 0 ? self.activeTasks[indexPath.row] : self.historyTasks[indexPath.row];
    return task.state != FFFileTaskStateRunning && task.state != FFFileTaskStateQueued;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    FFFileTask *task = indexPath.section == 0 ? self.activeTasks[indexPath.row] : self.historyTasks[indexPath.row];
    if (task.state != FFFileTaskStateFailed && task.state != FFFileTaskStateCancelled) return nil;
    UIContextualAction *retry = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"重试"
        handler:^(__unused UIContextualAction *action, __unused UIView *sourceView, void (^completionHandler)(BOOL)) {
            [[FFFileTaskManager sharedManager] retryTask:task];
            completionHandler(YES);
        }];
    retry.image = [UIImage systemImageNamed:@"arrow.clockwise"];
    retry.backgroundColor = UIColor.systemBlueColor;
    return [UISwipeActionsConfiguration configurationWithActions:@[retry]];
}

- (NSString *)formatSize:(unsigned long long)bytes
{
    return [NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleFile];
}

@end
