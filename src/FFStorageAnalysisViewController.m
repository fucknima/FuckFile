#import "FFStorageAnalysisViewController.h"

#import "FFLogger.h"
#import "FFStorageEnvironment.h"
#import "FFThumbnailService.h"

typedef NS_ENUM(NSInteger, FFStorageCategory) {
    FFStorageCategoryImages = 0,
    FFStorageCategoryVideos,
    FFStorageCategoryAudio,
    FFStorageCategoryDocuments,
    FFStorageCategoryArchives,
    FFStorageCategoryOther,
    FFStorageCategoryCount,
};

static NSString *FFStorageCategoryTitle(FFStorageCategory category)
{
    switch (category) {
        case FFStorageCategoryImages: return @"图片";
        case FFStorageCategoryVideos: return @"视频";
        case FFStorageCategoryAudio: return @"音频";
        case FFStorageCategoryDocuments: return @"文档";
        case FFStorageCategoryArchives: return @"压缩包";
        case FFStorageCategoryOther: return @"其他";
        case FFStorageCategoryCount: break;
    }
    return @"";
}

static NSArray<NSSet<NSString *> *> *FFStorageCategoryExtensions(void)
{
    static NSArray<NSSet<NSString *> *> *sets;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sets = @[
            [NSSet setWithArray:@[@"jpg", @"jpeg", @"png", @"gif", @"heic", @"heif",
                @"webp", @"bmp", @"tif", @"tiff", @"ico", @"car", @"dng", @"raw"]],
            [NSSet setWithArray:@[@"mp4", @"mov", @"m4v", @"mkv", @"avi", @"3gp",
                @"ts", @"flv", @"webm", @"mpg", @"mpeg"]],
            [NSSet setWithArray:@[@"mp3", @"wav", @"m4a", @"aac", @"aif", @"aiff",
                @"aifc", @"caf", @"m4b", @"m4p", @"m4r", @"flac", @"ogg", @"opus", @"wma"]],
            [NSSet setWithArray:@[@"doc", @"docx", @"docm", @"dot", @"dotx", @"dotm",
                @"ppt", @"pptx", @"pptm", @"pps", @"ppsx", @"pot", @"potx",
                @"xls", @"xlsx", @"xlsm", @"xlsb", @"csv", @"tsv", @"ods", @"odt", @"odp",
                @"rtf", @"rtfd", @"txt", @"md", @"markdown", @"log", @"json", @"xml",
                @"plist", @"pdf", @"epub", @"pages", @"numbers", @"key", @"wps",
                @"sqlite", @"sqlite3", @"db", @"html", @"htm", @"c", @"h", @"m", @"mm",
                @"cpp", @"cc", @"py", @"js", @"css", @"sh", @"swift", @"java", @"rs", @"go"]],
            [NSSet setWithArray:@[@"zip", @"ipa", @"7z", @"rar", @"tar", @"gz",
                @"tgz", @"bz2", @"tbz", @"tbz2", @"xz", @"txz", @"jar", @"apk"]],
        ];
    });
    return sets;
}

static FFStorageCategory FFStorageCategoryForExtension(NSString *extension)
{
    if (!extension.length) return FFStorageCategoryOther;
    NSArray<NSSet<NSString *> *> *sets = FFStorageCategoryExtensions();
    for (NSUInteger index = 0; index < sets.count; index++) {
        if ([sets[index] containsObject:extension]) return (FFStorageCategory)index;
    }
    return FFStorageCategoryOther;
}

static NSString *FFStorageFormatBytes(unsigned long long bytes)
{
    return [NSByteCountFormatter stringFromByteCount:(long long)bytes
        countStyle:NSByteCountFormatterCountStyleFile];
}

static unsigned long long FFStorageDirectorySize(NSString *path)
{
    NSFileManager *manager = NSFileManager.defaultManager;
    BOOL isDirectory = NO;
    if (!path.length || ![manager fileExistsAtPath:path isDirectory:&isDirectory] || !isDirectory)
        return 0;
    NSDirectoryEnumerator<NSURL *> *enumerator = [manager
        enumeratorAtURL:[NSURL fileURLWithPath:path]
        includingPropertiesForKeys:@[NSURLFileSizeKey]
        options:0
        errorHandler:nil];
    unsigned long long total = 0;
    for (NSURL *url in enumerator) {
        NSNumber *size = nil;
        if ([url getResourceValue:&size forKey:NSURLFileSizeKey error:nil])
            total += size.unsignedLongLongValue;
    }
    return total;
}

@interface FFStorageAnalysisViewController ()
@property(nonatomic) unsigned long long deviceTotal;
@property(nonatomic) unsigned long long deviceFree;
@property(nonatomic) unsigned long long appDataBytes;
@property(nonatomic) unsigned long long cacheBytes;
@property(nonatomic) unsigned long long trashBytes;
@property(nonatomic, copy) NSArray<NSNumber *> *categoryBytes;
@property(nonatomic) NSUInteger scannedFiles;
@property(nonatomic) BOOL scanning;
@property NSUInteger scanGeneration;
@property(nonatomic, weak) UIActivityIndicatorView *spinner;
@end

