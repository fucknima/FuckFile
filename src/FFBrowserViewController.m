#import "FFBrowserViewController.h"
#import "FFCopyEngine.h"
#import "FFConflictPolicy.h"
#import "FFFileTask.h"
#import "FFFileTaskManager.h"
#import "FFFileOperationService.h"
#import "MCMManager.h"
#import "FFLogger.h"
#import "FFAppNames.h"
#import "FFZipExtract.h"
#import "FFTextEditorViewController.h"
#import "FFPlistEditorViewController.h"
#import "FFPdfPreviewViewController.h"
#import "FFPreviewRouter.h"
#import "FFFileAssociationService.h"
#import "FFViewerRegistry.h"
#import "FFPathPolicy.h"
#import "FFThumbnailService.h"
#import "FFBookmarksService.h"

#import <AVKit/AVKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <dirent.h>
#import <fcntl.h>
#import <limits.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <sys/xattr.h>
#import <unistd.h>
#import <objc/runtime.h>

typedef NS_ENUM(NSInteger, FFClipboardMode) {
    FFClipboardModeNone = 0,
    FFClipboardModeCopy,
    FFClipboardModeCut,
};

typedef NS_ENUM(NSInteger, FFSortMode) {
    FFSortModeName = 0,
    FFSortModeSize,
    FFSortModeDate,
    FFSortModeKind,
};

typedef NS_ENUM(NSInteger, FFFilterMode) {
    FFFilterModeAll = 0,
    FFFilterModeImages,
    FFFilterModeVideos,
    FFFilterModeAudio,
    FFFilterModeDocuments,
    FFFilterModeArchives,
    FFFilterModeCode,
};

@implementation FFEntry
@end

// Map well-known bundle identifiers to readable display names; fall back to
// stripping the "com.apple." prefix and camel-case splitting.
@interface FFBrowserViewController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating, UIDocumentInteractionControllerDelegate, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIDocumentPickerDelegate>
@property(nonatomic, copy) NSString *currentPath;
@property(nonatomic, strong) NSArray<FFEntry *> *entries;
@property(nonatomic, strong) NSArray<FFEntry *> *filteredEntries;
@property(nonatomic) BOOL loading;
@property(nonatomic) BOOL hasLoaded;
@property(nonatomic) NSTimeInterval lastAutoReloadTime;
@property(nonatomic, strong) UIRefreshControl *refreshControl;
@property(nonatomic, strong) UIBarButtonItem *pasteItem;
@property(nonatomic, strong) UIBarButtonItem *sortItem;
@property(nonatomic, strong) UIBarButtonItem *editItem;
@property(nonatomic, strong) NSArray<UIBarButtonItem *> *batchToolbarItems;
@property(nonatomic, strong) UISearchController *searchController;
@property(nonatomic, copy) NSString *searchText;
@property(nonatomic) FFSortMode sortMode;
@property(nonatomic) BOOL sortDescending;
@property(nonatomic) FFFilterMode filterMode;
@property(nonatomic, strong) UIBarButtonItem *filterItem;
@property(nonatomic, strong) UIBarButtonItem *moreItem;
@property(nonatomic) BOOL showHiddenFiles;
@property(nonatomic, copy) NSString *batchNormalTitle;
@property(nonatomic, strong) UICollectionView *collectionView;
@property(nonatomic) BOOL gridMode;
@property(nonatomic, copy) NSString *loadError;
@property(nonatomic, strong) FFEntry *interactionItem;
@property(nonatomic, copy) NSString *interactionText;
@end

// Process-wide paste state so Copy in one folder can Paste in another.
static NSArray<NSString *> *gClipboardSources = nil;
static FFClipboardMode gClipboardMode = FFClipboardModeNone;

@implementation FFBrowserViewController

- (instancetype)initWithPath:(NSString *)path
{
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _currentPath = [path copy];
        _showHiddenFiles = [NSUserDefaults.standardUserDefaults
            boolForKey:@"FFSettingsShowHiddenFiles"];
        self.title = path.lastPathComponent.length ? path.lastPathComponent : @"设备存储";
        _sortMode = FFSortModeName;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    // 自建 tableView（基类已从 UITableViewController 改为 UIViewController）。
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds
        style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 58;
    self.tableView.allowsMultipleSelectionDuringEditing = YES;
    [self.view addSubview:self.tableView];
    [self.tableView reloadData];
    // 网格视图懒创建：仅网格模式才实例化 UICollectionView。列表模式下
    // 隐藏的网格仍会参与布局提交（横幅/键盘/菜单动画），是长按操作后
    // flowlayout 断言闪退的源头 —— 不创建就彻底消除这一类崩溃。
    self.gridMode = [NSUserDefaults.standardUserDefaults
        boolForKey:@"FFSettingsGridMode"];
    if (self.gridMode) [self setupCollectionView];
    [self applyLayoutModeAnimated:NO];

    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(reloadEntries)
                  forControlEvents:UIControlEventValueChanged];
    // 普通 UIViewController 需要手动挂载 refreshControl（iOS 10+ 官方方式）。
    [self.tableView addSubview:self.refreshControl];

    // 任务中心变更：有任务落到当前目录（复制/移动/解压/压缩完成）时
    // 自动刷新列表，免去手动下拉。
    __weak typeof(self) weakSelf = self;
    [[NSNotificationCenter defaultCenter]
        addObserverForName:FFFileTaskManagerDidChangeNotification object:nil queue:nil
        usingBlock:^(__unused NSNotification *note) {
            typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            NSArray<FFFileTask *> *tasks = [FFFileTaskManager sharedManager].tasks;
            BOOL affectsHere = NO;
            for (FFFileTask *task in tasks) {
                if (task.destination.length == 0 ||
                    task.state == FFFileTaskStateQueued) continue;
                // 粘贴：目标文件夹就是当前目录；压缩/解压：目标文件/
                // 目录的父级是当前目录。两种情况都刷新。
                if ([task.destination isEqualToString:strongSelf.currentPath] ||
                    [task.destination.stringByDeletingLastPathComponent
                        isEqualToString:strongSelf.currentPath]) {
                    affectsHere = YES;
                    break;
                }
            }
            if (!affectsHere) return;
            // 去抖：通知在进度更新时也会触发，1 秒内只刷一次。
            dispatch_async(dispatch_get_main_queue(), ^{
                NSTimeInterval now = [NSDate date].timeIntervalSince1970;
                if (now - strongSelf.lastAutoReloadTime < 1.0) return;
                strongSelf.lastAutoReloadTime = now;
                if (strongSelf.hasLoaded) [strongSelf reloadEntries];
            });
        }];

    // Reload once the background MCM scan has finished.
    [[NSNotificationCenter defaultCenter] addObserverForName:@"FFProbeFinished"
        object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
            typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf reloadEntries];
            });
        }];

    // Reload when the background LaunchServices confirmation pass installs
    // new MCM App Data links (iOS 26 third-party app discovery).
    [[NSNotificationCenter defaultCenter] addObserverForName:FFMCMAppLinksUpdatedNotification
        object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
            typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (![strongSelf.currentPath hasPrefix:MCMVirtualRoot()]) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf reloadEntries];
            });
        }];

    // 设置页修改（显示隐藏文件等）后，已打开的浏览器页面即时生效。
    [[NSNotificationCenter defaultCenter] addObserverForName:@"FFSettingsChangedNotification"
        object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
            typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                strongSelf.showHiddenFiles = [NSUserDefaults.standardUserDefaults
                    boolForKey:@"FFSettingsShowHiddenFiles"];
                if (strongSelf.moreItem) strongSelf.moreItem.menu = [strongSelf moreMenu];
                [strongSelf reloadEntries];
            });
        }];

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"搜索…";
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;
    self.definesPresentationContext = YES;

    self.pasteItem = [[UIBarButtonItem alloc] initWithTitle:@"粘贴"
        style:UIBarButtonItemStylePlain target:self action:@selector(pasteAction:)];
    self.sortItem = [[UIBarButtonItem alloc] initWithImage:[self symbolImage:@"arrow.up.arrow.down" tint:nil]
        style:UIBarButtonItemStylePlain target:nil action:nil];
    self.sortItem.menu = [self sortMenu];
    self.editItem = [[UIBarButtonItem alloc] initWithTitle:@"多选"
        style:UIBarButtonItemStylePlain target:self action:@selector(toggleBatchMode)];
    self.moreItem = [[UIBarButtonItem alloc] initWithImage:[self symbolImage:@"ellipsis.circle" tint:nil]
        style:UIBarButtonItemStylePlain target:nil action:nil];
    self.moreItem.menu = [self moreMenu];
    // 导航栏只保留搜索和“更多”菜单。
    self.navigationItem.rightBarButtonItems = @[self.moreItem];

    self.filterItem = [[UIBarButtonItem alloc] initWithImage:[self symbolImage:@"line.3.horizontal.decrease.circle" tint:nil]
        style:UIBarButtonItemStylePlain target:nil action:nil];
    self.filterItem.menu = [self filterMenu];
    UIBarButtonItem *addItem = [[UIBarButtonItem alloc] initWithImage:[self symbolImage:@"plus" tint:nil]
        style:UIBarButtonItemStylePlain target:nil action:nil];
    UIAction *newFolder = [UIAction actionWithTitle:@"新建文件夹" image:[self symbolImage:@"folder.badge.plus" tint:nil]
        identifier:nil handler:^(__unused UIAction *action) { [self createFolder]; }];
    UIAction *newFile = [UIAction actionWithTitle:@"新建文件" image:[self symbolImage:@"doc.badge.plus" tint:nil]
        identifier:nil handler:^(__unused UIAction *action) { [self createFile]; }];
    UIAction *refresh = [UIAction actionWithTitle:@"刷新" image:[self symbolImage:@"arrow.clockwise" tint:nil]
        identifier:nil handler:^(__unused UIAction *action) { [self reloadEntries]; }];
    addItem.menu = [UIMenu menuWithTitle:@"新建" children:@[newFolder, newFile, refresh]];
    self.toolbarItems = @[
        self.filterItem,
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil],
        addItem,
    ];
    self.navigationController.toolbarHidden = NO;

    [self updatePasteState];
    [self reloadEntries];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self updatePasteState];
    // 剪贴板是全局的：切到任何文件夹都恢复横幅与菜单状态。
    if (gClipboardSources.count > 0) [self showPasteBanner];
    if (self.moreItem) self.moreItem.menu = [self moreMenu];
    if (self.hasLoaded) [self reloadEntries];
    self.navigationController.toolbarHidden = NO;
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    self.navigationController.toolbarHidden = YES;
}

#pragma mark - Clipboard state

- (void)updatePasteState
{
    self.pasteItem.enabled = (gClipboardSources.count > 0) && ![self pasteIsInsideClipboardSource];
}

