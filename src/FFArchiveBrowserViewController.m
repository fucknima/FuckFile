#import "FFArchiveBrowserViewController.h"

#import "FFArchiveService.h"
#import "FFPreviewRouter.h"
#import "FFBrowserViewController.h"   // FFEntry
#import "FFFileTask.h"
#import "FFFileTaskManager.h"
#import "FFLogger.h"

@interface FFArchiveNode : NSObject
@property(nonatomic, copy) NSString *name;      // segment display name
@property(nonatomic, copy) NSString *fullPath;  // full entry path in archive
@property(nonatomic) BOOL isDirectory;
@property(nonatomic) unsigned long long size;
@end

@implementation FFArchiveNode
@end

@interface FFArchiveBrowserViewController ()
@property(nonatomic, copy) NSString *archivePath;
@property(nonatomic, strong) NSArray<FFArchiveEntry *> *entries; // flat listing
@property(nonatomic, strong) NSMutableArray<NSString *> *pathStack; // current folder segments
@property(nonatomic, strong) NSArray<FFArchiveNode *> *visibleNodes;
@property(nonatomic, strong) NSError *loadError;
@property(nonatomic, copy) NSString *unsupportedMessage;
@property(nonatomic) BOOL loading;
@property(nonatomic, strong) UIBarButtonItem *extractItem;
@property(nonatomic, strong) UIBarButtonItem *moreItem;
@property(nonatomic, copy) NSString *normalTitle;
@end

@implementation FFArchiveBrowserViewController

- (instancetype)initWithArchivePath:(NSString *)path
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _archivePath = [path copy];
        _pathStack = [NSMutableArray array];
        self.title = path.lastPathComponent;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"Entry"];
    self.tableView.allowsMultipleSelectionDuringEditing = YES;
    [self showUnsupportedIfKnownFormat];

    if (!self.unsupportedMessage)
        [self loadEntries];

    // 普通状态只有一个「…」：选择 / 全部解压 / 分享压缩包（ADR-014），
    // 与 Browser 同一套交互语言。进入选择后导航栏变为 取消/全选，
    // 底栏只提供「提取」。
    UIAction *selectAction = [UIAction actionWithTitle:@"选择"
        image:[UIImage systemImageNamed:@"checkmark.circle"]
        identifier:nil handler:^(__unused UIAction *action) { [self setEditing:YES animated:YES]; }];
    UIAction *extractAllAction = [UIAction actionWithTitle:@"全部解压"
        image:[UIImage systemImageNamed:@"shippingbox"]
        identifier:nil handler:^(__unused UIAction *action) { [self extractAll]; }];
    UIAction *shareAction = [UIAction actionWithTitle:@"分享压缩包"
        image:[UIImage systemImageNamed:@"square.and.arrow.up"]
        identifier:nil handler:^(__unused UIAction *action) { [self shareZip]; }];
    self.moreItem = [[UIBarButtonItem alloc] initWithImage:
        [UIImage systemImageNamed:@"ellipsis.circle"]
        style:UIBarButtonItemStylePlain target:nil action:nil];
    self.moreItem.menu = [UIMenu menuWithTitle:@"更多" children:
        @[selectAction, extractAllAction, shareAction]];
    self.moreItem.accessibilityLabel = @"更多操作";
    self.navigationItem.rightBarButtonItems = @[self.moreItem];

    self.extractItem = [[UIBarButtonItem alloc] initWithTitle:@"提取"
        style:UIBarButtonItemStylePlain target:self action:@selector(extractSelected)];
    self.extractItem.enabled = NO;
    self.navigationController.toolbarHidden = YES;
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    // 选择模式打开底栏：离开页面必须收起，避免泄漏到前一个页面。
    self.navigationController.toolbarHidden = YES;
}