@implementation FFStorageAnalysisViewController

- (instancetype)init
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) self.title = @"存储空间";
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.hidesWhenStopped = YES;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithCustomView:spinner];
    self.spinner = spinner;
    UIBarButtonItem *rescan = [[UIBarButtonItem alloc] initWithTitle:@"重新扫描"
        style:UIBarButtonItemStylePlain target:self action:@selector(rescan)];
    self.navigationItem.leftBarButtonItem = rescan;
    self.categoryBytes = @[];
    [self refreshDeviceSpace];
    [self startScan];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    if (self.isMovingFromParentViewController) [self cancelScan];
}

- (void)dealloc
{
    _scanGeneration += 1;
}

- (void)cancelScan
{
    self.scanGeneration += 1;
}

#pragma mark - Device space

- (void)refreshDeviceSpace
{
    NSError *error = nil;
    NSDictionary *attributes = [NSFileManager.defaultManager
        attributesOfFileSystemForPath:NSHomeDirectory() error:&error];
    if (error || ![attributes isKindOfClass:NSDictionary.class]) {
        FFLogTag(@"Storage", @"fs attributes failed: %@", error.localizedDescription ?: @"unknown");
        return;
    }
    self.deviceTotal = [attributes[NSFileSystemSize] unsignedLongLongValue];
    self.deviceFree = [attributes[NSFileSystemFreeSize] unsignedLongLongValue];
    [self.tableView reloadData];
}

#pragma mark - Scan

- (void)rescan
{
    [self refreshDeviceSpace];
    [self startScan];
}

- (void)startScan
{
    self.scanGeneration += 1;
    NSUInteger generation = self.scanGeneration;
    self.scanning = YES;
    self.scannedFiles = 0;
    [self.spinner startAnimating];
    [self.tableView reloadData];

    NSString *root = FFStorageRootPath();
    NSString *cacheRoot = NSSearchPathForDirectoriesInDomains(
        NSCachesDirectory, NSUserDomainMask, YES).firstObject ?: @"";
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        unsigned long long category[FFStorageCategoryCount] = {0};
        unsigned long long appData = 0;
        unsigned long long trash = 0;
        NSUInteger files = 0;
        NSDate *lastUpdate = NSDate.date;

        NSURL *rootURL = [NSURL fileURLWithPath:root];
        NSDirectoryEnumerator<NSURL *> *enumerator = [NSFileManager.defaultManager
            enumeratorAtURL:rootURL
            includingPropertiesForKeys:@[NSURLFileSizeKey, NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey]
            options:0
            errorHandler:^BOOL(NSURL *url, NSError *error) {
                FFLogTag(@"Storage", @"scan skip path=%@ error=%@", url.path,
                    error.localizedDescription ?: @"unknown");
                return YES;
            }];
        for (NSURL *url in enumerator) {
            if (generation != weakSelf.scanGeneration) return;
            NSDictionary<NSURLResourceKey, id> *values =
                [url resourceValuesForKeys:@[NSURLFileSizeKey, NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey]
                                     error:nil];
            BOOL isDirectory = [values[NSURLIsDirectoryKey] boolValue];
            if ([values[NSURLIsSymbolicLinkKey] boolValue]) {
                [enumerator skipDescendants];
                continue;
            }
            if (isDirectory) continue;

            unsigned long long size = [values[NSURLFileSizeKey] unsignedLongLongValue];
            appData += size;
            files += 1;
            NSString *path = url.path;
            if ([path hasPrefix:[root stringByAppendingPathComponent:@".Trash"]]) {
                trash += size;
            } else {
                category[FFStorageCategoryForExtension(path.pathExtension.lowercaseString)] += size;
            }

            NSDate *now = NSDate.date;
            if ([now timeIntervalSinceDate:lastUpdate] > 0.2) {
                lastUpdate = now;
                NSUInteger snapshotFiles = files;
                unsigned long long snapshotAppData = appData;
                unsigned long long snapshotTrash = trash;
                NSMutableArray<NSNumber *> *snapshot = [NSMutableArray arrayWithCapacity:FFStorageCategoryCount];
                for (NSInteger index = 0; index < FFStorageCategoryCount; index++)
                    [snapshot addObject:@(category[index])];
                dispatch_async(dispatch_get_main_queue(), ^{
                    typeof(weakSelf) strongSelf = weakSelf;
                    if (!strongSelf || generation != strongSelf.scanGeneration) return;
                    strongSelf.scannedFiles = snapshotFiles;
                    strongSelf.appDataBytes = snapshotAppData;
                    strongSelf.trashBytes = snapshotTrash;
                    strongSelf.categoryBytes = snapshot;
                    [strongSelf.tableView reloadData];
                });
            }
        }

        unsigned long long cacheBytes = FFStorageDirectorySize(cacheRoot);
        NSMutableArray<NSNumber *> *categoryResult = [NSMutableArray arrayWithCapacity:FFStorageCategoryCount];
        for (NSInteger index = 0; index < FFStorageCategoryCount; index++)
            [categoryResult addObject:@(category[index])];

        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf.scanGeneration) return;
            strongSelf.scanning = NO;
            strongSelf.scannedFiles = files;
            strongSelf.appDataBytes = appData;
            strongSelf.trashBytes = trash;
            strongSelf.cacheBytes = cacheBytes;
            strongSelf.categoryBytes = categoryResult;
            [strongSelf.spinner stopAnimating];
            [strongSelf.tableView reloadData];
            FFLogTag(@"Storage", @"scan done files=%lu appData=%llu cache=%llu trash=%llu",
                (unsigned long)files, appData, cacheBytes, trash);
        });
    });
}