- (BOOL)pasteIsInsideClipboardSource
{
    if (gClipboardSources.count == 0) return NO;
    for (NSString *source in gClipboardSources) {
        struct stat status = {0};
        if (lstat(source.fileSystemRepresentation, &status) != 0 || !S_ISDIR(status.st_mode))
            continue;
        char sourceReal[PATH_MAX] = {0};
        char destinationReal[PATH_MAX] = {0};
        if (!realpath(source.fileSystemRepresentation, sourceReal) ||
            !realpath(self.currentPath.fileSystemRepresentation, destinationReal)) continue;
        NSString *sourcePath = [NSString stringWithUTF8String:sourceReal];
        NSString *destinationPath = [NSString stringWithUTF8String:destinationReal];
        if ([destinationPath isEqualToString:sourcePath] ||
            [destinationPath hasPrefix:[sourcePath stringByAppendingString:@"/"]])
            return YES;
    }
    return NO;
}

// 源文件正好来自当前目录（剪切模式同目录粘贴的致命场景）。
- (NSArray<NSString *> *)clipboardSourcesInCurrentDirectory
{
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    NSString *myDirectory = self.currentPath;
    for (NSString *source in gClipboardSources) {
        if ([source.stringByDeletingLastPathComponent isEqualToString:myDirectory])
            [result addObject:source];
    }
    return result;
}

#pragma mark - Batch mode (multi-select)

- (void)toggleBatchMode
{
    [self setEditing:!self.editing animated:YES];
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated
{
    // 基类已是 UIViewController：editing 状态必须手动同步到 tableView。
    [super setEditing:editing animated:animated];
    [self.tableView setEditing:editing animated:animated];
    self.editItem.title = editing ? @"完成" : @"多选";
    if (editing) {
        // 导航栏：左侧“取消”，右侧“全选”；标题显示已选数量。
        _batchNormalTitle = self.navigationItem.title;
        UIBarButtonItem *cancel = [[UIBarButtonItem alloc] initWithTitle:@"取消"
            style:UIBarButtonItemStylePlain target:self action:@selector(cancelBatchMode)];
        self.navigationItem.leftBarButtonItem = cancel;
        UIBarButtonItem *selectAll = [[UIBarButtonItem alloc] initWithTitle:@"全选"
            style:UIBarButtonItemStylePlain target:self action:@selector(batchSelectAll)];
        self.navigationItem.rightBarButtonItems = @[selectAll];
        [self updateSelectionTitle];
        if (!self.batchToolbarItems)
            self.batchToolbarItems = [self buildBatchToolbarItems];
        self.toolbarItems = self.batchToolbarItems;
    } else {
        self.navigationItem.leftBarButtonItem = nil;
        self.navigationItem.rightBarButtonItems = @[self.moreItem];
        if (_batchNormalTitle.length) self.navigationItem.title = _batchNormalTitle;
        UIBarButtonItem *addItem = [[UIBarButtonItem alloc] initWithImage:[self symbolImage:@"plus" tint:nil]
            style:UIBarButtonItemStylePlain target:nil action:nil];
        UIAction *newFolder = [UIAction actionWithTitle:@"新建文件夹" image:[self symbolImage:@"folder.badge.plus" tint:nil]
            identifier:nil handler:^(__unused UIAction *action) { [self createFolder]; }];
        UIAction *newFile = [UIAction actionWithTitle:@"新建文件" image:[self symbolImage:@"doc.badge.plus" tint:nil]
            identifier:nil handler:^(__unused UIAction *action) { [self createFile]; }];
        UIAction *refresh = [UIAction actionWithTitle:@"刷新" image:[self symbolImage:@"arrow.clockwise" tint:nil]
            identifier:nil handler:^(__unused UIAction *action) { [self reloadEntries]; }];
        addItem.menu = [UIMenu menuWithTitle:@"新建" children:@[newFolder, newFile, refresh]];
        self.toolbarItems = @[
            self.filterItem,
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil],
            addItem,
        ];
    }
    [self updatePasteState];
    [self applyLayoutModeAnimated:NO];
}

- (void)cancelBatchMode
{
    [self setEditing:NO animated:YES];
}

- (NSArray<UIBarButtonItem *> *)buildBatchToolbarItems
{
    // 图标按钮代替长文本：6 个中文标题在窄屏会被截断（分享/删除溢出）。
    UIBarButtonItem *selectAll = [[UIBarButtonItem alloc] initWithImage:[self symbolImage:@"checkmark.circle" tint:nil]
        style:UIBarButtonItemStylePlain target:self action:@selector(batchSelectAll)];
    selectAll.accessibilityLabel = @"全选";
    UIBarButtonItem *copy = [[UIBarButtonItem alloc] initWithImage:[self symbolImage:@"doc.on.doc" tint:nil]
        style:UIBarButtonItemStylePlain target:self action:@selector(batchCopy)];
    copy.accessibilityLabel = @"复制";
    UIBarButtonItem *cut = [[UIBarButtonItem alloc] initWithImage:[self symbolImage:@"scissors" tint:nil]
        style:UIBarButtonItemStylePlain target:self action:@selector(batchCut)];
    cut.accessibilityLabel = @"剪切";
    UIBarButtonItem *zip = [[UIBarButtonItem alloc] initWithImage:[self symbolImage:@"shippingbox" tint:nil]
        style:UIBarButtonItemStylePlain target:self action:@selector(batchCompress)];
    zip.accessibilityLabel = @"压缩";
    UIBarButtonItem *share = [[UIBarButtonItem alloc] initWithImage:[self symbolImage:@"square.and.arrow.up" tint:nil]
        style:UIBarButtonItemStylePlain target:self action:@selector(batchShare)];
    share.accessibilityLabel = @"分享";
    UIBarButtonItem *trash = [[UIBarButtonItem alloc] initWithImage:[self symbolImage:@"trash" tint:nil]
        style:UIBarButtonItemStylePlain target:self action:@selector(batchDelete)];
    trash.tintColor = [UIColor systemRedColor];
    trash.accessibilityLabel = @"删除";
    return @[selectAll, copy, cut, zip, share, trash];
}

- (NSArray<FFEntry *> *)selectedBatchEntries
{
    NSArray<NSIndexPath *> *indexPaths = self.tableView.indexPathsForSelectedRows;
    NSMutableArray<FFEntry *> *items = [NSMutableArray arrayWithCapacity:indexPaths.count];
    for (NSIndexPath *indexPath in indexPaths)
        if (indexPath.row < self.filteredEntries.count)
            [items addObject:self.filteredEntries[indexPath.row]];
    return items;
}

- (void)batchSelectAll
{
    for (NSUInteger row = 0; row < self.filteredEntries.count; row++)
        [self.tableView selectRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]
            animated:NO scrollPosition:UITableViewScrollPositionNone];
    [self updateSelectionTitle];
    [self updatePasteState];
}

- (void)batchCopy
{
    [self batchSetClipboard:FFClipboardModeCopy];
}

- (void)batchCut
{
    [self batchSetClipboard:FFClipboardModeCut];
}

- (void)batchSetClipboard:(FFClipboardMode)mode
{
    NSArray<FFEntry *> *items = [self selectedBatchEntries];
    if (items.count == 0) {
        [self flash:@"未选择任何项目"];
        return;
    }
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:items.count];
    for (FFEntry *item in items) [paths addObject:item.path];
    gClipboardSources = paths;
    gClipboardMode = mode;
    [self setEditing:NO animated:YES];
    [self updatePasteState];
    if (self.moreItem) self.moreItem.menu = [self moreMenu];
    [self showPasteBanner];
}

- (void)batchCompress
{
    NSArray<FFEntry *> *items = [self selectedBatchEntries];
    if (items.count == 0) {
        [self flash:@"未选择任何项目"];
        return;
    }
    [self setEditing:NO animated:YES];
    [self compressEntries:items];
}

- (void)compressEntries:(NSArray<FFEntry *> *)items
{
    NSString *defaultName = items.count == 1
        ? [NSString stringWithFormat:@"%@.zip", items.firstObject.name]
        : @"归档.zip";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"压缩"
        message:[NSString stringWithFormat:@"%lu 个项目，压缩到当前目录",
            (unsigned long)items.count]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = defaultName;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"压缩" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            NSString *name = alert.textFields.firstObject.text ?: defaultName;
            if (![weakSelf validNewName:name]) return;
            if (![name.pathExtension.lowercaseString isEqualToString:@"zip"])
                name = [name stringByAppendingPathExtension:@"zip"];
            NSString *destination = [weakSelf.currentPath stringByAppendingPathComponent:name];
            NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:items.count];
            for (FFEntry *item in items) [paths addObject:item.path];
            FFFileTask *task = [FFFileTask new];
            task.kind = FFFileTaskKindCompress;
            task.displayName = [NSString stringWithFormat:@"压缩 %@", name];
            task.sources = paths;
            task.destination = destination;
            [[FFFileTaskManager sharedManager] enqueueTask:task];
            [weakSelf flash:[NSString stringWithFormat:@"已加入任务队列：%@", task.displayName]];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)batchShare
{
    NSArray<FFEntry *> *items = [self selectedBatchEntries];
    if (items.count == 0) {
        [self flash:@"未选择任何项目"];
        return;
    }
    NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithCapacity:items.count];
    for (FFEntry *item in items) [urls addObject:[NSURL fileURLWithPath:item.path]];
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:urls applicationActivities:nil];
    activity.popoverPresentationController.sourceView = self.view;
    activity.popoverPresentationController.sourceRect = CGRectMake(
        self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:activity animated:YES completion:nil];
    [self setEditing:NO animated:YES];
}

- (void)batchDelete
{
    NSArray<FFEntry *> *items = [self selectedBatchEntries];
    if (items.count == 0) {
        [self flash:@"未选择任何项目"];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"删除"
        message:[NSString stringWithFormat:@"确定删除 %lu 个项目？", (unsigned long)items.count]
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:items.count];
            for (FFEntry *item in items) [paths addObject:item.path];
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSError *error = nil;
                NSUInteger removed = [[FFFileOperationService sharedService]
                    removeItemsAtPaths:paths firstError:&error];
                NSUInteger failed = (NSUInteger)(paths.count - removed);
                if (error)
                    FFLogTag(@"Browser", @"batch delete FAIL path=%@ error=%@",
                             error.userInfo[NSFilePathErrorKey] ?: @"?", error);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf flash:failed == 0 ? @"删除完成"
                        : [NSString stringWithFormat:@"删除完成，%lu 个失败", (unsigned long)failed]];
                    [weakSelf setEditing:NO animated:YES];
                    [weakSelf reloadEntries];
                });
            });
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Loading

- (void)reloadEntries
{
    if (self.loading) return;
    self.loading = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // MHA is the only channel: every link in the MCM folders was
        // activated at startup, so its token already covers the target.
        // No per-directory extension consumption is needed.
        NSString *linkTarget = [self symlinkTargetOfPath:self.currentPath];
        if (linkTarget.length) {
            BOOL mhaCovered = [[MCMManager sharedManager] hasActiveLeaseForPath:linkTarget];
            FFLogTag(@"Browser", @"target=%@ mha-lease-covered=%d",
                     linkTarget, mhaCovered);
        }
        NSArray<FFEntry *> *loaded = [self loadDirectoryContents];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.entries = loaded;
            self.hasLoaded = YES;
            self.loading = NO;
            [self applyFilter];
            [self.tableView reloadData];
            if (self.collectionView) [self.collectionView reloadData];
            [self.refreshControl endRefreshing];
            [self updateEmptyState];
            [self applyLayoutModeAnimated:NO];
        });
    });
}

