#import "FFTasksViewController.h"
#import "FFFileTask.h"
#import "FFFileTaskManager.h"
#import "FFLogger.h"
#import "FFPreviewRouter.h"
#import "FFStorageEnvironment.h"

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

    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(taskManagerChanged:)
        name:FFFileTaskManagerDidChangeNotification object:nil];
    [self reloadTasks];
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)taskManagerChanged:(NSNotification *)note
{
    (void)note;
    if (NSThread.isMainThread) [self reloadTasks];
    else dispatch_async(dispatch_get_main_queue(), ^{ [self reloadTasks]; });
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
    FFFileTask *task = [self taskAtIndexPath:indexPath];
    if (!task) return cell;
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
    else if (task.state == FFFileTaskStateFailed) {
        [detail appendString:task.error.localizedDescription ?: @"失败"];
        if ([self taskHasResumeData:task]) [detail appendString:@"（已保留断点，可继续）"];
    }
    else {
        [detail appendString:task.stateText];
        if ([self taskHasResumeData:task]) [detail appendString:@"（可继续下载）"];
    }

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
        cell.accessoryType = UITableViewCellAccessoryNone;
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
        // 已完成的记录可点进所在目录：给出可点提示（失败/取消不给）。
        cell.accessoryType = task.state == FFFileTaskStateCompleted
            ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
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

// 进度通知每 ~0.15s reloadData，滑动/回调里的旧 indexPath 可能已越界；
// 统一取值入口，越界返回 nil（删除操作尤其需要，避免删错任务）。
- (FFFileTask *)taskAtIndexPath:(NSIndexPath *)indexPath
{
    NSArray<FFFileTask *> *rows = indexPath.section == 0 ? self.activeTasks : self.historyTasks;
    if (indexPath.row < 0 || (NSUInteger)indexPath.row >= rows.count) return nil;
    return rows[(NSUInteger)indexPath.row];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    FFFileTask *task = [self taskAtIndexPath:indexPath];
    if (!task) return;
    FFLogTag(@"Tasks", @"reveal tap state=%ld kind=%ld destination=%@ detail=%@",
        (long)task.state, (long)task.kind, task.destination ?: @"(nil)",
        task.detailName ?: @"(nil)");
    // 只有成功完成的任务才有可跳转的落盘结果；其余给个明确反馈，避免点了没反应。
    if (task.state != FFFileTaskStateCompleted) {
        NSString *message = (task.state == FFFileTaskStateRunning ||
            task.state == FFFileTaskStateQueued)
            ? @"任务还在进行中" : @"任务未完成，没有可跳转的文件";
        [FFPreviewRouter toastOnNav:self.navigationController message:message];
        return;
    }
    NSString *note = nil;
    NSString *path = [self revealPathForTask:task note:&note];
    if (!path.length) {
        [FFPreviewRouter toastOnNav:self.navigationController message:@"目标文件已不存在"];
        return;
    }
    if (self.revealHandler) {
        self.revealHandler(path, note);
        return;
    }
    // 理论上所有入口都经 FFRootTabBarController 接线；走到这里说明有入口漏了。
    FFLogTag(@"Tasks", @"reveal handler missing path=%@", path);
    [FFPreviewRouter toastOnNav:self.navigationController message:@"无法跳转（缺少导航接线）"];
}

// 已完成任务对应的落盘路径：
//   下载 → 目标目录 + 实际文件名（detailName，另兜底 URL 尾段）
//   复制/移动 → 单源时定位复制出的那个文件，多源时只打开目标目录
//   解压 → 解压出来的目录本身；压缩 → 生成的压缩包文件
// 目标文件缺失但所在目录还在时：打开目录并通过 note 说明（不再静默无反应）。
// 文件/目录都已不存在返回 nil。
- (nullable NSString *)revealPathForTask:(FFFileTask *)task note:(NSString **)noteOut
{
    NSFileManager *manager = NSFileManager.defaultManager;
    // 存档里的绝对路径可能来自旧容器（更新/重装后容器 UUID 变化）：映射回当前容器。
    NSString *destination = FFCanonicalStoragePath(task.destination ?: @"");
    BOOL destinationExists = [manager fileExistsAtPath:destination];
    NSString *resolved = nil;
    NSString *note = nil;
    switch (task.kind) {
        case FFFileTaskKindDownload: {
            for (NSString *name in [self downloadCandidateNamesForTask:task]) {
                NSString *candidate = [destination stringByAppendingPathComponent:name];
                if ([manager fileExistsAtPath:candidate]) { resolved = candidate; break; }
            }
            if (!resolved && destinationExists) {
                resolved = destination;
                note = [NSString stringWithFormat:@"未找到 %@，已打开所在目录",
                    task.detailName ?: @"下载文件"];
            }
            break;
        }
        case FFFileTaskKindCopy:
        case FFFileTaskKindMove:
            if (task.sources.count == 1 && destination.length) {
                NSString *candidate = [destination stringByAppendingPathComponent:
                    task.sources.firstObject.lastPathComponent];
                if ([manager fileExistsAtPath:candidate]) resolved = candidate;
            }
            if (!resolved && destinationExists) resolved = destination;
            break;
        case FFFileTaskKindExtract:
            if (destinationExists) resolved = destination;
            break;
        case FFFileTaskKindCompress: {
            if (destinationExists) {
                resolved = destination;
                break;
            }
            NSString *parent = destination.stringByDeletingLastPathComponent;
            if (destination.length && [manager fileExistsAtPath:parent]) {
                resolved = parent;
                note = [NSString stringWithFormat:@"未找到 %@，已打开所在目录",
                    destination.lastPathComponent];
            }
            break;
        }
    }
    if (!resolved) {
        FFLogTag(@"Tasks", @"reveal missing kind=%ld destination=%@ name=%@",
            (long)task.kind, task.destination ?: @"(nil)", task.detailName ?: @"(nil)");
    }
    if (noteOut) *noteOut = note;
    return resolved;
}

- (NSArray<NSString *> *)downloadCandidateNamesForTask:(FFFileTask *)task
{
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if (task.detailName.length) [names addObject:task.detailName];
    NSString *urlName = [NSURL URLWithString:task.remoteURL ?: @""].lastPathComponent;
    if (urlName.length && ![names containsObject:urlName]) [names addObject:urlName];
    return names;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    FFFileTask *task = [self taskAtIndexPath:indexPath];
    if (!task) return;
    [[FFFileTaskManager sharedManager] removeTask:task];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    FFFileTask *task = [self taskAtIndexPath:indexPath];
    if (!task) return NO;
    return task.state != FFFileTaskStateRunning && task.state != FFFileTaskStateQueued;
}

- (BOOL)taskHasResumeData:(FFFileTask *)task
{
    return task.kind == FFFileTaskKindDownload && task.resumeData.length > 0;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    FFFileTask *task = [self taskAtIndexPath:indexPath];
    if (!task) return nil;
    if (task.state != FFFileTaskStateFailed && task.state != FFFileTaskStateCancelled) return nil;
    BOOL resumable = [self taskHasResumeData:task];
    UIContextualAction *retry = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
        title:(resumable ? @"继续" : @"重试")
        handler:^(__unused UIContextualAction *action, __unused UIView *sourceView, void (^completionHandler)(BOOL)) {
            [[FFFileTaskManager sharedManager] retryTask:task];
            completionHandler(YES);
        }];
    retry.image = [UIImage systemImageNamed:(resumable ? @"arrow.down.circle" : @"arrow.clockwise")];
    retry.backgroundColor = UIColor.systemBlueColor;
    return [UISwipeActionsConfiguration configurationWithActions:@[retry]];
}

- (NSString *)formatSize:(unsigned long long)bytes
{
    return [NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleFile];
}

@end