#import "FFBrowserViewController.h"
#import "FFCopyEngine.h"
#import "MCMManager.h"
#import "BadQueryProbe.h"
#import "FFLogger.h"
#import "PosterBoardFeature.h"

#import <AVKit/AVKit.h>
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
};

@interface FFEntry : NSObject
@property(nonatomic, copy) NSString *name;
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

@interface FFBrowserViewController () <UISearchResultsUpdating, UIDocumentInteractionControllerDelegate>
@property(nonatomic, copy) NSString *currentPath;
@property(nonatomic, strong) NSArray<FFEntry *> *entries;
@property(nonatomic, strong) NSArray<FFEntry *> *filteredEntries;
@property(nonatomic) BOOL loading;
@property(nonatomic) BOOL hasLoaded;
@property(nonatomic, strong) UIBarButtonItem *pasteItem;
@property(nonatomic, strong) UIBarButtonItem *sortItem;
@property(nonatomic, strong) UISearchController *searchController;
@property(nonatomic, copy) NSString *searchText;
@property(nonatomic) FFSortMode sortMode;
@property(nonatomic, copy) NSString *loadError;
@property(nonatomic, strong) FFEntry *interactionItem;
@property(nonatomic, copy) NSString *interactionText;
@end

// Process-wide paste state so Copy in one folder can Paste in another.
static NSString *gClipboardSource = nil;
static FFClipboardMode gClipboardMode = FFClipboardModeNone;
static NSMutableSet<NSString *> *gConsumedEscapedRoots;
static NSMutableSet<NSString *> *gConsumedLinkTargets;
static NSMutableSet<NSString *> *gConsumedDirectPaths;

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
    self.tableView.allowsMultipleSelectionDuringEditing = NO;

    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(reloadEntries)
                  forControlEvents:UIControlEventValueChanged];

    // Reload once the background bad_query probe has finished.
    __weak typeof(self) weakSelf = self;
    [[NSNotificationCenter defaultCenter] addObserverForName:@"FFProbeFinished"
        object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
            typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
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
    self.navigationItem.rightBarButtonItems = @[self.pasteItem, self.sortItem];

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
    PBWallpaperConfigureBrowser(self, self.currentPath);
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    self.navigationController.toolbarHidden = YES;
}

#pragma mark - Clipboard state

- (void)updatePasteState
{
    self.pasteItem.enabled = (gClipboardSource.length > 0) && ![self pasteIsInsideClipboardSource];
}

- (BOOL)pasteIsInsideClipboardSource
{
    if (!gClipboardSource) return NO;
    struct stat status = {0};
    if (lstat(gClipboardSource.fileSystemRepresentation, &status) != 0 || !S_ISDIR(status.st_mode))
        return NO;
    char sourceReal[PATH_MAX] = {0};
    char destinationReal[PATH_MAX] = {0};
    if (!realpath(gClipboardSource.fileSystemRepresentation, sourceReal) ||
        !realpath(self.currentPath.fileSystemRepresentation, destinationReal)) return NO;
    NSString *sourcePath = [NSString stringWithUTF8String:sourceReal];
    NSString *destinationPath = [NSString stringWithUTF8String:destinationReal];
    return [destinationPath isEqualToString:sourcePath] ||
        [destinationPath hasPrefix:[sourcePath stringByAppendingString:@"/"]];
}

#pragma mark - Loading