// 空状态视图：空目录 / 加载失败（权限错误等），替代普通弹窗。
- (void)updateEmptyState
{
    UIView *emptyView = nil;
    if (self.loading) {
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
            initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [spinner startAnimating];
        spinner.frame = CGRectMake(0, 0, 44, 44);
        emptyView = spinner;
    } else if (self.loadError.length) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0,
            self.view.bounds.size.width - 80, 120)];
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 0;
        label.textColor = [UIColor secondaryLabelColor];
        label.text = [NSString stringWithFormat:@"无法打开目录\n\n%@\n\n下拉可重试",
            self.loadError];
        label.font = [UIFont systemFontOfSize:14];
        emptyView = label;
    } else if (self.filteredEntries.count == 0) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0,
            self.view.bounds.size.width - 80, 80)];
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 0;
        label.textColor = [UIColor secondaryLabelColor];
        label.text = @"此文件夹为空";
        label.font = [UIFont systemFontOfSize:15];
        emptyView = label;
    }
    if (emptyView) {
        UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0,
            self.view.bounds.size.width, self.view.bounds.size.height)];
        emptyView.center = container.center;
        [container addSubview:emptyView];
        self.tableView.backgroundView = container;
        self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    } else {
        self.tableView.backgroundView = nil;
        self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    }
}

- (NSString *)symlinkTargetOfPath:(NSString *)path
{
    struct stat status = {0};
    if (lstat(path.fileSystemRepresentation, &status) != 0 || !S_ISLNK(status.st_mode))
        return nil;
    char target[PATH_MAX] = {0};
    ssize_t length = readlink(path.fileSystemRepresentation, target, sizeof(target) - 1);
    if (length <= 0) return nil;
    target[length] = '\0';
    return [NSString stringWithUTF8String:target];
}


- (NSArray<FFEntry *> *)loadDirectoryContents
{
    NSMutableArray<FFEntry *> *result = [NSMutableArray array];
    DIR *directory = opendir(self.currentPath.fileSystemRepresentation);
    if (!directory) {
        self.loadError = [NSString stringWithFormat:@"无法打开目录 errno=%d (%s)",
            errno, strerror(errno)];
        FFLogTag(@"Browser", @"opendir FAIL path=%@ errno=%d (%s)",
            self.currentPath, errno, strerror(errno));
        return result;
    }
    self.loadError = nil;
    NSUInteger total = 0;
    NSUInteger dirs = 0;
    NSUInteger files = 0;
    NSUInteger links = 0;
    NSUInteger lstatFailures = 0;
    struct dirent *entry = NULL;
    while ((entry = readdir(directory)) != NULL) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        total++;
        NSString *name = [NSFileManager.defaultManager
            stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)];
        if (!name) continue;
        // 隐藏文件默认不显示（可在“更多”菜单打开）。
        if (!self.showHiddenFiles && [name hasPrefix:@"."]) continue;
        NSString *path = [self.currentPath stringByAppendingPathComponent:name];
        FFEntry *item = [FFEntry new];
        item.name = name;
        item.path = path;
        struct stat status = {0};
        if (lstat(path.fileSystemRepresentation, &status) != 0) {
            lstatFailures++;
            item.detail = [NSString stringWithFormat:@"lstat errno=%d", errno];
            [result addObject:item];
            continue;
        }
        if (S_ISLNK(status.st_mode)) links++;
        else if (S_ISDIR(status.st_mode)) dirs++;
        else files++;
        item.mode = status.st_mode;
        item.uid = status.st_uid;
        item.gid = status.st_gid;
        item.modificationDate = [NSDate dateWithTimeIntervalSince1970:status.st_mtimespec.tv_sec];
        item.creationDate = [NSDate dateWithTimeIntervalSince1970:status.st_birthtimespec.tv_sec];
        item.isSymlink = S_ISLNK(status.st_mode);
        if (item.isSymlink) {
            char target[PATH_MAX] = {0};
            ssize_t length = readlink(path.fileSystemRepresentation, target, sizeof(target) - 1);
            if (length > 0) {
                target[length] = '\0';
                item.linkTarget = [NSString stringWithUTF8String:target];
            }
            struct stat resolved = {0};
            if (stat(path.fileSystemRepresentation, &resolved) == 0) {
                item.isDirectory = S_ISDIR(resolved.st_mode);
                item.size = (unsigned long long)resolved.st_size;
            }
        } else {
            item.isDirectory = S_ISDIR(status.st_mode);
            item.size = S_ISREG(status.st_mode) ? (unsigned long long)status.st_size : 0;
        }
        // Resolve container UUIDs to readable app names via the MCM metadata
        // plist so directories show app names, not UUIDs. App Store installs
        // carry the localized display name in iTunesMetadata.plist; prefer
        // it over the bundle-identifier lookup.
        item.displayName = item.name;
        if (!item.isSymlink && item.isDirectory) {
            NSString *metadataPath = [path stringByAppendingPathComponent:
                @".com.apple.mobile_container_manager.metadata.plist"];
            NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
            NSString *identifier = [metadata[@"MCMMetadataIdentifier"]
                isKindOfClass:NSString.class] ? metadata[@"MCMMetadataIdentifier"] : nil;
            if (identifier.length) {
                NSString *itemName = FFAppContainerItemName(path);
                item.displayName = itemName ?: FFAppDisplayName(identifier);
                item.detail = [item.detail stringByAppendingFormat:@"\n%@", identifier];
                // Only log actual container roots (UUID-shaped names).
                if (FFIsUUIDShapedName(name))
                    FFLogTag(@"Browser", @"metadata resolved %@ -> %@ (%@)",
                        name, item.displayName, identifier);
            } else if (FFIsUUIDShapedName(name)) {
                FFLogTag(@"Browser", @"metadata MISSING/unreadable for %@",
                    path.lastPathComponent);
            }
        }
        [result addObject:item];
    }
    closedir(directory);
    FFLogTag(@"Browser", @"dir scan path=%@ total=%lu dirs=%lu files=%lu links=%lu lstatFail=%lu",
        self.currentPath, (unsigned long)total, (unsigned long)dirs,
        (unsigned long)files, (unsigned long)links, (unsigned long)lstatFailures);
    [self decorateEntries:result];
    [result sortUsingComparator:^NSComparisonResult(FFEntry *left, FFEntry *right) {
        // Folder-first ordering is a display preference, unaffected by
        // the sort direction.
        if (left.isDirectory != right.isDirectory)
            return left.isDirectory ? NSOrderedAscending : NSOrderedDescending;
        NSComparisonResult comparison = NSOrderedSame;
        switch (self.sortMode) {
            case FFSortModeSize:
                if (left.size != right.size)
                    comparison = left.size > right.size ? NSOrderedAscending : NSOrderedDescending;
                break;
            case FFSortModeDate:
                comparison = [right.modificationDate compare:left.modificationDate];
                break;
            case FFSortModeKind:
                comparison = [[self kindName:left] compare:[self kindName:right]];
                break;
            case FFSortModeName:
            default:
                break;
        }
        if (comparison == NSOrderedSame)
            comparison = [left.name compare:right.name options:NSNumericSearch];
        if (self.sortDescending)
            comparison = -comparison;
        return comparison;
    }];
    return result;
}

- (void)decorateEntries:(NSArray<FFEntry *> *)entries
{
    for (FFEntry *item in entries) {
        // Bundle-id links in the MCM folders read better as app names.
        // The link target is the real container root: its iTunesMetadata
        // carries the localized App Store display name (e.g. 中国移动).
        if (item.isSymlink && item.name.pathExtension.length &&
            [item.name containsString:@"."] && ![item.name hasPrefix:@"."]) {
            NSString *itemName = item.linkTarget.length
                ? FFAppContainerItemName(item.linkTarget) : nil;
            item.displayName = itemName ?: FFAppDisplayName(item.name);
        }
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        // 列表只显示简洁信息：目录不显示大小，文件显示大小 + 修改时间。
        if (!item.isDirectory && !item.isSymlink)
            [parts addObject:[self formatSize:item.size]];
        if (item.modificationDate)
            [parts addObject:[self formatDate:item.modificationDate]];
        if (item.linkTarget.length)
            [parts addObject:[NSString stringWithFormat:@"→ %@", item.linkTarget]];
        item.detail = [parts componentsJoinedByString:@"  "];

        NSMutableArray<NSString *> *full = [NSMutableArray arrayWithArray:@[
            [NSString stringWithFormat:@"名称：%@", item.name],
            [NSString stringWithFormat:@"路径：%@", item.path],
            [NSString stringWithFormat:@"类型：%@", [self kindName:item]],
            [NSString stringWithFormat:@"权限：%04o", item.mode & 07777],
            [NSString stringWithFormat:@"属主：%u:%u", item.uid, item.gid],
            [NSString stringWithFormat:@"大小：%@（%llu 字节）", [self formatSize:item.size], item.size],
        ]];
        if (item.modificationDate)
            [full addObject:[NSString stringWithFormat:@"修改时间：%@", [self formatDate:item.modificationDate]]];
        if (item.creationDate)
            [full addObject:[NSString stringWithFormat:@"创建时间：%@", [self formatDate:item.creationDate]]];
        if (item.isSymlink)
            [full addObject:[NSString stringWithFormat:@"链接目标：%@", item.linkTarget ?: @"？"]];
        [full addObjectsFromArray:[self extendedAttributesForPath:item.path]];
        item.fullDetail = [full componentsJoinedByString:@"\n"];
    }
}

- (NSArray<NSString *> *)extendedAttributesForPath:(NSString *)path
{
    ssize_t size = listxattr(path.fileSystemRepresentation, NULL, 0, 0);
    if (size <= 0) return @[];
    NSMutableData *buffer = [NSMutableData dataWithLength:(NSUInteger)size];
    ssize_t actual = listxattr(path.fileSystemRepresentation, buffer.mutableBytes, size, 0);
    if (actual <= 0) return @[];
    NSMutableArray<NSString *> *result = [NSMutableArray arrayWithObject:@"扩展属性："];
    const char *cursor = buffer.bytes;
    const char *end = cursor + actual;
    while (cursor < end) {
        NSString *name = [NSString stringWithUTF8String:cursor];
        if (name.length) {
            ssize_t valueSize = getxattr(path.fileSystemRepresentation, cursor, NULL, 0, 0, 0);
            if (valueSize >= 0)
                [result addObject:[NSString stringWithFormat:@"  %@ (%zd bytes)", name, valueSize]];
            else
                [result addObject:[NSString stringWithFormat:@"  %@ (errno=%d)", name, errno]];
        }
        cursor += strlen(cursor) + 1;
    }
    return result;
}

- (NSString *)kindName:(FFEntry *)item
{
    if (item.isDirectory) return @"目录";
    if (item.isSymlink) return @"符号链接";
    NSString *ext = item.name.pathExtension.lowercaseString;
    if (ext.length) return [NSString stringWithFormat:@"%@ 文件", ext.uppercaseString];
    return @"文件";
}

- (NSString *)formatDate:(NSDate *)date
{
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm";
    });
    return [formatter stringFromDate:date];
}