#pragma mark - Cache cleanup

- (void)clearCacheTapped
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清理缓存"
        message:@"将删除缩略图与临时缓存，不影响文件。"
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清理" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            [weakSelf clearCaches];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)clearCaches
{
    [FFThumbnailService.sharedService clearCaches];
    NSString *cacheRoot = NSSearchPathForDirectoriesInDomains(
        NSCachesDirectory, NSUserDomainMask, YES).firstObject ?: @"";
    if (!cacheRoot.length) return;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSFileManager *manager = NSFileManager.defaultManager;
        for (NSString *name in [manager contentsOfDirectoryAtPath:cacheRoot error:nil] ?: @[]) {
            [manager removeItemAtPath:[cacheRoot stringByAppendingPathComponent:name] error:nil];
        }
        unsigned long long bytes = FFStorageDirectorySize(cacheRoot);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.cacheBytes = bytes;
            [strongSelf.tableView reloadData];
            FFLogTag(@"Storage", @"cache cleared remaining=%llu", bytes);
        });
    });
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return 4; }

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case 0: return 3;
        case 1: return 3;
        case 2: return FFStorageCategoryCount;
        case 3: return 1;
    }
    return 0;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case 0: return @"设备存储";
        case 1: return @"本 App";
        case 2:
            return self.scanning
                ? [NSString stringWithFormat:@"分类占用（扫描中，%lu 个文件）",
                    (unsigned long)self.scannedFiles]
                : @"分类占用";
        case 3: return nil;
    }
    return nil;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section != 2 || self.scanning) return nil;
    return [NSString stringWithFormat:@"共 %lu 个文件 · %@",
        (unsigned long)self.scannedFiles, FFStorageFormatBytes(self.appDataBytes)];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell"];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                      reuseIdentifier:@"Cell"];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.textLabel.textAlignment = NSTextAlignmentNatural;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.detailTextLabel.text = nil;
    cell.imageView.image = nil;

    if (indexPath.section == 0) {
        NSArray<NSString *> *titles = @[@"总容量", @"可用空间", @"已用空间"];
        unsigned long long used = self.deviceTotal > self.deviceFree
            ? self.deviceTotal - self.deviceFree : 0;
        NSArray<NSNumber *> *values = @[@(self.deviceTotal), @(self.deviceFree), @(used)];
        cell.textLabel.text = titles[indexPath.row];
        cell.detailTextLabel.text = values[indexPath.row].unsignedLongLongValue
            ? FFStorageFormatBytes(values[indexPath.row].unsignedLongLongValue) : @"—";
    } else if (indexPath.section == 1) {
        NSArray<NSString *> *titles = @[@"App 数据", @"缓存", @"回收站"];
        NSArray<NSNumber *> *values = @[@(self.appDataBytes), @(self.cacheBytes), @(self.trashBytes)];
        cell.textLabel.text = titles[indexPath.row];
        cell.detailTextLabel.text = self.scanning && indexPath.row != 1
            ? @"扫描中…" : FFStorageFormatBytes(values[indexPath.row].unsignedLongLongValue);
    } else if (indexPath.section == 2) {
        FFStorageCategory category = (FFStorageCategory)indexPath.row;
        unsigned long long bytes = indexPath.row < (NSInteger)self.categoryBytes.count
            ? self.categoryBytes[indexPath.row].unsignedLongLongValue : 0;
        cell.textLabel.text = FFStorageCategoryTitle(category);
        cell.detailTextLabel.text = FFStorageFormatBytes(bytes);
    } else {
        cell.textLabel.text = @"清理缓存";
        cell.textLabel.textColor = UIColor.systemRedColor;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 3) [self clearCacheTapped];
}

@end