- (void)reloadEntries
{
    if (self.loading) return;
    self.loading = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            gConsumedEscapedRoots = [NSMutableSet set];
            gConsumedLinkTargets = [NSMutableSet set];
            gConsumedDirectPaths = [NSMutableSet set];
        });
        NSString *escapedRoot = [self escapedRootForPath:self.currentPath];
        NSString *linkTarget = [self symlinkTargetOfPath:self.currentPath];

        // Real paths outside the app's own container (e.g. the MobileGestalt
        // Caches directory opened from the editor, or an MCM lease target)
        // need their own sandbox extension. Consume the /var form once.
        NSString *varPath = [self varFormOfPath:self.currentPath];
        BOOL outsideOwnContainer = varPath.length &&
            ![self.currentPath hasPrefix:NSHomeDirectory()];
        if (outsideOwnContainer && !escapedRoot.length && !linkTarget.length) {
            BOOL cached = NO;
            @synchronized (gConsumedDirectPaths) {
                cached = [gConsumedDirectPaths containsObject:varPath];
            }
            if (!cached) {
                NSString *error = nil;
                int64_t handle = BadQueryConsumePath(varPath, nil, NO, &error);
                FFLogTag(@"Browser", @"escaped reconnect direct=%@ path=%@ handle=%lld error=%@",
                    varPath, self.currentPath, handle, error ?: @"(nil)");
                if (handle >= 0) {
                    @synchronized (gConsumedDirectPaths) {
                        [gConsumedDirectPaths addObject:varPath];
                    }
                }
            }
        }

        // Inside [BadQuery] Escaped the sandbox extension may be gone after a
        // restart. Re-consume the matching real root, and if the current path
        // is itself a symlink (a container UUID/bundle-id link), consume its
        // target too. Every step is written to FuckFile Log.txt.
        if (escapedRoot.length) {
            BOOL cached = NO;
            @synchronized (gConsumedEscapedRoots) {
                cached = [gConsumedEscapedRoots containsObject:escapedRoot];
            }
            if (!cached) {
                NSString *error = nil;
                int64_t handle = BadQueryConsumePath(escapedRoot, nil, NO, &error);
                FFLogTag(@"Browser", @"escaped reconnect root=%@ path=%@ handle=%lld error=%@",
                    escapedRoot, self.currentPath, handle, error ?: @"(nil)");
                if (handle >= 0) {
                    @synchronized (gConsumedEscapedRoots) {
                        [gConsumedEscapedRoots addObject:escapedRoot];
                    }
                }
            }
        }
        if (linkTarget.length) {
            BOOL cached = NO;
            @synchronized (gConsumedLinkTargets) {
                cached = [gConsumedLinkTargets containsObject:linkTarget];
            }
            if (!cached) {
                NSString *error = nil;
                int64_t handle = BadQueryConsumePath(linkTarget, nil, NO, &error);
                FFLogTag(@"Browser", @"escaped reconnect target=%@ handle=%lld error=%@",
                    linkTarget, handle, error ?: @"(nil)");
                if (handle >= 0) {
                    @synchronized (gConsumedLinkTargets) {
                        [gConsumedLinkTargets addObject:linkTarget];
                    }
                }
            }
        }
        NSArray<FFEntry *> *loaded = [self loadDirectoryContents];
        if (loaded.count == 0 && self.loadError.length && varPath.length) {
            // The first open may have raced the token issuance; consume again
            // (failure is not cached) and try once more before showing the
            // error alert.
            NSString *error = nil;
            int64_t retryHandle = BadQueryConsumePath(varPath, nil, NO, &error);
            FFLogTag(@"Browser", @"escaped retry direct=%@ handle=%lld error=%@",
                varPath, retryHandle, error ?: @"(nil)");
            loaded = [self loadDirectoryContents];
        }
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

- (NSString *)escapedRootForPath:(NSString *)path
{
    NSArray<NSString *> *parts = path.pathComponents;
    NSUInteger index = [parts indexOfObject:@"[BadQuery] Escaped"];
    if (index == NSNotFound || index + 1 >= parts.count) return nil;
    NSString *folder = parts[index + 1];
    static NSDictionary<NSString *, NSString *> *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            @"App Data": @"/var/mobile/Containers/Data/Application",
            @"InternalDaemon": @"/var/mobile/Containers/Data/InternalDaemon",
            @"PluginKitPlugin": @"/var/mobile/Containers/Data/PluginKitPlugin",
            @"App Groups": @"/var/mobile/Containers/Shared/AppGroup",
            @"System Groups": @"/var/mobile/Containers/Shared/SystemGroup",
            @"SystemGroup (new path)": @"/var/containers/Shared/SystemGroup",
        };
    });
    return map[folder];
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

- (NSString *)varFormOfPath:(NSString *)path
{
    if ([path hasPrefix:@"/private/var"]) return [path substringFromIndex:8];
    if ([path hasPrefix:@"/var"]) return path;
    return nil;
}

- (void)presentLoadError
{
    NSString *message = self.loadError.length ? self.loadError : @"未知错误";
    message = [message stringByAppendingString:
        @"\n\n沙盒扩展可能已经失效。App 已尝试自动重新消费 token；"
        @"如果仍然失败，请到「bad_query 探针控制台」点「枚举容器」重建链接，"
        @"或点「重新运行探针」后重试。"];
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
        [result addObject:item];
    }
    closedir(directory);
    FFLogTag(@"Browser", @"dir scan path=%@ total=%lu dirs=%lu files=%lu links=%lu lstatFail=%lu",
        self.currentPath, (unsigned long)total, (unsigned long)dirs,
        (unsigned long)files, (unsigned long)links, (unsigned long)lstatFailures);
    [self decorateEntries:result];
    [result sortUsingComparator:^NSComparisonResult(FFEntry *left, FFEntry *right) {
        if (left.isDirectory != right.isDirectory)
            return left.isDirectory ? NSOrderedAscending : NSOrderedDescending;
        switch (self.sortMode) {
            case FFSortModeSize:
                if (left.size != right.size)
                    return left.size > right.size ? NSOrderedAscending : NSOrderedDescending;
                break;
            case FFSortModeDate:
                return [right.modificationDate compare:left.modificationDate];
            case FFSortModeName:
            default:
                break;
        }
        return [left.name compare:right.name options:NSNumericSearch];
    }];
    return result;
}