- (NSString *)formatSize:(unsigned long long)bytes
{
    if (bytes >= 1024ULL * 1024ULL * 1024ULL)
        return [NSString stringWithFormat:@"%.1f GB", bytes / (1024.0 * 1024.0 * 1024.0)];
    if (bytes >= 1024ULL * 1024ULL)
        return [NSString stringWithFormat:@"%.1f MB", bytes / (1024.0 * 1024.0)];
    if (bytes >= 1024ULL)
        return [NSString stringWithFormat:@"%.1f KB", bytes / 1024.0];
    return [NSString stringWithFormat:@"%llu B", bytes];
}

- (void)applyFilter
{
    NSArray<FFEntry *> *source = self.entries;
    if (self.filterMode != FFFilterModeAll)
        source = [source filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:
            ^BOOL(FFEntry *item, __unused NSDictionary *bindings) {
                return [self entry:item matchesFilter:self.filterMode];
            }]];
    if (!self.searchText.length) {
        self.filteredEntries = source;
        return;
    }
    NSPredicate *predicate = [NSPredicate predicateWithFormat:
        @"name contains[cd] %@ OR path contains[cd] %@", self.searchText, self.searchText];
    self.filteredEntries = [source filteredArrayUsingPredicate:predicate];
}

#pragma mark - Search

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    self.searchText = searchController.searchBar.text;
    [self applyFilter];
    [self.tableView reloadData];
}

#pragma mark - More menu

- (UIMenu *)moreMenu
{
    UIAction *select = [UIAction actionWithTitle:@"多选" image:[self symbolImage:@"checkmark.circle" tint:nil]
        identifier:nil handler:^(__unused UIAction *action) { [self toggleBatchMode]; }];
    UIAction *paste = [UIAction actionWithTitle:@"粘贴" image:[self symbolImage:@"doc.on.clipboard" tint:nil]
        identifier:nil handler:^(__unused UIAction *action) { [self pasteAction:nil]; }];
    paste.attributes = gClipboardSources.count == 0 ? UIMenuElementAttributesDisabled : 0;
    UIAction *import = [UIAction actionWithTitle:@"导入文件…" image:[self symbolImage:@"square.and.arrow.down" tint:nil]
        identifier:nil handler:^(__unused UIAction *action) { [self importFilesTapped]; }];
    UIAction *toggleGrid = [UIAction actionWithTitle:@"网格视图"
        image:[self symbolImage:@"square.grid.2x2" tint:nil]
        identifier:nil handler:^(__unused UIAction *action) {
            [self toggleGridMode];
        }];
    toggleGrid.state = self.gridMode ? UIMenuElementStateOn : UIMenuElementStateOff;
    UIAction *toggleHidden = [UIAction actionWithTitle:@"显示隐藏文件"
        image:[self symbolImage:@"eye" tint:nil]
        identifier:nil handler:^(__unused UIAction *action) {
            self.showHiddenFiles = !self.showHiddenFiles;
            self.moreItem.menu = [self moreMenu];
            [self reloadEntries];
        }];
    toggleHidden.state = self.showHiddenFiles ? UIMenuElementStateOn : UIMenuElementStateOff;
    UIMenu *sort = [UIMenu menuWithTitle:@"排序"
        children:@[[self sortMenu]]];
    UIMenu *filter = [UIMenu menuWithTitle:@"筛选"
        children:@[[self filterMenu]]];
    return [UIMenu menuWithTitle:@"更多"
        children:@[paste, import, select, sort, filter, toggleGrid, toggleHidden]];
}

#pragma mark - Import from Files app

// 外部导入：系统文件选择器（拷贝模式）。文件落到发起导入的当前目录，
// 写入经路径安全策略校验，重名自动加序号。
- (void)importFilesTapped
{
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initWithDocumentTypes:@[@"public.data", @"public.content"]
                       inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;
    [self presentViewController:picker animated:YES completion:nil];
}

// 目标重名时自动加序号，绝不静默覆盖。
- (NSString *)importDestinationForName:(NSString *)name inDirectory:(NSString *)directory
{
    NSString *candidate = [directory stringByAppendingPathComponent:name];
    if (![NSFileManager.defaultManager fileExistsAtPath:candidate]) return candidate;
    NSString *base = name.stringByDeletingPathExtension;
    NSString *ext = name.pathExtension.length ?
        [@"." stringByAppendingString:name.pathExtension] : @"";
    for (NSInteger index = 2; index < 1000; index++) {
        candidate = [directory stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@ (%ld)%@", base, (long)index, ext]];
        if (![NSFileManager.defaultManager fileExistsAtPath:candidate]) return candidate;
    }
    return nil;
}

- (void)documentPicker:(__unused UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    if (urls.count == 0) return;
    NSMutableArray<NSURL *> *picked = [urls mutableCopy];
    // 从哪个文件夹的右上角导入就落到哪个文件夹。目标目录是“目的地
    // 目录”而非被创建的文件：传一个探针路径（父=当前目录）验证可写，
    // 再用解析出的 parent（=当前目录）作为落盘根。
    NSString *probePath = [self.currentPath stringByAppendingPathComponent:@".ff-import"];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSUInteger imported = 0;
        NSString *firstFailure = nil;
        for (NSURL *url in picked) {
            [url startAccessingSecurityScopedResource];
            @try {
                NSString *detail = nil;
                NSString *finalName = nil;
                NSString *parent = [FFPathPolicy resolveParentForMutation:probePath
                    finalName:&finalName errorMessage:&detail];
                if (!parent) { firstFailure = detail ?: @"路径不可写"; continue; }
                NSString *destination = [weakSelf importDestinationForName:url.lastPathComponent
                    inDirectory:parent];
                if (!destination || ![NSFileManager.defaultManager copyItemAtPath:url.path
                        toPath:destination error:nil]) {
                    firstFailure = url.lastPathComponent ?: @"未知文件";
                    continue;
                }
                imported++;
            } @finally {
                [url stopAccessingSecurityScopedResource];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (imported > 0 && weakSelf.hasLoaded)
                [weakSelf reloadEntries];
            NSString *message = firstFailure ?
                [NSString stringWithFormat:@"已导入 %lu 项；失败：%@",
                    (unsigned long)imported, firstFailure] :
                [NSString stringWithFormat:@"已导入 %lu 项到当前目录。", (unsigned long)imported];
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                message:message preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好"
                style:UIAlertActionStyleCancel handler:nil]];
            [weakSelf presentViewController:alert animated:YES completion:nil];
        });
    });
}

#pragma mark - Sort menu

- (UIMenu *)sortMenu
{
    UIAction *name = [UIAction actionWithTitle:@"名称" image:[self symbolImage:@"textformat" tint:nil]
        identifier:nil handler:^(__unused UIAction *action) { [self setSortMode:FFSortModeName]; }];
    UIAction *size = [UIAction actionWithTitle:@"大小" image:[self symbolImage:@"arrow.down.right.and.arrow.up.left" tint:nil]
        identifier:nil handler:^(__unused UIAction *action) { [self setSortMode:FFSortModeSize]; }];
    UIAction *date = [UIAction actionWithTitle:@"修改时间" image:[self symbolImage:@"calendar" tint:nil]
        identifier:nil handler:^(__unused UIAction *action) { [self setSortMode:FFSortModeDate]; }];
    UIAction *kind = [UIAction actionWithTitle:@"类型" image:[self symbolImage:@"square.grid.2x2" tint:nil]
        identifier:nil handler:^(__unused UIAction *action) { [self setSortMode:FFSortModeKind]; }];
    name.state = self.sortMode == FFSortModeName ? UIMenuElementStateOn : UIMenuElementStateOff;
    size.state = self.sortMode == FFSortModeSize ? UIMenuElementStateOn : UIMenuElementStateOff;
    date.state = self.sortMode == FFSortModeDate ? UIMenuElementStateOn : UIMenuElementStateOff;
    kind.state = self.sortMode == FFSortModeKind ? UIMenuElementStateOn : UIMenuElementStateOff;
    NSString *directionTitle = self.sortDescending ? @"降序" : @"升序";
    UIAction *direction = [UIAction actionWithTitle:directionTitle
        image:[self symbolImage:self.sortDescending ? @"arrow.down" : @"arrow.up" tint:nil]
        identifier:nil handler:^(__unused UIAction *action) {
            self.sortDescending = !self.sortDescending;
            self.sortItem.menu = [self sortMenu];
            [self reloadEntries];
        }];
    return [UIMenu menuWithTitle:@"排序方式" children:@[name, size, date, kind, direction]];
}

- (void)setSortMode:(FFSortMode)sortMode
{
    _sortMode = sortMode;
    self.sortItem.menu = [self sortMenu];
    [self reloadEntries];
}

#pragma mark - Filter menu

static NSString *FFFilterTitle(FFFilterMode mode)
{
    switch (mode) {
        case FFFilterModeImages: return @"图片";
        case FFFilterModeVideos: return @"视频";
        case FFFilterModeAudio: return @"音频";
        case FFFilterModeDocuments: return @"文档";
        case FFFilterModeArchives: return @"压缩包";
        case FFFilterModeCode: return @"代码";
        case FFFilterModeAll: default: return @"全部";
    }
}

- (BOOL)entry:(FFEntry *)item matchesFilter:(FFFilterMode)mode
{
    if (item.isDirectory || mode == FFFilterModeAll) return YES;
    NSString *ext = item.name.pathExtension.lowercaseString;
    switch (mode) {
        case FFFilterModeImages:
            return [@[@"png", @"jpg", @"jpeg", @"gif", @"heic", @"webp", @"tiff", @"bmp"] containsObject:ext];
        case FFFilterModeVideos:
            return [@[@"mp4", @"mov", @"m4v", @"avi", @"mkv"] containsObject:ext];
        case FFFilterModeAudio:
            return [@[@"mp3", @"m4a", @"wav", @"aac", @"caf", @"flac"] containsObject:ext];
        case FFFilterModeDocuments:
            return [@[@"txt", @"log", @"md", @"json", @"xml", @"plist", @"csv", @"pdf",
                      @"rtf", @"doc", @"docx", @"xls", @"xlsx", @"ppt", @"pptx",
                      @"pages", @"numbers", @"key"] containsObject:ext];
        case FFFilterModeArchives:
            // .deb 不属于压缩包：无解析后端，不参与归档逻辑。
            return [@[@"zip", @"ipa", @"tar", @"gz", @"7z", @"rar", @"xz"] containsObject:ext];
        case FFFilterModeCode:
            return [@[@"c", @"h", @"m", @"mm", @"swift", @"sh", @"py", @"js", @"ts",
                      @"html", @"css", @"java", @"kt", @"go", @"rs", @"rb", @"php"] containsObject:ext];
        case FFFilterModeAll: default:
            return YES;
    }
}

