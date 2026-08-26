#import "FFArchiveBrowserViewController.h"
#import "FFArchiveService.h"
#import "FFFileTask.h"
#import "FFFileTaskManager.h"
#import "FFPreviewRouter.h"

#import <objc/runtime.h>

@interface FFArchiveBrowserViewController (FFEncryptedPrivate)
- (void)rebuildVisibleNodes;
- (void)previewEntry:(id)node;
- (void)extractSelected;
- (void)extractAll;
- (NSString *)extractionRootForStem:(NSString *)stem;
@end

@implementation FFArchiveBrowserViewController (Encrypted)

+ (void)load
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = self;
        SEL pairs[][2] = {
            {@selector(viewDidLoad), @selector(ff_secure_viewDidLoad)},
            {@selector(rebuildVisibleNodes), @selector(ff_secure_rebuildVisibleNodes)},
            {@selector(previewEntry:), @selector(ff_secure_previewEntry:)},
            {@selector(extractSelected), @selector(ff_secure_extractSelected)},
            {@selector(extractAll), @selector(ff_secure_extractAll)},
            {@selector(setEditing:animated:), @selector(ff_secure_setEditing:animated:)},
        };
        for (NSUInteger i = 0; i < sizeof(pairs) / sizeof(pairs[0]); i++) {
            Method a = class_getInstanceMethod(cls, pairs[i][0]);
            Method b = class_getInstanceMethod(cls, pairs[i][1]);
            if (a && b) method_exchangeImplementations(a, b);
        }
    });
}

- (NSString *)ff_archivePath
{
    id value = [self valueForKey:@"archivePath"];
    return [value isKindOfClass:NSString.class] ? value : @"";
}

- (NSArray<FFArchiveEntry *> *)ff_archiveEntries
{
    id value = [self valueForKey:@"entries"];
    return [value isKindOfClass:NSArray.class] ? value : @[];
}

- (BOOL)ff_hasEncryptedEntryBelowPath:(NSString *)path directory:(BOOL)directory
{
    NSString *prefix = directory
        ? ([path hasSuffix:@"/"] ? path : [path stringByAppendingString:@"/"])
        : nil;
    for (FFArchiveEntry *entry in [self ff_archiveEntries]) {
        if (!entry.encrypted || entry.isDirectory) continue;
        if ((!directory && [entry.entryPath isEqualToString:path]) ||
            (directory && [entry.entryPath hasPrefix:prefix])) return YES;
    }
    return NO;
}

- (BOOL)ff_archiveContainsEncryptedFiles
{
    for (FFArchiveEntry *entry in [self ff_archiveEntries])
        if (entry.encrypted && !entry.isDirectory) return YES;
    return NO;
}

- (void)ff_withArchivePassword:(void (^)(NSString *password))completion
{
    NSString *archive = [self ff_archivePath];
    NSString *cached = [FFArchiveService cachedPasswordForArchivePath:archive];
    if (cached.length) {
        completion(cached);
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"加密 ZIP"
        message:@"输入压缩包密码。密码只保存在本次 App 运行内存中，不会写入磁盘。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"密码";
        field.secureTextEntry = YES;
        field.textContentType = UITextContentTypePassword;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"继续" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            NSString *password = alert.textFields.firstObject.text ?: @"";
            if (!password.length) return;
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [FFArchiveService cachePassword:password forArchivePath:[strongSelf ff_archivePath]];
            completion(password);
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)ff_updateArchiveUpButton
{
    if (self.editing) return;
    id value = [self valueForKey:@"pathStack"];
    NSArray *stack = [value isKindOfClass:NSArray.class] ? value : @[];
    self.navigationItem.leftItemsSupplementBackButton = YES;
    if (!stack.count) {
        self.navigationItem.leftBarButtonItem = nil;
        return;
    }
    UIBarButtonItem *up = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"arrow.up"]
        style:UIBarButtonItemStylePlain target:self action:@selector(ff_archiveGoUp)];
    up.accessibilityLabel = @"压缩包内上一级";
    self.navigationItem.leftBarButtonItem = up;
}

- (void)ff_archiveGoUp
{
    id value = [self valueForKey:@"pathStack"];
    NSMutableArray *stack = [value isKindOfClass:NSMutableArray.class] ? value : nil;
    if (!stack.count) return;
    [stack removeLastObject];
    [self rebuildVisibleNodes];
    [self.tableView reloadData];
}

- (void)ff_secure_viewDidLoad
{
    [self ff_secure_viewDidLoad];
    [self ff_updateArchiveUpButton];
}

- (void)ff_secure_rebuildVisibleNodes
{
    [self ff_secure_rebuildVisibleNodes];
    [self ff_updateArchiveUpButton];
}

- (void)ff_secure_setEditing:(BOOL)editing animated:(BOOL)animated
{
    [self ff_secure_setEditing:editing animated:animated];
    if (!editing) [self ff_updateArchiveUpButton];
}

- (void)ff_secure_previewEntry:(id)node
{
    NSString *path = [node valueForKey:@"fullPath"];
    BOOL directory = [[node valueForKey:@"isDirectory"] boolValue];
    if (![self ff_hasEncryptedEntryBelowPath:path directory:directory]) {
        [self ff_secure_previewEntry:node];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [self ff_withArchivePassword:^(__unused NSString *password) {
        [weakSelf ff_secure_previewEntry:node];
    }];
}

- (BOOL)ff_selectionContainsEncryptedFiles
{
    NSArray<NSIndexPath *> *selected = self.tableView.indexPathsForSelectedRows ?: @[];
    id value = [self valueForKey:@"visibleNodes"];
    NSArray *nodes = [value isKindOfClass:NSArray.class] ? value : @[];
    for (NSIndexPath *indexPath in selected) {
        if ((NSUInteger)indexPath.row >= nodes.count) continue;
        id node = nodes[(NSUInteger)indexPath.row];
        NSString *path = [node valueForKey:@"fullPath"];
        BOOL directory = [[node valueForKey:@"isDirectory"] boolValue];
        if ([self ff_hasEncryptedEntryBelowPath:path directory:directory]) return YES;
    }
    return NO;
}

- (void)ff_secure_extractSelected
{
    if (![self ff_selectionContainsEncryptedFiles]) {
        [self ff_secure_extractSelected];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [self ff_withArchivePassword:^(__unused NSString *password) {
        [weakSelf ff_secure_extractSelected];
    }];
}

- (void)ff_enqueueEncryptedExtractAllWithPassword:(NSString *)password
{
    NSString *archivePath = [self ff_archivePath];
    NSString *stem = archivePath.lastPathComponent.stringByDeletingPathExtension;
    if (!stem.length) stem = @"archive";
    FFFileTask *task = [FFFileTask new];
    task.kind = FFFileTaskKindExtract;
    task.displayName = [NSString stringWithFormat:@"解压 %@", stem];
    task.sources = @[archivePath];
    task.destination = [self extractionRootForStem:stem];
    task.archivePassword = password;
    [FFFileTaskManager.sharedManager enqueueTask:task];
    [FFPreviewRouter toastOnNav:self.navigationController
        message:[NSString stringWithFormat:@"已加入任务队列：%@", task.displayName]];
}

- (void)ff_secure_extractAll
{
    if (![self ff_archiveContainsEncryptedFiles]) {
        [self ff_secure_extractAll];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [self ff_withArchivePassword:^(NSString *password) {
        [weakSelf ff_enqueueEncryptedExtractAllWithPassword:password];
    }];
}

@end
