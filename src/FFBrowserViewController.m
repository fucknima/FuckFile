#import "FFBrowserViewController.h"
#import "FFCopyEngine.h"
#import "FFConflictPolicy.h"
#import "MCMManager.h"
#import "FFLogger.h"
#import "FFAppNames.h"
#import "FFZipExtract.h"
#import "FFTextEditorViewController.h"
#import "FFPlistEditorViewController.h"
#import "FFPdfPreviewViewController.h"

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

@interface FFEntry : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *displayName;
@property(nonatomic, copy) NSString *path;
@property(nonatomic) BOOL isDirectory;
@property(nonatomic) BOOL isSymlink;
@property(nonatomic, copy) NSString *linkTarget;
@property(nonatomic, copy) NSString *detail;
@property(nonatomic, copy) NSString *fullDetail;
@property(nonatomic) unsigned long long size;
@property(nonatomic, strong) NSDate *modificationDate;
@property(nonatomic, strong) NSDate *creationDate;
@property(nonatomic) mode_t mode;
@property(nonatomic) uid_t uid;
@property(nonatomic) gid_t gid;
@end

@implementation FFEntry
@end

// Map well-known bundle identifiers to readable display names; fall back to
// stripping the "com.apple." prefix and camel-case splitting.
@interface FFBrowserViewController () <UISearchResultsUpdating, UIDocumentInteractionControllerDelegate>
@property(nonatomic, copy) NSString *currentPath;
@property(nonatomic, strong) NSArray<FFEntry *> *entries;
@property(nonatomic, strong) NSArray<FFEntry *> *filteredEntries;
@property(nonatomic) BOOL loading;
@property(nonatomic) BOOL hasLoaded;
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
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _currentPath = [path copy];
        self.title = path.lastPathComponent.length ? path.lastPathComponent : @"设备存储";
        _sortMode = FFSortModeName;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 58;
    self.tableView.allowsMultipleSelectionDuringEditing = YES;

    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(reloadEntries)
                  forControlEvents:UIControlEventValueChanged];

    // Reload once the background MCM scan has finished.
    __weak typeof(self) weakSelf = self;
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
    self.navigationItem.rightBarButtonItems = @[self.pasteItem, self.sortItem, self.editItem];

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

#pragma mark - Batch mode (multi-select)

- (void)toggleBatchMode
{
    [self setEditing:!self.editing animated:YES];
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated
{
    [super setEditing:editing animated:animated];
    self.editItem.title = editing ? @"完成" : @"多选";
    self.navigationItem.rightBarButtonItems = editing
        ? @[self.editItem]
        : @[self.pasteItem, self.sortItem, self.editItem];
    if (editing) {
        if (!self.batchToolbarItems)
            self.batchToolbarItems = [self buildBatchToolbarItems];
        self.toolbarItems = self.batchToolbarItems;
    } else {
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
}

- (NSArray<UIBarButtonItem *> *)buildBatchToolbarItems
{
    UIBarButtonItem *selectAll = [[UIBarButtonItem alloc] initWithTitle:@"全选"
        style:UIBarButtonItemStylePlain target:self action:@selector(batchSelectAll)];
    UIBarButtonItem *copy = [[UIBarButtonItem alloc] initWithTitle:@"复制"
        style:UIBarButtonItemStylePlain target:self action:@selector(batchCopy)];
    UIBarButtonItem *cut = [[UIBarButtonItem alloc] initWithTitle:@"剪切"
        style:UIBarButtonItemStylePlain target:self action:@selector(batchCut)];
    UIBarButtonItem *share = [[UIBarButtonItem alloc] initWithTitle:@"分享"
        style:UIBarButtonItemStylePlain target:self action:@selector(batchShare)];
    UIBarButtonItem *trash = [[UIBarButtonItem alloc] initWithTitle:@"删除"
        style:UIBarButtonItemStylePlain target:self action:@selector(batchDelete)];
    trash.tintColor = [UIColor systemRedColor];
    return @[selectAll, copy, cut, share, trash];
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
    [self flash:[NSString stringWithFormat:@"%@ %lu 个项目",
        mode == FFClipboardModeCopy ? @"已复制" : @"已剪切", (unsigned long)items.count]];
    [self setEditing:NO animated:YES];
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
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSUInteger failed = 0;
                for (FFEntry *item in items) {
                    NSError *error = nil;
                    if (![[NSFileManager defaultManager] removeItemAtPath:item.path error:&error]) {
                        failed++;
                        FFLogTag(@"Browser", @"batch delete FAIL path=%@ error=%@",
                            item.path, error);
                    }
                }
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
            [self.refreshControl endRefreshing];
            if (loaded.count == 0 && self.loadError.length) {
                [self presentLoadError];
            }
        });
    });
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