- (UIMenu *)filterMenu
{
    NSMutableArray<UIAction *> *actions = [NSMutableArray array];
    for (NSInteger mode = FFFilterModeAll; mode <= FFFilterModeCode; mode++) {
        FFFilterMode filterMode = (FFFilterMode)mode;
        UIAction *action = [UIAction actionWithTitle:FFFilterTitle(filterMode)
            image:nil identifier:nil handler:^(__unused UIAction *act) {
                self.filterMode = filterMode;
                self.filterItem.menu = [self filterMenu];
                [self applyFilter];
                [self.tableView reloadData];
            }];
        action.state = self.filterMode == filterMode ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:action];
    }
    return [UIMenu menuWithTitle:@"筛选" children:actions];
}

#pragma mark - Table view

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.filteredEntries.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:@"Cell"];
    }
    FFEntry *item = self.filteredEntries[indexPath.row];
    [self configureCell:cell withItem:item];
    return cell;
}

- (void)configureCell:(UITableViewCell *)cell withItem:(FFEntry *)item
{
    UIListContentConfiguration *config = [cell defaultContentConfiguration];
    config.text = item.displayName.length ? item.displayName : item.name;
    config.textProperties.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    config.secondaryText = item.detail;
    config.secondaryTextProperties.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    config.secondaryTextProperties.numberOfLines = 0;
    config.image = item.thumbnail ?: [self iconForEntry:item];
    config.imageProperties.cornerRadius = 4;
    config.imageProperties.maximumSize = CGSizeMake(44, 44);
    if (item.thumbnail)
        config.imageProperties.tintColor = nil;
    else
        config.imageProperties.tintColor = [self tintForEntry:item];
    cell.contentConfiguration = config;
    cell.accessoryType = item.isDirectory ? UITableViewCellAccessoryDisclosureIndicator
                                         : UITableViewCellAccessoryNone;

    if (item.thumbnail || item.isDirectory || item.isSymlink ||
        ![self supportsThumbnail:item]) return;
    // Async thumbnail generation; the cell is re-configured once the
    // image lands and still hosts the same entry.
    __weak typeof(self) weakSelf = self;
    [[FFThumbnailService sharedService] thumbnailForPath:item.path
        size:CGSizeMake(44, 44) completion:^(UIImage * _Nullable image) {
            if (!image) return;
            item.thumbnail = image;
            dispatch_async(dispatch_get_main_queue(), ^{
                NSIndexPath *path = [weakSelf.tableView indexPathForCell:cell];
                if (!path) return;
                NSArray<FFEntry *> *entries = weakSelf.filteredEntries;
                if (path.row >= entries.count || entries[path.row] != item) return;
                [weakSelf configureCell:cell withItem:item];
            });
        }];
}

- (BOOL)supportsThumbnail:(FFEntry *)item
{
    NSString *ext = item.name.pathExtension.lowercaseString;
    static NSSet<NSString *> *supported;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        supported = [NSSet setWithArray:@[
            @"png", @"jpg", @"jpeg", @"gif", @"heic", @"webp", @"tiff", @"bmp",
            @"mp4", @"mov", @"m4v", @"avi", @"mkv",
            @"pdf",
        ]];
    });
    return [supported containsObject:ext];
}

- (UIImage *)iconForEntry:(FFEntry *)item
{
    if (item.isDirectory) return [self symbolImage:@"folder.fill" tint:nil];
    if (item.isSymlink) return [self symbolImage:@"link" tint:nil];
    NSString *ext = item.name.pathExtension.lowercaseString;
    static NSDictionary<NSString *, NSString *> *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            @"plist": @"list.bullet.rectangle",
            @"png": @"photo", @"jpg": @"photo", @"jpeg": @"photo", @"gif": @"photo",
            @"heic": @"photo", @"webp": @"photo", @"tiff": @"photo", @"bmp": @"photo",
            @"mp4": @"film", @"mov": @"film", @"m4v": @"film", @"avi": @"film", @"mkv": @"film",
            @"mp3": @"music.note", @"m4a": @"music.note", @"wav": @"music.note",
            @"aac": @"music.note", @"caf": @"music.note", @"flac": @"music.note",
            @"zip": @"archivebox", @"ipa": @"archivebox",
            @"tar": @"archivebox", @"gz": @"archivebox", @"7z": @"archivebox",
            @"rar": @"archivebox", @"xz": @"archivebox",
            @"db": @"internaldrive", @"sqlite": @"internaldrive", @"sqlite3": @"internaldrive",
            @"txt": @"doc.plaintext", @"log": @"doc.plaintext", @"md": @"doc.plaintext",
            @"json": @"curlybraces", @"xml": @"curlybraces", @"html": @"curlybraces",
            @"c": @"chevron.left.forwardslash.chevron.right",
            @"h": @"chevron.left.forwardslash.chevron.right",
            @"m": @"chevron.left.forwardslash.chevron.right",
            @"mm": @"chevron.left.forwardslash.chevron.right",
            @"swift": @"chevron.left.forwardslash.chevron.right",
            @"sh": @"doc.plaintext", @"command": @"doc.plaintext",
            @"key": @"key", @"mobileconfig": @"lock.doc", @"cer": @"lock.doc",
            @"p12": @"lock.doc", @"crt": @"lock.doc",
            @"app": @"app.badge", @"dylib": @"shippingbox", @"bundle": @"shippingbox",
            @"framework": @"shippingbox", @"tendies": @"photo.on.rectangle.angled",
        };
    });
    NSString *symbol = map[ext];
    if (!symbol) {
        if ([item.name hasPrefix:@"."]) symbol = @"gearshape";
        else symbol = @"doc";
    }
    return [self symbolImage:symbol tint:nil];
}

- (UIColor *)tintForEntry:(FFEntry *)item
{
    if (item.isDirectory) return [UIColor systemBlueColor];
    if (item.isSymlink) return [UIColor systemTealColor];
    NSString *ext = item.name.pathExtension.lowercaseString;
    if ([@[@"png", @"jpg", @"jpeg", @"gif", @"heic", @"webp", @"tiff", @"bmp"] containsObject:ext])
        return [UIColor systemGreenColor];
    if ([@[@"mp4", @"mov", @"m4v", @"avi", @"mkv"] containsObject:ext])
        return [UIColor systemOrangeColor];
    if ([@[@"mp3", @"m4a", @"wav", @"aac", @"caf", @"flac"] containsObject:ext])
        return [UIColor systemPinkColor];
    if ([@[@"zip", @"ipa", @"tar", @"gz", @"7z", @"rar", @"xz"] containsObject:ext])
        return [UIColor systemBrownColor];
    if ([@[@"plist", @"db", @"sqlite", @"sqlite3"] containsObject:ext])
        return [UIColor systemPurpleColor];
    if ([@[@"key", @"mobileconfig", @"cer", @"p12", @"crt"] containsObject:ext])
        return [UIColor systemYellowColor];
    return [UIColor systemGrayColor];
}

