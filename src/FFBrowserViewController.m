#import "FFBrowserViewController.h"
#import "FFCopyEngine.h"

#import <dirent.h>
#import <sys/stat.h>
#import <sys/xattr.h>
#import <objc/runtime.h>

typedef NS_ENUM(NSInteger, FFClipboardMode) {
    FFClipboardModeNone = 0,
    FFClipboardModeCopy,
    FFClipboardModeCut,
};

@interface FFEntry : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *path;
@property(nonatomic) BOOL isDirectory;
@property(nonatomic) BOOL isSymlink;
@property(nonatomic, copy) NSString *linkTarget;
@property(nonatomic, copy) NSString *detail; // size / mode / uid:gid
@property(nonatomic) unsigned long long size;
@end

@implementation FFEntry
@end

@interface FFBrowserViewController () <UIDocumentInteractionControllerDelegate>
@property(nonatomic, copy) NSString *currentPath;
@property(nonatomic, strong) NSArray<FFEntry *> *entries;
@property(nonatomic) BOOL loading;
@property(nonatomic, strong) UIBarButtonItem *pasteItem;
@end

// Process-wide paste state so Copy in one folder can Paste in another.
static NSString *gClipboardSource = nil;
static FFClipboardMode gClipboardMode = FFClipboardModeNone;

@implementation FFBrowserViewController

- (instancetype)initWithPath:(NSString *)path
{
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        _currentPath = [path copy];
        self.title = path.lastPathComponent.length ? path.lastPathComponent : @"Device Storage";
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 56;

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

    self.pasteItem = [[UIBarButtonItem alloc] initWithTitle:@"Paste"
        style:UIBarButtonItemStylePlain target:self action:@selector(pasteAction:)];
    self.navigationItem.rightBarButtonItems = @[self.pasteItem];
    [self updatePasteState];

    [self reloadEntries];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self updatePasteState];
    [self reloadEntries];
}

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
        NSArray<FFEntry *> *loaded = [self loadDirectoryContents];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.entries = loaded;
            self.loading = NO;
            [self.tableView reloadData];
            [self.refreshControl endRefreshing];
        });
    });
}

- (NSArray<FFEntry *> *)loadDirectoryContents
{
    NSMutableArray<FFEntry *> *result = [NSMutableArray array];
    DIR *directory = opendir(self.currentPath.fileSystemRepresentation);
    if (!directory) {
        NSLog(@"[FuckFile] opendir failed path=%@ errno=%d", self.currentPath, errno);
        return result;
    }
    struct dirent *entry = NULL;
    while ((entry = readdir(directory)) != NULL) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        NSString *name = [NSFileManager.defaultManager
            stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)];
        if (!name) continue;
        NSString *path = [self.currentPath stringByAppendingPathComponent:name];
        FFEntry *item = [FFEntry new];
        item.name = name;
        item.path = path;
        struct stat status = {0};
        if (lstat(path.fileSystemRepresentation, &status) != 0) {
            item.detail = [NSString stringWithFormat:@"lstat errno=%d", errno];
            [result addObject:item];
            continue;
        }
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
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        if (item.isDirectory) [parts addObject:@"dir"];
        if (item.isSymlink) [parts addObject:@"link"];
        [parts addObject:[NSString stringWithFormat:@"%04o", status.st_mode & 07777]];
        [parts addObject:[NSString stringWithFormat:@"%u:%u", status.st_uid, status.st_gid]];
        if (S_ISREG(status.st_mode))
            [parts addObject:[self formatSize:status.st_size]];
        if (item.linkTarget.length)
            [parts addObject:[NSString stringWithFormat:@"-> %@", item.linkTarget]];
        item.detail = [parts componentsJoinedByString:@"  "];
        [result addObject:item];
    }
    closedir(directory);
    [result sortUsingComparator:^NSComparisonResult(FFEntry *left, FFEntry *right) {
        if (left.isDirectory != right.isDirectory)
            return left.isDirectory ? NSOrderedAscending : NSOrderedDescending;
        return [left.name compare:right.name options:NSNumericSearch];
    }];
    return result;
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