- (void)presentLoadError
{
    NSString *message = self.loadError.length ? self.loadError : @"未知错误";
    message = [message stringByAppendingString:
        @"\n\n该容器未被 MHA 授权（containermanagerd 拒绝发 token），"
        @"或 token 已失效。可在「运行日志」重跑探针后重试。"];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法打开目录"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"重试"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [weakSelf reloadEntries];
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
        style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
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
        if (item.isDirectory) [parts addObject:@"dir"];
        if (item.isSymlink) [parts addObject:@"link"];
        [parts addObject:[NSString stringWithFormat:@"%04o", item.mode & 07777]];
        [parts addObject:[NSString stringWithFormat:@"%u:%u", item.uid, item.gid]];
        if (item.size > 0 || !item.isDirectory)
            [parts addObject:[self formatSize:item.size]];
        if (item.modificationDate)
            [parts addObject:[self formatDate:item.modificationDate]];
        if (item.linkTarget.length)
            [parts addObject:[NSString stringWithFormat:@"-> %@", item.linkTarget]];
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
            return [@[@"zip", @"ipa", @"deb", @"tar", @"gz", @"7z", @"rar", @"xz"] containsObject:ext];
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
    UIListContentConfiguration *config = [cell defaultContentConfiguration];
    config.text = item.displayName.length ? item.displayName : item.name;
    config.textProperties.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    config.secondaryText = item.detail;
    config.secondaryTextProperties.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    config.secondaryTextProperties.numberOfLines = 0;
    config.image = [self iconForEntry:item];
    config.imageProperties.tintColor = [self tintForEntry:item];
    config.imageProperties.cornerRadius = 4;
    cell.contentConfiguration = config;
    cell.accessoryType = item.isDirectory ? UITableViewCellAccessoryDisclosureIndicator
                                         : UITableViewCellAccessoryNone;
    return cell;
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
            @"zip": @"archivebox", @"ipa": @"archivebox", @"deb": @"archivebox",
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
            @"sh": @"terminal", @"command": @"terminal",
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
    if ([@[@"zip", @"ipa", @"deb", @"tar", @"gz", @"7z", @"rar", @"xz"] containsObject:ext])
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
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    FFEntry *item = self.filteredEntries[indexPath.row];
    if (item.isDirectory) {
        FFBrowserViewController *next = [[FFBrowserViewController alloc] initWithPath:item.path];
        next.title = item.displayName.length ? item.displayName : item.name;
        [self.navigationController pushViewController:next animated:YES];
        return;
    }
    [self previewEntry:item];
}