- (UIImage *)symbolImage:(NSString *)name tint:(UIColor *)tint
{
    if (@available(iOS 13.0, *)) {
        UIImage *image = [UIImage systemImageNamed:name];
        if (!image) return nil;
        return [image imageWithTintColor:tint ?: [UIColor systemBlueColor]
                           renderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    return nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    // Multi-select mode: selection only toggles, never opens. The cell
    // keeps its selection state; the title bar shows the running count.
    if (self.editing) {
        [self updateSelectionTitle];
        [self updatePasteState];
        return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self openEntry:self.filteredEntries[indexPath.row]];
}

// 打开条目：目录进入、文件预览（列表与网格共用）。
- (void)openEntry:(FFEntry *)item
{
    [[FFRecentService sharedService] recordPath:item.path
        name:item.displayName.length ? item.displayName : item.name
        isDirectory:item.isDirectory];
    if (item.isDirectory) {
        FFBrowserViewController *next = [[FFBrowserViewController alloc] initWithPath:item.path];
        next.title = item.displayName.length ? item.displayName : item.name;
        [self.navigationController pushViewController:next animated:YES];
        return;
    }
    [self previewEntry:item];
}

- (void)tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (self.editing) {
        [self updateSelectionTitle];
        [self updatePasteState];
    }
}

// Multi-select title: "已选 X 项" while editing; normal title untouched.
- (void)updateSelectionTitle
{
    if (!self.editing) return;
    NSInteger count = (NSInteger)self.tableView.indexPathsForSelectedRows.count;
    self.navigationItem.title = count == 0 ? @"已选 0 项" :
        [NSString stringWithFormat:@"已选 %ld 项", (long)count];
}

#pragma mark - Grid / list layout

- (void)setupCollectionView
{
    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.minimumInteritemSpacing = 8;
    layout.minimumLineSpacing = 12;
    layout.sectionInset = UIEdgeInsetsMake(12, 12, 12, 12);
    self.collectionView = [[UICollectionView alloc] initWithFrame:self.view.bounds
        collectionViewLayout:layout];
    self.collectionView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;
    self.collectionView.backgroundColor = [UIColor systemBackgroundColor];
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    self.collectionView.hidden = YES;
    self.collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.collectionView registerClass:UICollectionViewCell.class
            forCellWithReuseIdentifier:@"GridCell"];
    [self.view addSubview:self.collectionView];
    [NSLayoutConstraint activateConstraints:@[
        [self.collectionView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.collectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.collectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.collectionView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
    ]];
}

// 列表/网格切换：显示对应视图（网格 3 列，仅浏览；多选/编辑保持列表）。
- (void)applyLayoutModeAnimated:(BOOL)animated
{
    BOOL useGrid = self.gridMode && !self.editing;
    if (useGrid && !self.collectionView) [self setupCollectionView];
    if (!useGrid && self.collectionView && !self.collectionView.hidden) {
        // 退出网格即销毁：不留隐藏布局对象。
        [self.collectionView removeFromSuperview];
        self.collectionView = nil;
    }
    if (!self.collectionView) {
        self.tableView.hidden = NO;
        return;
    }
    self.collectionView.hidden = !useGrid;
    self.tableView.hidden = useGrid;
    if (useGrid) {
        [self.collectionView reloadData];
    }
}

- (void)toggleGridMode
{
    self.gridMode = !self.gridMode;
    [NSUserDefaults.standardUserDefaults setBool:self.gridMode
                                          forKey:@"FFSettingsGridMode"];
    if (self.moreItem) self.moreItem.menu = [self moreMenu];
    [self applyLayoutModeAnimated:NO];
}

#pragma mark - Collection view (grid)

- (NSInteger)collectionView:(UICollectionView *)collectionView
     numberOfItemsInSection:(NSInteger)section
{
    return (NSInteger)self.filteredEntries.count;
}

- (CGSize)collectionView:(UICollectionView *)collectionView
                  layout:(UICollectionViewLayout *)collectionViewLayout
  sizeForItemAtIndexPath:(NSIndexPath *)indexPath
{
    // 防御性尺寸：未完成布局（宽度为 0）或极窄时给安全默认值；floor
    // 防止浮点累加使整行宽度超出可用宽度 —— 超出会触发 flowlayout
    // 断言闪退（复制/剪切的横幅、压缩弹窗的键盘都会引发隐藏网格的
    // 布局提交，iOS 27 上隐藏视图同样参与 CATransaction 布局）。
    CGFloat available = collectionView.bounds.size.width - 24 - 16;
    if (available < 120) return CGSizeMake(44, 72);
    CGFloat width = floor(available / 3.0);
    return CGSizeMake(width, width + 28);
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView
                  cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
    UICollectionViewCell *cell = [collectionView
        dequeueReusableCellWithReuseIdentifier:@"GridCell" forIndexPath:indexPath];
    FFEntry *item = self.filteredEntries[indexPath.row];
    UIView *existing = [cell.contentView viewWithTag:999];
    [existing removeFromSuperview];

    UIListContentConfiguration *config = [UIListContentConfiguration
        subtitleCellConfiguration];
    config.text = item.displayName.length ? item.displayName : item.name;
    config.textProperties.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    config.textProperties.numberOfLines = 1;
    config.textProperties.alignment = UIListContentTextAlignmentCenter;
    config.secondaryText = [self formatSize:item.size];
    config.secondaryTextProperties.font = [UIFont systemFontOfSize:10];
    config.secondaryTextProperties.alignment = UIListContentTextAlignmentCenter;
    config.image = item.thumbnail ?: [self iconForEntry:item];
    config.imageProperties.maximumSize = CGSizeMake(48, 48);
    config.imageProperties.cornerRadius = 6;
    config.imageProperties.tintColor = item.thumbnail ? nil : [self tintForEntry:item];
    UIView *content = [config makeContentView];
    content.tag = 999;
    content.frame = cell.contentView.bounds;
    content.autoresizingMask = UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;
    [cell.contentView addSubview:content];
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView
    didSelectItemAtIndexPath:(NSIndexPath *)indexPath
{
    [collectionView deselectItemAtIndexPath:indexPath animated:YES];
    [self openEntry:self.filteredEntries[indexPath.row]];
}

#pragma mark - Context menu & swipe actions

// 上下文菜单的 action handler 在菜单收起动画期间被回调；此时直接
// present（尤其带输入框、会拉起键盘的 alert）会与进行中的转场冲突，
// 在 iOS 27 上直接闪退。统一推迟到下一轮主循环，让菜单先完成收起。
- (void)performAfterContextMenu:(void (^)(void))block
{
    dispatch_async(dispatch_get_main_queue(), block);
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
    contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
    point:(CGPoint)point
{
    FFEntry *item = self.filteredEntries[indexPath.row];
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
        previewProvider:nil
        actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
            UIAction *view = [UIAction actionWithTitle:item.isDirectory ? @"打开" : @"查看"
                image:[self symbolImage:@"eye" tint:nil]
                identifier:nil handler:^(__unused UIAction *action) {
                    [weakSelf performAfterContextMenu:^{
                        if (!weakSelf) return;
                        if (item.isDirectory) {
                            FFBrowserViewController *next = [[FFBrowserViewController alloc] initWithPath:item.path];
                            next.title = item.displayName.length ? item.displayName : item.name;
                            [weakSelf.navigationController pushViewController:next animated:YES];
                        } else {
                            [weakSelf previewEntry:item];
                        }
                    }];
                }];
            UIAction *copy = [UIAction actionWithTitle:@"复制" image:[self symbolImage:@"doc.on.doc" tint:nil]
                identifier:nil handler:^(__unused UIAction *action) {
                    [weakSelf performAfterContextMenu:^{ [weakSelf setClipboard:item mode:FFClipboardModeCopy]; }];
                }];
            UIAction *cut = [UIAction actionWithTitle:@"剪切" image:[self symbolImage:@"scissors" tint:nil]
                identifier:nil handler:^(__unused UIAction *action) {
                    [weakSelf performAfterContextMenu:^{ [weakSelf setClipboard:item mode:FFClipboardModeCut]; }];
                }];
            UIAction *duplicate = [UIAction actionWithTitle:@"创建副本" image:[self symbolImage:@"plus.square.on.square" tint:nil]
                identifier:nil handler:^(__unused UIAction *action) {
                    [weakSelf performAfterContextMenu:^{ [weakSelf duplicateEntry:item]; }];
                }];
            UIAction *favorite = [UIAction actionWithTitle:
                [[FFFavoritesService sharedService] isFavoritePath:item.path] ? @"取消收藏" : @"收藏"
                image:[self symbolImage:@"star" tint:nil]
                identifier:nil handler:^(__unused UIAction *action) {
                    [weakSelf performAfterContextMenu:^{ [weakSelf toggleFavorite:item]; }];
                }];
            UIAction *compress = [UIAction actionWithTitle:@"压缩" image:[self symbolImage:@"shippingbox" tint:nil]
                identifier:nil handler:^(__unused UIAction *action) {
                    [weakSelf performAfterContextMenu:^{ [weakSelf compressEntries:@[item]]; }];
                }];
            UIAction *rename = [UIAction actionWithTitle:@"重命名" image:[self symbolImage:@"pencil" tint:nil]
                identifier:nil handler:^(__unused UIAction *action) {
                    [weakSelf performAfterContextMenu:^{ [weakSelf renameEntry:item]; }];
                }];
            UIAction *copyPath = [UIAction actionWithTitle:@"复制路径" image:[self symbolImage:@"point.topleft.down.curvedto.point.bottomright.up" tint:nil]
                identifier:nil handler:^(__unused UIAction *action) {
                    [weakSelf performAfterContextMenu:^{ [weakSelf copyPath:item]; }];
                }];
            UIAction *share = [UIAction actionWithTitle:@"分享" image:[self symbolImage:@"square.and.arrow.up" tint:nil]
                identifier:nil handler:^(__unused UIAction *action) {
                    [weakSelf performAfterContextMenu:^{ [weakSelf shareEntry:item]; }];
                }];
            UIAction *properties = [UIAction actionWithTitle:@"属性" image:[self symbolImage:@"info.circle" tint:nil]
                identifier:nil handler:^(__unused UIAction *action) {
                    [weakSelf performAfterContextMenu:^{ [weakSelf showProperties:item]; }];
                }];
            UIAction *delete = [UIAction actionWithTitle:@"删除" image:[self symbolImage:@"trash" tint:nil]
                identifier:nil handler:^(__unused UIAction *action) {
                    [weakSelf performAfterContextMenu:^{ [weakSelf deleteEntry:item]; }];
                }];
            delete.attributes = UIMenuElementAttributesDestructive;
            // 用其他查看器打开：列出全部注册查看器（默认关联打勾）。
            UIAction *openWith = [UIAction actionWithTitle:@"用其他查看器打开"
                image:[self symbolImage:@"square.and.arrow.down.on.square" tint:nil]
                identifier:nil handler:^(__unused UIAction *action) {
                    [weakSelf performAfterContextMenu:^{ [weakSelf openWithPicker:item]; }];
                }];
            NSMutableArray *children = [NSMutableArray arrayWithArray:
                @[view, copy, cut, duplicate, favorite, compress, rename, copyPath, share, properties, delete]];
            if (!item.isDirectory) {
                NSString *ext = item.name.pathExtension.lowercaseString;
                // 按文件能力追加：压缩包浏览 / IPA 安装 / 用其他查看器打开。
                if ([self isArchiveEntry:item])
                    [children insertObject:[UIAction actionWithTitle:@"浏览压缩包"
                        image:[self symbolImage:@"shippingbox" tint:nil]
                        identifier:nil handler:^(__unused UIAction *action) {
                            [weakSelf performAfterContextMenu:^{ [weakSelf openWithViewer:item viewerID:@"archive"]; }];
                        }] atIndex:children.count - 2];
                if ([ext isEqualToString:@"ipa"])
                    [children insertObject:[UIAction actionWithTitle:@"安装"
                        image:[self symbolImage:@"arrow.down.app" tint:nil]
                        identifier:nil handler:^(__unused UIAction *action) {
                            [weakSelf performAfterContextMenu:^{ [weakSelf openWithViewer:item viewerID:@"installer"]; }];
                        }] atIndex:children.count - 2];
                [children insertObject:openWith atIndex:children.count - 2];
            }
            if ([self isArchiveEntry:item])
                [children insertObject:[UIAction actionWithTitle:@"解压"
                    image:[self symbolImage:@"shippingbox" tint:nil]
                    identifier:nil handler:^(__unused UIAction *action) {
                        [weakSelf performAfterContextMenu:^{ [weakSelf extractEntry:item]; }];
                    }]
                    atIndex:children.count - 2];
            return [UIMenu menuWithTitle:item.name children:children];
        }];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    // 编辑（多选）模式下禁用左滑：swipe 按钮与底部批量工具栏重叠。
    if (self.editing) return nil;
    FFEntry *item = self.filteredEntries[indexPath.row];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"删除" handler:^(__unused UIContextualAction *action, __unused UIView *sourceView,
            void (^completionHandler)(BOOL)) {
            [weakSelf deleteEntry:item];
            completionHandler(YES);
        }];
    delete.image = [self symbolImage:@"trash" tint:nil];
    UIContextualAction *more = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
        title:@"更多" handler:^(__unused UIContextualAction *action, __unused UIView *sourceView,
            void (^completionHandler)(BOOL)) {
            [weakSelf presentActionsForEntry:item];
            completionHandler(YES);
        }];
    more.image = [self symbolImage:@"ellipsis.circle" tint:nil];
    UISwipeActionsConfiguration *configuration =
        [UISwipeActionsConfiguration configurationWithActions:@[delete, more]];
    configuration.performsFirstActionWithFullSwipe = YES;
    return configuration;
}

#pragma mark - Actions

- (void)presentActionsForEntry:(FFEntry *)item
{
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:item.name
        message:item.detail preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;

    [sheet addAction:[UIAlertAction actionWithTitle:item.isDirectory ? @"打开" : @"查看"
        style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            if (item.isDirectory) {
                FFBrowserViewController *next = [[FFBrowserViewController alloc] initWithPath:item.path];
                next.title = item.displayName.length ? item.displayName : item.name;
                [weakSelf.navigationController pushViewController:next animated:YES];
            } else {
                [weakSelf previewEntry:item];
            }
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"复制" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf setClipboard:item mode:FFClipboardModeCopy]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"创建副本" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf duplicateEntry:item]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:
        [[FFFavoritesService sharedService] isFavoritePath:item.path] ? @"取消收藏" : @"收藏"
        style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf toggleFavorite:item]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"压缩" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf compressEntries:@[item]]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"剪切" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf setClipboard:item mode:FFClipboardModeCut]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"重命名" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf renameEntry:item]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"复制路径" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf copyPath:item]; }]];
    if (!item.isDirectory) {
        NSString *ext = item.name.pathExtension.lowercaseString;
        // 按文件能力追加：压缩包浏览 / IPA 安装 / 用其他查看器打开。
        if ([self isArchiveEntry:item]) {
            [sheet addAction:[UIAlertAction actionWithTitle:@"浏览压缩包"
                style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *action) {
                    [weakSelf openWithViewer:item viewerID:@"archive"];
                }]];
            [sheet addAction:[UIAlertAction actionWithTitle:@"解压"
                style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *action) { [weakSelf extractEntry:item]; }]];
        }
        if ([ext isEqualToString:@"ipa"])
            [sheet addAction:[UIAlertAction actionWithTitle:@"安装"
                style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *action) {
                    [weakSelf openWithViewer:item viewerID:@"installer"];
                }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"用其他查看器打开"
            style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) { [weakSelf openWithPicker:item]; }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"分享" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf shareEntry:item]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"属性" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf showProperties:item]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) { [weakSelf deleteEntry:item]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2,
        self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)setClipboard:(FFEntry *)item mode:(FFClipboardMode)mode
{
    gClipboardSources = @[item.path];
    gClipboardMode = mode;
    [self updatePasteState];
    if (self.moreItem) self.moreItem.menu = [self moreMenu];
    [self showPasteBanner];
}

