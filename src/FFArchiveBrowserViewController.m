#import "FFArchiveBrowserViewController.h"

#import "FFArchiveService.h"
#import "FFZipExtract.h"
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

- (void)showUnsupportedIfKnownFormat
{
    if ([FFArchiveService isGenericArchivePath:self.archivePath] &&
        ![FFArchiveService genericArchiveBackendAvailable]) {
        self.unsupportedMessage = @"当前系统未提供通用归档后端，无法读取 7Z/RAR/TAR/GZ/BZ2/XZ。\n\n"
            "ZIP/IPA 等 ZIP 容器仍可正常使用。";
        return;
    }
    self.unsupportedMessage = nil;
}

- (void)promptForArchivePasswordAfterError:(NSError *)error
{
    BOOL wrong = [error.domain isEqualToString:FFZipExtractErrorDomain] &&
        error.code == FFZipExtractErrorWrongPassword;
    if (wrong) [FFArchiveService clearCachedPasswordForArchivePath:self.archivePath];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"加密压缩包"
        message:wrong ? @"密码错误，请重新输入。密码只保存在本次 App 运行内存中。"
                      : @"需要密码才能读取此压缩包。密码只保存在本次 App 运行内存中。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"密码";
        field.secureTextEntry = YES;
        field.textContentType = UITextContentTypePassword;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
        style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"继续"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            NSString *password = alert.textFields.firstObject.text ?: @"";
            if (!password.length) return;
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [FFArchiveService cachePassword:password forArchivePath:strongSelf.archivePath];
            strongSelf.loadError = nil;
            [strongSelf loadEntries];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
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
                BOOL passwordError = [error.domain isEqualToString:FFZipExtractErrorDomain] &&
                    (error.code == FFZipExtractErrorPasswordRequired ||
                     error.code == FFZipExtractErrorWrongPassword);
                if (passwordError) {
                    [strongSelf.tableView reloadData];
                    [strongSelf promptForArchivePasswordAfterError:error];
                    return;
                }
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
            node.isDirectory = entry.isDirectory;
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
    // 仅根层在异常归档结构下做平铺兜底。进入一个合法的空目录时
    // sorted 也会是 0；旧逻辑会把整个归档平铺进去，看起来像“穿帮”。
    if (sorted.count == 0 && self.entries.count > 0 && self.pathStack.count == 0) {
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
    // 空归档、空文件夹或结构无法展示时给显式状态行，绝不留空白列表。
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
        if (self.pathStack.count > 0) {
            config.image = [UIImage systemImageNamed:@"folder"];
            config.text = @"空文件夹";
            config.secondaryText = @"该文件夹内没有文件";
        } else {
            config.image = [UIImage systemImageNamed:@"exclamationmark.triangle"];
            config.text = @"无法解析包内结构";
            config.secondaryText = @"已读到条目但无法组织为目录，可尝试「全部解压」";
        }
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
    NSMutableSet<NSString *> *directoryPaths = [NSMutableSet set];
    for (NSIndexPath *indexPath in selected) {
        FFArchiveNode *node = self.visibleNodes[(NSUInteger)indexPath.row];
        [paths addObject:node.fullPath];
        if (node.isDirectory) [directoryPaths addObject:node.fullPath];
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
        NSError *rootError = nil;
        if (![manager createDirectoryAtPath:destination
            withIntermediateDirectories:YES attributes:nil error:&rootError]) {
            firstError = rootError;
        }
        for (NSString *entryPath in paths) {
            if (firstError && done == 0 && rootError) break;
            // UI 节点本身最清楚它是不是目录。旧逻辑拿无尾斜杠的
            // node.fullPath 去和 ZIP 中带 "/" 的目录条目精确比较，导致
            // 文件夹被当成普通文件，选择提取文件夹必然失败。
            BOOL isDirectory = [directoryPaths containsObject:entryPath];
            NSArray<NSString *> *targets = isDirectory ?
                [weakSelf childFilesOfDirectory:entryPath] : @[entryPath];
            if (isDirectory && targets.count == 0) {
                NSString *emptyDir = [destination stringByAppendingPathComponent:entryPath];
                NSError *mkdirError = nil;
                if (![manager createDirectoryAtPath:emptyDir
                    withIntermediateDirectories:YES attributes:nil error:&mkdirError] && !firstError)
                    firstError = mkdirError;
                continue;
            }
            for (NSString *target in targets) {
                // 保留包内相对目录结构。
                NSString *relativeFolder = target.stringByDeletingLastPathComponent;
                NSString *subDir = relativeFolder.length ?
                    [destination stringByAppendingPathComponent:relativeFolder]
                    : destination;
                NSError *mkdirError = nil;
                if (![manager createDirectoryAtPath:subDir
                    withIntermediateDirectories:YES attributes:nil error:&mkdirError]) {
                    if (!firstError) firstError = mkdirError;
                    continue;
                }
                NSError *extractError = nil;
                NSString *file = [[FFArchiveService new] extractEntry:target
                    fromArchive:self->_archivePath toDirectory:subDir error:&extractError];
                if (file) done++;
                else if (!firstError) firstError = extractError ?: [NSError errorWithDomain:@"FFArchive"
                    code:-1 userInfo:@{NSLocalizedDescriptionKey: target}];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            NSString *message;
            if (firstError && done == 0)
                message = [NSString stringWithFormat:@"提取失败：%@",
                    firstError.localizedDescription ?: @"未知错误"];
            else if (firstError)
                message = [NSString stringWithFormat:
                    @"已提取 %lu 项，部分失败：%@", (unsigned long)done,
                    firstError.localizedDescription ?: @"未知错误"];
            else
                message = [NSString stringWithFormat:@"已提取 %lu 项到：\n%@",
                    (unsigned long)done, destination];
            UINavigationController *nav = strongSelf.navigationController;
            // 先关掉“正在提取”再弹结果。旧代码直接在 wait 上再 present
            // 一个 alert，UIKit 会拒绝第二次 present，用户看起来像卡住。
            [strongSelf dismissViewControllerAnimated:NO completion:^{
                [strongSelf setEditing:NO animated:YES];
                if (nav) [FFPreviewRouter alertOnNav:nav title:@"提取完成"
                    message:message];
            }];
        });
    });
    [self presentViewController:wait animated:YES completion:nil];
}

// Directory entry → all file entries below it.
- (NSArray<NSString *> *)childFilesOfDirectory:(NSString *)directoryPath
{
    NSString *prefix = [directoryPath hasSuffix:@"/"] ? directoryPath :
        [directoryPath stringByAppendingString:@"/"];
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
    NSString *stem = [FFArchiveService archiveStemForPath:self.archivePath];

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