- (void)decorateEntries:(NSArray<FFEntry *> *)entries
{
    for (FFEntry *item in entries) {
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
    if (!self.searchText.length) {
        self.filteredEntries = self.entries;
        return;
    }
    NSPredicate *predicate = [NSPredicate predicateWithFormat:
        @"name contains[cd] %@ OR path contains[cd] %@", self.searchText, self.searchText];
    self.filteredEntries = [self.entries filteredArrayUsingPredicate:predicate];
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
    name.state = self.sortMode == FFSortModeName ? UIMenuElementStateOn : UIMenuElementStateOff;
    size.state = self.sortMode == FFSortModeSize ? UIMenuElementStateOn : UIMenuElementStateOff;
    date.state = self.sortMode == FFSortModeDate ? UIMenuElementStateOn : UIMenuElementStateOff;
    return [UIMenu menuWithTitle:@"排序方式" children:@[name, size, date]];
}

- (void)setSortMode:(FFSortMode)sortMode
{
    _sortMode = sortMode;
    self.sortItem.menu = [self sortMenu];
    [self reloadEntries];
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
    config.text = item.name;
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
                        [weakSelf.navigationController pushViewController:next animated:YES];
                    } else {
                        [weakSelf previewEntry:item];
                    }
                }];
            UIAction *copy = [UIAction actionWithTitle:@"复制" image:[self symbolImage:@"doc.on.doc" tint:nil]
                identifier:nil handler:^(__unused UIAction *action) { [weakSelf setClipboard:item mode:FFClipboardModeCopy]; }];
            UIAction *cut = [UIAction actionWithTitle:@"剪切" image:[self symbolImage:@"scissors" tint:nil]
                identifier:nil handler:^(__unused UIAction *action) { [weakSelf setClipboard:item mode:FFClipboardModeCut]; }];
            UIAction *rename = [UIAction actionWithTitle:@"重命名" image:[self symbolImage:@"pencil" tint:nil]
                identifier:nil handler:^(__unused UIAction *action) { [weakSelf renameEntry:item]; }];
            UIAction *share = [UIAction actionWithTitle:@"分享" image:[self symbolImage:@"square.and.arrow.up" tint:nil]
                identifier:nil handler:^(__unused UIAction *action) { [weakSelf shareEntry:item]; }];
            UIAction *properties = [UIAction actionWithTitle:@"属性" image:[self symbolImage:@"info.circle" tint:nil]
                identifier:nil handler:^(__unused UIAction *action) { [weakSelf showProperties:item]; }];
            UIAction *delete = [UIAction actionWithTitle:@"删除" image:[self symbolImage:@"trash" tint:nil]
                identifier:nil handler:^(__unused UIAction *action) { [weakSelf deleteEntry:item]; }];
            delete.attributes = UIMenuElementAttributesDestructive;
            return [UIMenu menuWithTitle:item.name children:@[view, copy, cut, rename, share, properties, delete]];
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
                [weakSelf.navigationController pushViewController:next animated:YES];
            } else {
                [weakSelf previewEntry:item];
            }
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"复制" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf setClipboard:item mode:FFClipboardModeCopy]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"剪切" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf setClipboard:item mode:FFClipboardModeCut]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"重命名" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf renameEntry:item]; }]];
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
    gClipboardSource = item.path;
    gClipboardMode = mode;
    [self updatePasteState];
    [self flash:[NSString stringWithFormat:@"%@: %@",
        mode == FFClipboardModeCopy ? @"已复制" : @"已剪切", item.name]];
}

- (void)pasteAction:(id)sender
{
    if (!gClipboardSource) return;
    if ([self pasteIsInsideClipboardSource]) return;
    NSString *destination = [self uniqueDestinationForName:gClipboardSource.lastPathComponent];
    if (!destination) {
        [self flash:@"无法确定粘贴目标"];
        return;
    }
    NSError *error = nil;
    BOOL ok = [FFCopyEngine copyItemAtPath:gClipboardSource toPath:destination error:&error];
    if (ok && gClipboardMode == FFClipboardModeCut) {
        NSError *removeError = nil;
        [[NSFileManager defaultManager] removeItemAtPath:gClipboardSource error:&removeError];
        if (removeError) ok = NO;
    }
    if (ok) {
        gClipboardSource = nil;
        gClipboardMode = FFClipboardModeNone;
        [self flash:@"粘贴完成"];
        [self reloadEntries];
    } else {
        [self showError:error];
    }
    [self updatePasteState];
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

- (void)showProperties:(FFEntry *)item
{
    [self presentText:item.name body:item.fullDetail ?: item.detail];
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
    NSString *text = nil;
    NSDictionary *plist = nil;
    if (data.length > 0) {
        NSPropertyListFormat format = NSPropertyListBinaryFormat_v1_0;
        plist = [NSPropertyListSerialization propertyListWithData:data
            options:NSPropertyListImmutable format:&format error:nil];
        if ([plist isKindOfClass:NSDictionary.class] || [plist isKindOfClass:NSArray.class]) {
            NSError *serializationError = nil;
            NSData *xml = [NSPropertyListSerialization dataWithPropertyList:plist
                format:NSPropertyListXMLFormat_v1_0 options:0 error:&serializationError];
            if (xml)
                text = [[NSString alloc] initWithData:xml encoding:NSUTF8StringEncoding];
        }
    }
    if (!text) {
        NSString *candidate = [self stringFromData:data];
        if (candidate && [self looksTextual:candidate]) text = candidate;
    }
    if (!text) text = [self hexdump:data maxBytes:data.length <= 1024 * 1024 ? data.length : 1024 * 1024];
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