#pragma mark - Paste banner

// 底部提示条：复制/剪切后显示“已复制 X 项 + 粘贴/取消”，
// 替代连续弹窗，进入目标目录后粘贴按钮清晰可见。
- (void)showPasteBanner
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *existing = [self.view viewWithTag:9347];
        [existing removeFromSuperview];
        if (gClipboardSources.count == 0) return;

        UIView *banner = [[UIView alloc] initWithFrame:CGRectMake(0, 0,
            self.view.bounds.size.width - 24, 52)];
        banner.tag = 9347;
        banner.translatesAutoresizingMaskIntoConstraints = NO;
        banner.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        banner.layer.cornerRadius = 12;
        banner.layer.masksToBounds = YES;
        [self.view addSubview:banner];
        [NSLayoutConstraint activateConstraints:@[
            [banner.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
            [banner.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
            [banner.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor
                                                constant:-8],
            [banner.heightAnchor constraintEqualToConstant:52],
        ]];

        NSString *action = gClipboardMode == FFClipboardModeCopy ? @"已复制" : @"已剪切";
        UILabel *label = [[UILabel alloc] init];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        label.text = [NSString stringWithFormat:@"%@ %lu 项",
            action, (unsigned long)gClipboardSources.count];
        [banner addSubview:label];

        UIButton *pasteButton = [UIButton buttonWithType:UIButtonTypeSystem];
        pasteButton.translatesAutoresizingMaskIntoConstraints = NO;
        [pasteButton setTitle:@"粘贴" forState:UIControlStateNormal];
        [pasteButton setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
        [pasteButton addTarget:self action:@selector(pasteAction:)
              forControlEvents:UIControlEventTouchUpInside];
        [banner addSubview:pasteButton];

        UIButton *cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
        cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
        [cancelButton setTitle:@"取消" forState:UIControlStateNormal];
        [cancelButton setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
        [cancelButton addTarget:self action:@selector(cancelPaste)
              forControlEvents:UIControlEventTouchUpInside];
        [banner addSubview:cancelButton];

        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor constant:14],
            [label.centerYAnchor constraintEqualToAnchor:banner.centerYAnchor],
            [cancelButton.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:-8],
            [cancelButton.centerYAnchor constraintEqualToAnchor:banner.centerYAnchor],
            [pasteButton.trailingAnchor constraintEqualToAnchor:cancelButton.leadingAnchor constant:-8],
            [pasteButton.centerYAnchor constraintEqualToAnchor:banner.centerYAnchor],
        ]];
        banner.alpha = 0;
        [UIView animateWithDuration:0.2 animations:^{ banner.alpha = 1; }];
    });
}

- (void)cancelPaste
{
    gClipboardSources = nil;
    gClipboardMode = FFClipboardModeNone;
    [self hidePasteBanner];
    [self updatePasteState];
    if (self.moreItem) self.moreItem.menu = [self moreMenu];
}

- (void)hidePasteBanner
{
    UIView *banner = [self.view viewWithTag:9347];
    [UIView animateWithDuration:0.15 animations:^{ banner.alpha = 0; }
        completion:^(BOOL finished) { [banner removeFromSuperview]; }];
}

- (void)pasteAction:(id)sender
{
    if (gClipboardSources.count == 0) return;
    if ([self pasteIsInsideClipboardSource]) return;
    // 同目录粘贴（剪切模式）：移动引擎会把文件搬到自身再“替换”，
    // 导致源文件消失。直接拦截并提示。
    NSArray<NSString *> *sameDir = [self clipboardSourcesInCurrentDirectory];
    if (sameDir.count > 0) {
        [self flash:[NSString stringWithFormat:
            @"已在当前目录内，忽略 %lu 项", (unsigned long)sameDir.count]];
        return;
    }
    NSArray<NSString *> *sources = gClipboardSources;
    gClipboardSources = nil;
    FFClipboardMode mode = gClipboardMode;
    gClipboardMode = FFClipboardModeNone;

    FFFileTask *task = [FFFileTask new];
    task.kind = mode == FFClipboardModeCut ? FFFileTaskKindMove : FFFileTaskKindCopy;
    task.displayName = [NSString stringWithFormat:@"%@ %lu 个项目",
        task.kindText, (unsigned long)sources.count];
    task.sources = sources;
    task.destination = self.currentPath;
    __weak typeof(self) weakSelf = self;
    // 冲突处理绑定到本任务，避免并发任务交叉。
    task.conflictHandler = ^FFConflictAction(NSString *name) {
        typeof(weakSelf) strongSelf = weakSelf;
        return strongSelf ? [strongSelf askConflictForName:name] : FFConflictActionSkip;
    };
    [[FFFileTaskManager sharedManager] enqueueTask:task];
    [self hidePasteBanner];
    [self flash:[NSString stringWithFormat:@"已加入任务队列：%@", task.displayName]];
    [self updatePasteState];
}

// Blocks the calling (background) thread until the user picks a
// conflict action on the main thread.
- (FFConflictAction)askConflictForName:(NSString *)name
{
    __block FFConflictAction chosen = FFConflictActionSkip;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"目标已存在"
            message:[NSString stringWithFormat:@"“%@” 已存在于当前目录。", name]
            preferredStyle:UIAlertControllerStyleActionSheet];
        [sheet addAction:[UIAlertAction actionWithTitle:@"替换" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                chosen = FFConflictActionReplace;
                dispatch_semaphore_signal(semaphore);
            }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"跳过" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                chosen = FFConflictActionSkip;
                dispatch_semaphore_signal(semaphore);
            }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"保留两者" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                chosen = FFConflictActionKeepBoth;
                dispatch_semaphore_signal(semaphore);
            }]];
        // “应用于后续项目”：替换/跳过应用到剩余项目。
        [sheet addAction:[UIAlertAction actionWithTitle:@"应用于后续：全部替换"
            style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                chosen = FFConflictActionReplaceAll;
                dispatch_semaphore_signal(semaphore);
            }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"应用于后续：全部跳过"
            style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                chosen = FFConflictActionSkipAll;
                dispatch_semaphore_signal(semaphore);
            }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
            handler:^(__unused UIAlertAction *action) {
                chosen = FFConflictActionSkip;
                dispatch_semaphore_signal(semaphore);
            }]];
        sheet.popoverPresentationController.sourceView = self.view;
        sheet.popoverPresentationController.sourceRect = CGRectMake(
            self.view.bounds.size.width / 2, self.view.bounds.size.height - 60, 1, 1);
        [self presentOnTop:sheet];
    });
    // 超时兜底：90 秒未决策（例如页面已离开、弹窗被覆盖）按“跳过”处理，
    // 避免任务永久阻塞在冲突决策上。
    long timedOut = dispatch_semaphore_wait(semaphore,
        dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_SEC));
    if (timedOut != 0) return FFConflictActionSkip;
    return chosen;
}

- (NSString *)uniqueDestinationForName:(NSString *)name
{
    if (name.length == 0 || [name isEqualToString:@"."] || [name isEqualToString:@".."])
        return nil;
    NSString *candidate = [self.currentPath stringByAppendingPathComponent:name];
    struct stat status = {0};
    if (lstat(candidate.fileSystemRepresentation, &status) != 0 && errno == ENOENT)
        return candidate;
    NSString *extension = name.pathExtension;
    NSString *stem = extension.length ? name.stringByDeletingPathExtension : name;
    for (NSUInteger index = 1; index <= 999; index++) {
        NSString *suffix = index == 1 ? @" copy"
            : [NSString stringWithFormat:@" copy %lu", (unsigned long)index];
        NSString *copyName = [stem stringByAppendingString:suffix];
        if (extension.length) copyName = [copyName stringByAppendingPathExtension:extension];
        candidate = [self.currentPath stringByAppendingPathComponent:copyName];
        if (lstat(candidate.fileSystemRepresentation, &status) != 0 && errno == ENOENT)
            return candidate;
    }
    return nil;
}

- (void)createFolder
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"新建文件夹"
        message:self.currentPath preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"文件夹名称";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"创建" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            NSString *name = alert.textFields.firstObject.text;
            if (![weakSelf validNewName:name]) return;
            NSString *path = [weakSelf.currentPath stringByAppendingPathComponent:name];
            NSError *error = nil;
            if (![[FFFileOperationService sharedService] createDirectoryAtPath:path error:&error])
                [weakSelf showError:error];
            [weakSelf reloadEntries];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)createFile
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"新建文件"
        message:self.currentPath preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"文件名";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"创建" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            NSString *name = alert.textFields.firstObject.text;
            if (![weakSelf validNewName:name]) return;
            NSString *path = [weakSelf.currentPath stringByAppendingPathComponent:name];
            NSError *error = nil;
            if (![[FFFileOperationService sharedService] createEmptyFileAtPath:path error:&error])
                [weakSelf showError:error];
            [weakSelf reloadEntries];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)toggleFavorite:(FFEntry *)item
{
    BOOL wasFavorite = [[FFFavoritesService sharedService] isFavoritePath:item.path];
    [[FFFavoritesService sharedService] togglePath:item.path
        name:item.displayName.length ? item.displayName : item.name
        isDirectory:item.isDirectory];
    [self flash:wasFavorite ? @"已取消收藏" : @"已收藏"];
}

- (void)duplicateEntry:(FFEntry *)item
{
    NSString *destination = [self uniqueDestinationForName:item.name];
    if (!destination) {
        [self flash:@"无法确定副本目标"];
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        BOOL ok = [FFCopyEngine copyItemAtPath:item.path toPath:destination error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ok) {
                [weakSelf flash:@"副本已创建"];
                [weakSelf reloadEntries];
            } else {
                [weakSelf showError:error];
            }
        });
    });
}

- (BOOL)validNewName:(NSString *)name
{
    name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (name.length == 0 || [name containsString:@"/"] || [name containsString:@"\0"]) {
        [self flash:@"名称无效"];
        return NO;
    }
    return YES;
}

- (void)renameEntry:(FFEntry *)item
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重命名"
        message:item.path preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = item.name;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"重命名" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            NSString *newName = alert.textFields.firstObject.text;
            if (![weakSelf validNewName:newName]) return;
            [weakSelf performRenameItem:item toName:newName overwrite:NO];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