// tar/gz/7z/rar/xz/bz2 等默认关联到压缩包浏览器，但当前构建没有解析后端：
// 明确显示暂不支持，绝不拿 ZIP 解析器硬解。
- (void)showUnsupportedIfKnownFormat
{
    NSString *ext = self.archivePath.pathExtension.lowercaseString;
    // tar.gz：pathExtension 只剩 gz，需要看完整后缀。
    NSString *name = self.archivePath.lastPathComponent.lowercaseString;
    if ([name hasSuffix:@".tar.gz"]) ext = @"tar.gz";
    if ([FFArchiveService isKnownButUnsupportedExtension:ext]) {
        self.unsupportedMessage = @"当前构建暂不支持此格式（TAR/GZ/7z/RAR/XZ/BZ2 无解析后端）。\n\n"
            "可以使用「分享」导出后由系统或其他应用处理。";
        return;
    }
    if (![FFArchiveService isZipFamilyExtension:ext]) {
        // 未注册的扩展名也走 zip 尝试（如 docx/app 等 zip 容器），
        // 解析失败时 loadEntries 给出明确错误。
        self.unsupportedMessage = nil;
    }
}

- (void)loadEntries
{
    self.loading = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSArray *entries = [[FFArchiveService new] listEntries:self->_archivePath error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.loading = NO;
            if (!entries && error) {
                strongSelf.loadError = error;
                FFLogTag(@"Archive", @"list FAIL %@ (%@)",
                    strongSelf->_archivePath, error.localizedDescription);
            } else {
                strongSelf.entries = entries ?: @[];
                FFLogTag(@"Archive", @"list %@ entries=%lu",
                    strongSelf->_archivePath, (unsigned long)strongSelf.entries.count);
                [strongSelf rebuildVisibleNodes];
            }
            [strongSelf.tableView reloadData];
        });
    });
}

#pragma mark - Tree building

- (void)rebuildVisibleNodes
{
    NSString *prefix = self.pathStack.count ?
        [[self.pathStack componentsJoinedByString:@"/"] stringByAppendingString:@"/"] : @"";
    NSMutableDictionary<NSString *, FFArchiveNode *> *nodes =
        [NSMutableDictionary dictionary];
    for (FFArchiveEntry *entry in self.entries) {
        if (![entry.entryPath hasPrefix:prefix]) continue;
        NSString *rest = [entry.entryPath substringFromIndex:prefix.length];
        if (rest.length == 0) continue;
        NSRange slash = [rest rangeOfString:@"/"];
        if (slash.location == NSNotFound) {
            // Direct file.
            FFArchiveNode *node = [FFArchiveNode new];
            node.name = rest;
            node.fullPath = [prefix stringByAppendingString:rest];
            node.isDirectory = NO;
            node.size = entry.size;
            nodes[node.fullPath] = node;
            continue;
        }
        // Direct subfolder (deduplicated).
        NSString *segment = [rest substringToIndex:slash.location];
        NSString *fullPath = [prefix stringByAppendingString:segment];
        if (!nodes[fullPath]) {
            FFArchiveNode *node = [FFArchiveNode new];
            node.name = segment;
            node.fullPath = fullPath;
            node.isDirectory = YES;
            nodes[fullPath] = node;
        }
    }
    NSArray *sorted = [nodes.allValues sortedArrayUsingComparator:
        ^NSComparisonResult(FFArchiveNode *a, FFArchiveNode *b) {
            if (a.isDirectory != b.isDirectory)
                return a.isDirectory ? NSOrderedAscending : NSOrderedDescending;
            return [a.name compare:b.name options:NSCaseInsensitiveSearch];
        }];
    // 兜底：有条目但树建不出来（异常归档结构）→ 降级为平铺列表，
    // 保证内容始终可见，绝不给用户一个空白/死胡同页面。
    if (sorted.count == 0 && self.entries.count > 0) {
        NSMutableArray<FFArchiveNode *> *flat = [NSMutableArray array];
        for (FFArchiveEntry *entry in self.entries) {
            FFArchiveNode *node = [FFArchiveNode new];
            node.fullPath = entry.entryPath;
            node.isDirectory = entry.isDirectory;
            node.size = entry.size;
            node.name = entry.entryPath;
            [flat addObject:node];
        }
        sorted = flat;
        FFLogTag(@"Archive", @"tree EMPTY -> flat list (%lu entries)",
            (unsigned long)self.entries.count);
    }
    self.visibleNodes = sorted;

    // Breadcrumb subtitle keeps the current location visible.
    self.title = self.pathStack.count ?
        self.pathStack.lastObject : self.archivePath.lastPathComponent;
}