#pragma mark - Context menu & swipe actions

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
                    if (item.isDirectory) {
                        FFBrowserViewController *next = [[FFBrowserViewController alloc] initWithPath:item.path];
                        next.title = item.displayName.length ? item.displayName : item.name;
                        [weakSelf.navigationController pushViewController:next animated:YES];
                    } else {
                        [weakSelf previewEntry:item];
                    }
                }];
            UIAction *copy = [UIAction actionWithTitle:@"复制" image:[self symbolImage:@"doc.on.doc" tint:nil]
                identifier:nil handler:^(__unused UIAction *action) { [weakSelf setClipboard:item mode:FFClipboardModeCopy]; }];
            UIAction *cut = [UIAction actionWithTitle:@"剪切" image:[self symbolImage:@"scissors" tint:nil]
                identifier:nil handler:^(__unused UIAction *action) { [weakSelf setClipboard:item mode:FFClipboardModeCut]; }];
            UIAction *duplicate = [UIAction actionWithTitle:@"创建副本" image:[self symbolImage:@"plus.square.on.square" tint:nil]
                identifier:nil handler:^(__unused UIAction *action) { [weakSelf duplicateEntry:item]; }];
            UIAction *rename = [UIAction actionWithTitle:@"重命名" image:[self symbolImage:@"pencil" tint:nil]
                identifier:nil handler:^(__unused UIAction *action) { [weakSelf renameEntry:item]; }];
            UIAction *copyPath = [UIAction actionWithTitle:@"复制路径" image:[self symbolImage:@"point.topleft.down.curvedto.point.bottomright.up" tint:nil]
                identifier:nil handler:^(__unused UIAction *action) { [weakSelf copyPath:item]; }];
            UIAction *share = [UIAction actionWithTitle:@"分享" image:[self symbolImage:@"square.and.arrow.up" tint:nil]
                identifier:nil handler:^(__unused UIAction *action) { [weakSelf shareEntry:item]; }];
            UIAction *properties = [UIAction actionWithTitle:@"属性" image:[self symbolImage:@"info.circle" tint:nil]
                identifier:nil handler:^(__unused UIAction *action) { [weakSelf showProperties:item]; }];
            UIAction *delete = [UIAction actionWithTitle:@"删除" image:[self symbolImage:@"trash" tint:nil]
                identifier:nil handler:^(__unused UIAction *action) { [weakSelf deleteEntry:item]; }];
            delete.attributes = UIMenuElementAttributesDestructive;
            NSMutableArray *children = [NSMutableArray arrayWithArray:
                @[view, copy, cut, duplicate, rename, copyPath, share, properties, delete]];
            if ([self isArchiveEntry:item])
                [children insertObject:[UIAction actionWithTitle:@"解压"
                    image:[self symbolImage:@"shippingbox" tint:nil]
                    identifier:nil handler:^(__unused UIAction *action) { [weakSelf extractEntry:item]; }]
                    atIndex:children.count - 2];
            return [UIMenu menuWithTitle:item.name children:children];
        }];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
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
    [sheet addAction:[UIAlertAction actionWithTitle:@"剪切" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf setClipboard:item mode:FFClipboardModeCut]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"重命名" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf renameEntry:item]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"复制路径" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf copyPath:item]; }]];
    if ([self isArchiveEntry:item])
        [sheet addAction:[UIAlertAction actionWithTitle:@"解压" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) { [weakSelf extractEntry:item]; }]];
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
    [self flash:[NSString stringWithFormat:@"%@: %@",
        mode == FFClipboardModeCopy ? @"已复制" : @"已剪切", item.name]];
}

- (void)pasteAction:(id)sender
{
    if (gClipboardSources.count == 0) return;
    if ([self pasteIsInsideClipboardSource]) return;
    NSArray<NSString *> *sources = gClipboardSources;
    gClipboardSources = nil;
    FFClipboardMode mode = gClipboardMode;
    gClipboardMode = FFClipboardModeNone;
    [self performCopyOfSources:sources mode:mode];
}