// 重命名冲突处理：目标已存在时提供 取消 / 覆盖 / 保留两者。
- (void)performRenameItem:(FFEntry *)item toName:(NSString *)newName
                overwrite:(BOOL)overwrite
{
    NSString *newPath = [self.currentPath stringByAppendingPathComponent:newName];
    NSError *error = nil;
    if ([[FFFileOperationService sharedService] renameItemAtPath:item.path
        toPath:newPath overwrite:overwrite error:&error]) {
        [self reloadEntries];
        return;
    }
    if (error.code != EEXIST) {
        [self showError:error];
        [self reloadEntries];
        return;
    }
    // 目标存在：提供覆盖 / 保留两者 / 取消。
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"名称已存在"
        message:[NSString stringWithFormat:@"“%@” 已存在，是否覆盖？", newName]
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"覆盖" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            [weakSelf performRenameItem:item toName:newName overwrite:YES];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"保留两者" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            NSString *copyName = [weakSelf uniqueDestinationForName:newName];
            if (!copyName) {
                [weakSelf flash:@"无法生成不冲突的名称"];
                return;
            }
            NSString *copyPath = [weakSelf.currentPath stringByAppendingPathComponent:copyName];
            NSError *moveError = nil;
            if (![[FFFileOperationService sharedService] renameItemAtPath:item.path
                toPath:copyPath error:&moveError])
                [weakSelf showError:moveError];
            [weakSelf reloadEntries];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(
        self.view.bounds.size.width / 2, self.view.bounds.size.height - 60, 1, 1);
    [self presentOnTop:sheet];
}

- (void)deleteEntry:(FFEntry *)item
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"删除"
        message:[NSString stringWithFormat:@"确定删除 %@？", item.path]
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            NSError *error = nil;
            if (![[FFFileOperationService sharedService] removeItemAtPath:item.path error:&error]) {
                FFLogTag(@"Browser", @"delete FAIL path=%@ errno=%ld (%@)",
                    item.path, (long)error.code, error.localizedDescription);
                [weakSelf showError:error];
            }
            [weakSelf reloadEntries];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)shareEntry:(FFEntry *)item
{
    NSURL *url = [NSURL fileURLWithPath:item.path];
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:@[url] applicationActivities:nil];
    activity.popoverPresentationController.sourceView = self.view;
    activity.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2,
        self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)copyPath:(FFEntry *)item
{
    UIPasteboard.generalPasteboard.string = item.path;
    [self flash:@"路径已复制"];
}

- (BOOL)isArchiveEntry:(FFEntry *)item
{
    static NSSet<NSString *> *extensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 真实 zip 容器家族。.deb 明确排除：无解析后端，不再当作 ZIP/归档。
        extensions = [NSSet setWithArray:@[
            @"zip", @"ipa", @"xcarchive", @"appex", @"app",
            @"bundle", @"framework", @"war", @"jar", @"crx", @"xpi",
            @"docx", @"xlsx", @"pptx", @"pages", @"numbers", @"key",
            @"epub", @"apk",
        ]];
    });
    return [extensions containsObject:item.name.pathExtension.lowercaseString];
}

- (void)extractEntry:(FFEntry *)item
{
    NSString *stem = item.name.stringByDeletingPathExtension;
    if (stem.length == 0) stem = @"archive";
    NSString *sibling = [self.currentPath stringByAppendingPathComponent:
        [stem stringByAppendingString:@" (解压)"]];
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *extractedRoot = [[documents stringByAppendingPathComponent:@"Device Storage"]
        stringByAppendingPathComponent:@"Extracted"];
    NSString *fallbackDestination = [extractedRoot stringByAppendingPathComponent:
        [stem stringByAppendingFormat:@"-%@",
            [[[NSUUID UUID] UUIDString] substringToIndex:8]]];

    FFFileTask *task = [FFFileTask new];
    task.kind = FFFileTaskKindExtract;
    task.displayName = [NSString stringWithFormat:@"解压 %@", item.name];
    task.sources = @[item.path];
    // Prefer the sibling folder; sandbox-denied destinations fall back
    // to the app's own Documents on the next attempt (sibling write
    // failures leave the fallback path stored on the task).
    task.destination = sibling;
    [[FFFileTaskManager sharedManager] enqueueTask:task];
    FFLogTag(@"Browser", @"extract task queued archive=%@ sibling=%@ fallback=%@",
             item.path, sibling, fallbackDestination);
    [self flash:[NSString stringWithFormat:@"已加入任务队列：%@", task.displayName]];
}

- (void)showProperties:(FFEntry *)item
{
    NSString *body = item.fullDetail ?: item.detail;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:item.displayName ?: item.name
        message:body preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"复制路径" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf copyPath:item]; }]];
    if (item.isDirectory) {
        [alert addAction:[UIAlertAction actionWithTitle:@"计算目录大小" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) { [weakSelf computeDirectorySize:item]; }]];
    } else if (!item.isSymlink) {
        [alert addAction:[UIAlertAction actionWithTitle:@"计算 SHA-256" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) { [weakSelf computeSHA256:item]; }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)computeSHA256:(FFEntry *)item
{
    [self flash:@"正在计算…"];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *hash = [self sha256OfFile:item.path];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!hash) {
                [weakSelf flash:@"计算失败（文件不可读）"];
                return;
            }
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"SHA-256"
                message:[NSString stringWithFormat:@"%@\n\n%@", hash, item.path]
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"复制" style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *action) {
                    UIPasteboard.generalPasteboard.string = hash;
                    [weakSelf flash:@"哈希已复制"];
                }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
            [weakSelf presentViewController:alert animated:YES completion:nil];
        });
    });
}

- (NSString *)sha256OfFile:(NSString *)path
{
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return nil;
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    uint8_t buffer[64 * 1024];
    ssize_t count = 0;
    while ((count = read(fd, buffer, sizeof(buffer))) > 0)
        CC_SHA256_Update(&context, buffer, (CC_LONG)count);
    close(fd);
    if (count < 0) return nil;
    uint8_t digest[CC_SHA256_DIGEST_LENGTH] = {0};
    CC_SHA256_Final(digest, &context);
    NSMutableString *result = [NSMutableString stringWithCapacity:64];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++)
        [result appendFormat:@"%02x", digest[index]];
    return result;
}

- (void)computeDirectorySize:(FFEntry *)item
{
    [self flash:@"正在计算…"];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        unsigned long long size = [self directorySizeAtPath:item.path];
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:item.name
                message:[NSString stringWithFormat:@"目录大小：%@\n（%llu 字节）\n\n%@",
                    [weakSelf formatSize:size], size, item.path]
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"复制路径" style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *action) { [weakSelf copyPath:item]; }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
            [weakSelf presentViewController:alert animated:YES completion:nil];
        });
    });
}

- (unsigned long long)directorySizeAtPath:(NSString *)path
{
    unsigned long long total = 0;
    DIR *directory = opendir(path.fileSystemRepresentation);
    if (!directory) return 0;
    struct dirent *entry = NULL;
    while ((entry = readdir(directory)) != NULL) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        NSString *name = [[NSFileManager defaultManager]
            stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)];
        if (!name) continue;
        NSString *child = [path stringByAppendingPathComponent:name];
        struct stat status = {0};
        if (lstat(child.fileSystemRepresentation, &status) != 0) continue;
        if (S_ISDIR(status.st_mode) && !S_ISLNK(status.st_mode)) {
            total += [self directorySizeAtPath:child];
        } else if (S_ISREG(status.st_mode)) {
            total += (unsigned long long)status.st_size;
        }
    }
    closedir(directory);
    return total;
}

#pragma mark - Preview

// 显式指定查看器打开（长按菜单：浏览压缩包 / 安装）。
- (void)openWithViewer:(FFEntry *)item viewerID:(NSString *)viewerID
{
    UINavigationController *nav = self.navigationController;
    if (!nav) return;
    [FFPreviewRouter openItem:item viewerID:viewerID navigationController:nav];
}

// 用其他查看器打开：列出全部注册查看器，当前默认关联打勾。
- (void)openWithPicker:(FFEntry *)item
{
    NSString *extension = item.name.pathExtension.lowercaseString;
    FFFileAssociationService *service = [FFFileAssociationService sharedService];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:item.name
        message:@"选择查看器" preferredStyle:UIAlertControllerStyleActionSheet];
    for (FFViewerInfo *viewer in [[FFViewerRegistry sharedRegistry] allViewers]) {
        BOOL isDefault =
            [viewer.viewerID isEqualToString:[service effectiveViewerIDForExtension:extension]];
        [sheet addAction:[UIAlertAction actionWithTitle:
            isDefault ? [NSString stringWithFormat:@"✓ %@（默认关联）", viewer.displayName]
                      : viewer.displayName
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                [self openWithViewer:item viewerID:viewer.viewerID];
            }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
        style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect =
        CGRectMake(self.view.bounds.size.width / 2,
            self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

// Opens a path from search/favorites/recents: directories push a
// browser, files open the preview directly. Uses the caller's
// navigation controller (a freshly created browser has none).
- (void)openItemAtPath:(NSString *)path title:(NSString *)title
     navigationController:(UINavigationController *)nav
            completion:(void (^)(BOOL))completion
{
    struct stat status = {0};
    if (lstat(path.fileSystemRepresentation, &status) != 0) {
        if (completion) completion(NO);
        return;
    }
    BOOL isDirectory = S_ISDIR(status.st_mode) && !S_ISLNK(status.st_mode);
    if (isDirectory) {
        FFBrowserViewController *browser =
            [[FFBrowserViewController alloc] initWithPath:path];
        browser.title = title.length ? title : path.lastPathComponent;
        [nav pushViewController:browser animated:YES];
        if (completion) completion(YES);
        return;
    }
    FFEntry *item = [FFEntry new];
    item.name = path.lastPathComponent;
    item.path = path;
    item.isDirectory = NO;
    item.isSymlink = S_ISLNK(status.st_mode);
    item.size = S_ISREG(status.st_mode) ? (unsigned long long)status.st_size : 0;
    item.modificationDate = [NSDate dateWithTimeIntervalSince1970:status.st_mtimespec.tv_sec];
    item.creationDate = [NSDate dateWithTimeIntervalSince1970:status.st_birthtimespec.tv_sec];
    item.mode = status.st_mode;
    item.uid = status.st_uid;
    item.gid = status.st_gid;
    if (item.isSymlink) {
        char target[PATH_MAX] = {0};
        ssize_t length = readlink(path.fileSystemRepresentation, target, sizeof(target) - 1);
        if (length > 0) {
            target[length] = '\0';
            item.linkTarget = [NSString stringWithUTF8String:target];
        }
    }
    [FFPreviewRouter previewItem:item navigationController:nav];
    if (completion) completion(YES);
}

- (void)previewEntry:(FFEntry *)item
{
    [FFPreviewRouter previewItem:item navigationController:self.navigationController];
}










#pragma mark - Helpers

- (void)flash:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [self presentOnTop:alert];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.2 * NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{
            [alert dismissViewControllerAnimated:YES completion:nil];
        });
}

// UIKit silently drops presentViewController when an alert is already
// up; dismiss whatever is on top first so sequential prompts survive.
- (void)presentOnTop:(UIViewController *)controller
{
    if (self.presentedViewController) {
        UIViewController *presented = self.presentedViewController;
        [presented dismissViewControllerAnimated:NO completion:^{
            [self presentViewController:controller animated:YES completion:nil];
        }];
    } else {
        [self presentViewController:controller animated:YES completion:nil];
    }
}

- (void)showError:(NSError *)error
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"错误"
        message:error.localizedDescription ?: @"未知错误"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