#pragma mark - Table source

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section
{
    if (self.unsupportedMessage || self.loadError || !self.entries) return 1;
    // 空归档或结构无法展示时给显式状态行，绝不留空白列表。
    if (self.entries.count == 0 || self.visibleNodes.count == 0) return 1;
    return (NSInteger)self.visibleNodes.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Entry"
        forIndexPath:indexPath];

    UIListContentConfiguration *config = [cell defaultContentConfiguration];
    config.textProperties.numberOfLines = 3;
    config.secondaryTextProperties.font =
        [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    cell.contentConfiguration = config;

    if (self.unsupportedMessage) {
        config.image = [UIImage systemImageNamed:@"exclamationmark.triangle"];
        config.text = @"暂不支持此格式";
        config.secondaryText = self.unsupportedMessage;
        cell.contentConfiguration = config;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    if (self.loadError) {
        config.image = [UIImage systemImageNamed:@"xmark.octagon"];
        config.text = @"无法读取归档";
        config.secondaryText = self.loadError.localizedDescription ?: @"未知错误";
        cell.contentConfiguration = config;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    if (self.loading || !self.entries || self.visibleNodes == nil) {
        config.text = @"正在读取归档…";
        cell.contentConfiguration = config;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    if (self.entries.count == 0) {
        config.image = [UIImage systemImageNamed:@"tray"];
        config.text = @"空归档";
        config.secondaryText = @"该压缩包内没有文件";
        cell.contentConfiguration = config;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    if (self.visibleNodes.count == 0) {
        config.image = [UIImage systemImageNamed:@"exclamationmark.triangle"];
        config.text = @"无法解析包内结构";
        config.secondaryText = @"已读到条目但无法组织为目录，可尝试「全部解压」";
        cell.contentConfiguration = config;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }

    FFArchiveNode *node = self.visibleNodes[(NSUInteger)indexPath.row];
    config.textProperties.numberOfLines = 2;
    if (node.isDirectory) {
        config.image = [UIImage systemImageNamed:@"folder"];
        config.text = node.name;
    } else {
        config.image = [UIImage systemImageNamed:@"doc"];
        config.text = node.name;
        config.secondaryText = [NSByteCountFormatter stringFromByteCount:
            (long long)node.size countStyle:NSByteCountFormatterCountStyleFile];
    }
    cell.contentConfiguration = config;
    cell.accessoryType = node.isDirectory ? UITableViewCellAccessoryDisclosureIndicator :
        UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    FFArchiveNode *node = self.visibleNodes.count > (NSUInteger)indexPath.row ?
        self.visibleNodes[(NSUInteger)indexPath.row] : nil;
    if (self.editing) {
        [self updateSelectionTitle];
        return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!node || self.unsupportedMessage || self.loadError || self.loading ||
        !self.entries) return;

    // 平铺降级模式下目录节点名带完整路径，取最后一段作为层级前缀。
    if (node.isDirectory) {
        NSString *segment = node.name;
        if ([segment hasSuffix:@"/"])
            segment = [segment substringToIndex:segment.length - 1];
        segment = segment.lastPathComponent;
        [self.pathStack addObject:segment];
        [self rebuildVisibleNodes];
        [self.tableView reloadData];
        return;
    }
    [self previewEntry:node];
}

- (void)tableView:(__unused UITableView *)tableView didDeselectRowAtIndexPath:(__unused NSIndexPath *)indexPath
{
    if (!self.editing) return;
    [self updateSelectionTitle];
}

#pragma mark - Entry actions

- (void)previewEntry:(FFArchiveNode *)node
{
    UIAlertController *wait = [UIAlertController alertControllerWithTitle:nil
        message:@"正在提取…" preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSString *tempDir = [NSTemporaryDirectory()
            stringByAppendingPathComponent:[[[NSUUID UUID] UUIDString]
                substringToIndex:8]];
        [[NSFileManager defaultManager] createDirectoryAtPath:tempDir
            withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *file = [[FFArchiveService new] extractEntry:node.fullPath
            fromArchive:self->_archivePath toDirectory:tempDir error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            UINavigationController *nav = weakSelf.navigationController;
            if (!nav) return;
            [weakSelf dismissViewControllerAnimated:NO completion:^{
                if (!file) {
                    [FFPreviewRouter alertOnNav:nav title:@"提取失败"
                        message:error.localizedDescription ?: @"未知错误"];
                    return;
                }
                FFEntry *item = [FFEntry new];
                item.name = node.name;
                item.path = file;
                item.isDirectory = NO;
                item.size = node.size;
                [FFPreviewRouter previewItem:item navigationController:nav];
            }];
        });
    });
    [self presentViewController:wait animated:YES completion:nil];
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated
{
    [super setEditing:editing animated:animated];
    [self.tableView setEditing:editing animated:animated];
    if (editing) {
        _normalTitle = self.navigationItem.title;
        UIBarButtonItem *cancel = [[UIBarButtonItem alloc] initWithTitle:@"取消"
            style:UIBarButtonItemStylePlain target:self action:@selector(cancelEditing)];
        self.navigationItem.leftBarButtonItem = cancel;
        UIBarButtonItem *selectAll = [[UIBarButtonItem alloc] initWithTitle:@"全选"
            style:UIBarButtonItemStylePlain target:self action:@selector(selectAllEntries)];
        self.navigationItem.rightBarButtonItems = @[selectAll];
        [self updateSelectionTitle];
        self.toolbarItems = @[self.extractItem];
        self.navigationController.toolbarHidden = NO;
    } else {
        self.navigationItem.leftBarButtonItem = nil;
        self.navigationItem.rightBarButtonItems = @[self.moreItem];
        if (_normalTitle.length) self.navigationItem.title = _normalTitle;
        self.extractItem.enabled = NO;
        self.navigationController.toolbarHidden = YES;
        [self.tableView reloadData];
    }
    [self updateSelectionTitleIfEditing];
}

- (void)cancelEditing
{
    [self setEditing:NO animated:YES];
}

- (void)selectAllEntries
{
    for (NSInteger row = 0; row < (NSInteger)self.visibleNodes.count; row++)
        [self.tableView selectRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]
            animated:NO scrollPosition:UITableViewScrollPositionNone];
    [self updateSelectionTitle];
}

- (void)updateSelectionTitle
{
    if (!self.editing) return;
    NSInteger count = (NSInteger)self.tableView.indexPathsForSelectedRows.count;
    self.navigationItem.title = [NSString stringWithFormat:@"已选 %ld 项", (long)count];
    self.extractItem.enabled = count > 0;
}

- (void)updateSelectionTitleIfEditing
{
    if (self.editing) [self updateSelectionTitle];
}

- (void)shareZip
{
    NSURL *url = [NSURL fileURLWithPath:self.archivePath];
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:@[url] applicationActivities:nil];
    activity.popoverPresentationController.sourceView = self.view;
    activity.popoverPresentationController.sourceRect = CGRectMake(
        self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:activity animated:YES completion:nil];
}

// 提取所选（编辑模式下勾选的条目，含文件夹递归）。
- (void)extractSelected
{
    NSArray<NSIndexPath *> *selected = self.tableView.indexPathsForSelectedRows;
    if (selected.count == 0) return;
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSIndexPath *indexPath in selected) {
        FFArchiveNode *node = self.visibleNodes[(NSUInteger)indexPath.row];
        [paths addObject:node.fullPath];
    }

    NSString *stem = self.archivePath.lastPathComponent.stringByDeletingPathExtension;
    NSString *destination = [self extractionRootForStem:stem.length ? stem : @"archive"];

    UIAlertController *wait = [UIAlertController alertControllerWithTitle:nil
        message:[NSString stringWithFormat:@"正在提取 %lu 项…", (unsigned long)paths.count]
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *firstError = nil;
        NSUInteger done = 0;
        NSFileManager *manager = NSFileManager.defaultManager;
        [manager createDirectoryAtPath:destination
            withIntermediateDirectories:YES attributes:nil error:nil];
        for (NSString *entryPath in paths) {
            // 目录条目：递归提取其下所有文件。
            BOOL isDirectory = NO;
            for (FFArchiveEntry *entry in weakSelf.entries)
                if ([entry.entryPath isEqualToString:entryPath])
                    isDirectory = entry.isDirectory;
            NSArray<NSString *> *targets = isDirectory ?
                [weakSelf childFilesOfDirectory:entryPath] : @[entryPath];
            for (NSString *target in targets) {
                // 保留包内相对目录结构。
                NSString *relativeFolder = target.stringByDeletingLastPathComponent;
                NSString *subDir = relativeFolder.length ?
                    [destination stringByAppendingPathComponent:relativeFolder]
                    : destination;
                [manager createDirectoryAtPath:subDir
                    withIntermediateDirectories:YES attributes:nil error:nil];
                NSString *file = [[FFArchiveService new] extractEntry:target
                    fromArchive:self->_archivePath toDirectory:subDir error:&firstError];
                if (file) done++;
                else if (!firstError) firstError = [NSError errorWithDomain:@"FFArchive"
                    code:-1 userInfo:@{NSLocalizedDescriptionKey: target}];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf setEditing:NO animated:YES];
            NSString *message;
            if (firstError && done == 0)
                message = [NSString stringWithFormat:@"提取失败：%@",
                    firstError.localizedDescription];
            else if (firstError)
                message = [NSString stringWithFormat:
                    @"已提取 %lu 项，部分失败：%@", (unsigned long)done,
                    firstError.localizedDescription];
            else
                message = [NSString stringWithFormat:@"已提取 %lu 项到：\n%@",
                    (unsigned long)done, destination];
            UINavigationController *nav = weakSelf.navigationController;
            if (nav) [FFPreviewRouter alertOnNav:nav title:@"提取完成"
                message:message];
        });
    });
    [self presentViewController:wait animated:YES completion:nil];
}