// Copy/move loop with the conflict system: when a destination already
// exists the user chooses Replace / Skip / Keep Both / Replace All /
// Skip All (applied to the rest of the batch). Every decision runs on
// the main thread; the background thread waits on a semaphore.
- (void)performCopyOfSources:(NSArray<NSString *> *)sources mode:(FFClipboardMode)mode
{
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __block FFConflictAction applyAll = FFConflictActionAsk;
        NSUInteger failures = 0;
        NSUInteger skipped = 0;
        for (NSString *source in sources) {
            NSString *name = source.lastPathComponent;
            NSString *destination = [weakSelf.currentPath stringByAppendingPathComponent:name];
            struct stat existing = {0};
            BOOL conflict = lstat(destination.fileSystemRepresentation, &existing) == 0;
            if (conflict) {
                FFConflictAction action = applyAll != FFConflictActionAsk
                    ? applyAll
                    : [weakSelf askConflictForName:name];
                if (action == FFConflictActionSkip || action == FFConflictActionSkipAll) {
                    if (action == FFConflictActionSkipAll) applyAll = action;
                    skipped++;
                    FFLogTag(@"Browser", @"conflict skip %@", name);
                    continue;
                }
                if (action == FFConflictActionReplaceAll) applyAll = action;
                if (action == FFConflictActionReplace || action == FFConflictActionReplaceAll) {
                    NSError *removeError = nil;
                    if (![[NSFileManager defaultManager] removeItemAtPath:destination
                                                                     error:&removeError]) {
                        failures++;
                        FFLogTag(@"Browser", @"conflict replace failed %@ error=%@",
                                 name, removeError);
                        continue;
                    }
                } else {
                    // Keep Both -> auto-renamed sibling.
                    destination = [weakSelf uniqueDestinationForName:name];
                    if (!destination) {
                        failures++;
                        continue;
                    }
                }
            }
            NSError *error = nil;
            BOOL ok = [FFCopyEngine copyItemAtPath:source toPath:destination error:&error];
            if (ok && mode == FFClipboardModeCut) {
                NSError *removeError = nil;
                [[NSFileManager defaultManager] removeItemAtPath:source error:&removeError];
                if (removeError) ok = NO;
            }
            if (!ok) {
                failures++;
                FFLogTag(@"Browser", @"paste FAIL source=%@ error=%@", source, error);
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *summary = failures == 0 && skipped == 0 ? @"粘贴完成"
                : [NSString stringWithFormat:@"粘贴完成：%lu 成功，%lu 跳过，%lu 失败",
                    (unsigned long)(sources.count - failures - skipped),
                    (unsigned long)skipped, (unsigned long)failures];
            [weakSelf flash:summary];
            [weakSelf reloadEntries];
            [weakSelf updatePasteState];
        });
    });
}

// Blocks the calling (background) thread until the user picks a
// conflict action on the main thread.
- (FFConflictAction)askConflictForName:(NSString *)name
{
    __block FFConflictAction chosen = FFConflictActionSkip;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"目标已存在"
            message:[NSString stringWithFormat:@"“%@” 已存在于当前目录。", name]
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"替换" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                chosen = FFConflictActionReplace;
                dispatch_semaphore_signal(semaphore);
            }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"跳过" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                chosen = FFConflictActionSkip;
                dispatch_semaphore_signal(semaphore);
            }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"保留两者" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                chosen = FFConflictActionKeepBoth;
                dispatch_semaphore_signal(semaphore);
            }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"全部替换" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                chosen = FFConflictActionReplaceAll;
                dispatch_semaphore_signal(semaphore);
            }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"全部跳过" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                chosen = FFConflictActionSkipAll;
                dispatch_semaphore_signal(semaphore);
            }]];
        [self presentViewController:alert animated:YES completion:nil];
    });
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
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
            if (![[NSFileManager defaultManager] createDirectoryAtPath:path
                withIntermediateDirectories:NO attributes:nil error:&error])
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
            int fd = open(path.fileSystemRepresentation,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0644);
            if (fd < 0) {
                [weakSelf showError:[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{
                    NSLocalizedDescriptionKey: [NSString stringWithFormat:@"create %@: %s",
                        name, strerror(errno)]}]];
            } else {
                close(fd);
            }
            [weakSelf reloadEntries];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
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
            NSString *newPath = [weakSelf.currentPath stringByAppendingPathComponent:newName];
            NSError *error = nil;
            if (![[NSFileManager defaultManager] moveItemAtPath:item.path
                toPath:newPath error:&error])
                [weakSelf showError:error];
            [weakSelf reloadEntries];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
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
            if (![[NSFileManager defaultManager] removeItemAtPath:item.path error:&error])
                [weakSelf showError:error];
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
        extensions = [NSSet setWithArray:@[
            @"zip", @"ipa", @"deb", @"xcarchive", @"appex", @"app",
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
    [self flash:@"正在解压…"];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSArray<NSString *> *entries = nil;
        NSString *destination = sibling;
        if (!FFZipExtract(item.path, sibling, &entries, &error)) {
            // Sandbox-denied destinations fall back to the app's Documents.
            NSString *documents = NSSearchPathForDirectoriesInDomains(
                NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            NSString *extracted = [[documents stringByAppendingPathComponent:@"Device Storage"]
                stringByAppendingPathComponent:@"Extracted"];
            destination = [extracted stringByAppendingPathComponent:
                [stem stringByAppendingFormat:@"-%@",
                    [[[NSUUID UUID] UUIDString] substringToIndex:8]]];
            NSError *fallbackError = nil;
            if (!FFZipExtract(item.path, destination, &entries, &fallbackError))
                error = fallbackError;
            else
                error = nil;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                [weakSelf showError:error];
                return;
            }
            FFLogTag(@"Browser", @"extracted %@ -> %@ (%lu files)", item.path,
                destination, (unsigned long)(entries ? entries.count : 0));
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"解压完成"
                message:[NSString stringWithFormat:@"%lu 个文件\n%@",
                    (unsigned long)(entries ? entries.count : 0), destination]
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"打开" style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *action) {
                    FFBrowserViewController *next =
                        [[FFBrowserViewController alloc] initWithPath:destination];
                    next.title = destination.lastPathComponent;
                    [weakSelf.navigationController pushViewController:next animated:YES];
                }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
            [weakSelf presentViewController:alert animated:YES completion:nil];
            [weakSelf reloadEntries];
        });
    });
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