#pragma mark - Table view

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.entries.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"Cell"];
        cell.textLabel.font = [UIFont systemFontOfSize:16];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:11];
        cell.detailTextLabel.numberOfLines = 0;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    FFEntry *item = self.entries[indexPath.row];
    cell.textLabel.text = item.name;
    cell.detailTextLabel.text = item.detail;
    if (item.isDirectory) {
        cell.imageView.image = [self symbolImage:@"folder" tint:[UIColor systemBlueColor]];
    } else if (item.isSymlink) {
        cell.imageView.image = [self symbolImage:@"link" tint:[UIColor systemTealColor]];
    } else {
        cell.imageView.image = [self symbolImage:@"doc" tint:[UIColor systemGrayColor]];
    }
    return cell;
}

- (UIImage *)symbolImage:(NSString *)name tint:(UIColor *)tint
{
    if (@available(iOS 13.0, *)) {
        UIImage *image = [UIImage systemImageNamed:name];
        return [image imageWithTintColor:tint renderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    return nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    FFEntry *item = self.entries[indexPath.row];
    if (item.isDirectory) {
        FFBrowserViewController *next = [[FFBrowserViewController alloc] initWithPath:item.path];
        [self.navigationController pushViewController:next animated:YES];
        return;
    }
    [self presentActionsForEntry:item];
}

#pragma mark - Actions

- (void)presentActionsForEntry:(FFEntry *)item
{
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:item.name
        message:item.detail preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;

    [sheet addAction:[UIAlertAction actionWithTitle:@"View" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf viewEntry:item]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf setClipboard:item mode:FFClipboardModeCopy]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cut" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf setClipboard:item mode:FFClipboardModeCut]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Rename" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) { [weakSelf renameEntry:item]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) { [weakSelf deleteEntry:item]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
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
        mode == FFClipboardModeCopy ? @"Copied" : @"Cut", item.name]];
}

- (void)pasteAction:(id)sender
{
    if (!gClipboardSource) return;
    if ([self pasteIsInsideClipboardSource]) return;
    NSString *destination = [self uniqueDestinationForName:gClipboardSource.lastPathComponent];
    if (!destination) {
        [self flash:@"Could not resolve a paste destination"];
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
        [self flash:@"Paste complete"];
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

- (void)renameEntry:(FFEntry *)item
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Rename"
        message:item.path preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = item.name;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Rename" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            NSString *newName = alert.textFields.firstObject.text;
            if (newName.length == 0 || [newName containsString:@"/"]) return;
            NSString *newPath = [self.currentPath stringByAppendingPathComponent:newName];
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
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Delete"
        message:[NSString stringWithFormat:@"Remove %@?", item.path]
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            NSError *error = nil;
            if (![[NSFileManager defaultManager] removeItemAtPath:item.path error:&error])
                [weakSelf showError:error];
            [weakSelf reloadEntries];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Viewing

- (void)viewEntry:(FFEntry *)item
{
    NSData *data = [NSData dataWithContentsOfFile:item.path];
    if (!data) {
        [self flash:@"Failed to read file"];
        return;
    }
    NSString *text = nil;
    NSDictionary *plist = nil;
    if (data.length > 0) {
        plist = [NSPropertyListSerialization propertyListWithData:data
            options:NSPropertyListImmutable format:NULL error:nil];
        if ([plist isKindOfClass:NSDictionary.class] || [plist isKindOfClass:NSArray.class]) {
            NSError *serializationError = nil;
            NSData *xml = [NSPropertyListSerialization dataWithPropertyList:plist
                format:NSPropertyListXMLFormat_v1_0 options:0 error:&serializationError];
            if (xml)
                text = [[NSString alloc] initWithData:xml encoding:NSUTF8StringEncoding];
        }
    }
    if (!text) {
        NSString *candidate = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (candidate && [self looksTextual:candidate]) text = candidate;
    }
    if (!text) text = [self hexdump:data maxBytes:4096];
    [self presentText:item.name body:text];
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
        [result appendFormat:@"\n... truncated at %lu of %lu bytes\n",
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
    textView.font = [UIFont fontWithName:@"Menlo" size:12];
    textView.text = body;
    [viewer.view addSubview:textView];
    [self.navigationController pushViewController:viewer animated:YES];
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
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Error"
        message:error.localizedDescription ?: @"Unknown error"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