// Directory entry → all file entries below it.
- (NSArray<NSString *> *)childFilesOfDirectory:(NSString *)directoryPath
{
    NSString *prefix = [directoryPath stringByAppendingString:@"/"];
    NSMutableArray<NSString *> *files = [NSMutableArray array];
    for (FFArchiveEntry *entry in self.entries) {
        if (entry.isDirectory || ![entry.entryPath hasPrefix:prefix]) continue;
        [files addObject:entry.entryPath];
    }
    return files;
}

#pragma mark - Extraction

// 全部解压：复用任务中心既有 ZIP 解压链路。
- (void)extractAll
{
    NSString *stem = self.archivePath.lastPathComponent.stringByDeletingPathExtension;
    if (stem.length == 0) stem = @"archive";

    FFFileTask *task = [FFFileTask new];
    task.kind = FFFileTaskKindExtract;
    task.displayName = [NSString stringWithFormat:@"解压 %@", stem];
    task.sources = @[self.archivePath];
    task.destination = [self extractionRootForStem:stem];
    [[FFFileTaskManager sharedManager] enqueueTask:task];
    [FFPreviewRouter toastOnNav:self.navigationController
        message:[NSString stringWithFormat:@"已加入任务队列：%@", task.displayName]];
}

- (NSString *)extractionRootForStem:(NSString *)stem
{
    NSString *sibling = [self.archivePath.stringByDeletingLastPathComponent
        stringByAppendingPathComponent:[stem stringByAppendingString:@" (解压)"]];
    return sibling;
}

@end