- (void)previewEntry:(FFEntry *)item
{
    NSString *ext = item.name.pathExtension.lowercaseString;
    static NSSet<NSString *> *images;
    static NSSet<NSString *> *videos;
    static NSSet<NSString *> *audios;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        images = [NSSet setWithArray:@[@"png", @"jpg", @"jpeg", @"gif", @"heic", @"webp", @"tiff", @"bmp"]];
        videos = [NSSet setWithArray:@[@"mp4", @"mov", @"m4v", @"avi", @"mkv"]];
        audios = [NSSet setWithArray:@[@"mp3", @"m4a", @"wav", @"aac", @"caf", @"flac"]];
    });
    if ([images containsObject:ext]) {
        [self previewImage:item];
        return;
    }
    if ([videos containsObject:ext] || [audios containsObject:ext]) {
        [self previewMedia:item];
        return;
    }
    if ([ext isEqualToString:@"pdf"]) {
        FFPdfPreviewViewController *viewer =
            [[FFPdfPreviewViewController alloc] initWithPath:item.path];
        [self.navigationController pushViewController:viewer animated:YES];
        return;
    }
    [self previewData:item];
}

- (void)previewImage:(FFEntry *)item
{
    UIImage *image = [UIImage imageWithContentsOfFile:item.path];
    if (!image) {
        [self flash:@"图片解码失败"];
        return;
    }
    UIViewController *viewer = [UIViewController new];
    viewer.title = item.name;
    UIImageView *imageView = [[UIImageView alloc] initWithFrame:viewer.view.bounds];
    imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    imageView.contentMode = UIViewContentModeScaleAspectFit;
    imageView.backgroundColor = [UIColor systemBackgroundColor];
    imageView.image = image;
    imageView.userInteractionEnabled = YES;
    [viewer.view addSubview:imageView];
    viewer.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:self
        action:@selector(shareCurrentItem:)];
    self.interactionItem = item;
    [self.navigationController pushViewController:viewer animated:YES];
}

- (void)previewMedia:(FFEntry *)item
{
    NSURL *url = [NSURL fileURLWithPath:item.path];
    AVPlayerViewController *player = [AVPlayerViewController new];
    player.player = [AVPlayer playerWithURL:url];
    [self.navigationController pushViewController:player animated:YES];
    [player.player play];
}

- (void)previewData:(FFEntry *)item
{
    NSData *data = [NSData dataWithContentsOfFile:item.path];
    if (!data) {
        [self flash:@"读取文件失败"];
        return;
    }
    // Structured plist editing: any parseable plist opens the plist editor.
    NSDictionary *plist = nil;
    if (data.length > 0) {
        NSPropertyListFormat format = NSPropertyListBinaryFormat_v1_0;
        plist = [NSPropertyListSerialization propertyListWithData:data
            options:NSPropertyListImmutable format:&format error:nil];
    }
    if ([plist isKindOfClass:NSDictionary.class] || [plist isKindOfClass:NSArray.class]) {
        FFPlistEditorViewController *editor =
            [[FFPlistEditorViewController alloc] initWithPath:item.path];
        [self.navigationController pushViewController:editor animated:YES];
        return;
    }
    NSString *candidate = [self stringFromData:data];
    if (candidate && [self looksTextual:candidate]) {
        FFTextEditorViewController *editor =
            [[FFTextEditorViewController alloc] initWithPath:item.path];
        [self.navigationController pushViewController:editor animated:YES];
        return;
    }
    NSString *text = [self hexdump:data maxBytes:data.length <= 1024 * 1024 ? data.length : 1024 * 1024];
    [self presentText:item.name body:text];
}

- (NSString *)stringFromData:(NSData *)data
{
    NSString *utf8 = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (utf8) return utf8;
    NSString *utf16 = [[NSString alloc] initWithData:data encoding:NSUTF16StringEncoding];
    if (utf16) return utf16;
    NSString *isoLatin1 = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    return isoLatin1;
}

- (BOOL)looksTextual:(NSString *)candidate
{
    if (candidate.length == 0) return YES;
    NSUInteger printable = 0;
    for (NSUInteger i = 0; i < candidate.length && i < 4096; i++) {
        unichar c = [candidate characterAtIndex:i];
        if (c >= 0x20 && c != 0x7F) printable++;
    }
    return printable * 10 >= candidate.length * 9;
}

- (NSString *)hexdump:(NSData *)data maxBytes:(NSUInteger)maxBytes
{
    const uint8_t *bytes = data.bytes;
    NSUInteger count = MIN(data.length, maxBytes);
    NSMutableString *result = [NSMutableString string];
    for (NSUInteger offset = 0; offset < count; offset += 16) {
        [result appendFormat:@"%08lx  ", (unsigned long)offset];
        NSUInteger lineLength = MIN((NSUInteger)16, count - offset);
        for (NSUInteger i = 0; i < 16; i++) {
            if (i < lineLength) [result appendFormat:@"%02x ", bytes[offset + i]];
            else [result appendString:@"   "];
            if (i == 7) [result appendString:@" "];
        }
        [result appendString:@" |"];
        for (NSUInteger i = 0; i < lineLength; i++) {
            uint8_t c = bytes[offset + i];
            [result appendFormat:@"%c", (c >= 0x20 && c != 0x7F) ? c : '.'];
        }
        [result appendString:@"|\n"];
    }
    if (data.length > maxBytes)
        [result appendFormat:@"\n… 已截断：共 %lu 字节，仅显示前 %lu 字节\n",
            (unsigned long)maxBytes, (unsigned long)data.length];
    return result;
}

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
    textView.backgroundColor = [UIColor systemBackgroundColor];
    [viewer.view addSubview:textView];
    viewer.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:self
        action:@selector(shareCurrentText:)];
    self.interactionText = body;
    [self.navigationController pushViewController:viewer animated:YES];
}

- (void)shareCurrentItem:(id)sender
{
    if (!self.interactionItem) return;
    [self shareEntry:self.interactionItem];
}

- (void)shareCurrentText:(id)sender
{
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:@[self.interactionText ?: @""] applicationActivities:nil];
    activity.popoverPresentationController.sourceView = self.view;
    [self presentViewController:activity animated:YES completion:nil];
}

#pragma mark - Helpers

- (void)flash:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.2 * NSEC_PER_SEC),
            dispatch_get_main_queue(), ^{
                [alert dismissViewControllerAnimated:YES completion:nil];
            });
    }];
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
