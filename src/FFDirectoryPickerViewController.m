#import "FFDirectoryPickerViewController.h"

#import "FFLogger.h"
#import "FFStorageEnvironment.h"

@interface FFDirectoryPickerViewController ()
@property(nonatomic, copy) NSString *rootPath;
@property(nonatomic, copy) NSString *currentPath;
@property(nonatomic, copy) NSArray<NSString *> *subdirectories;
@property(nonatomic, copy) void (^completion)(NSString *path);
@property(nonatomic, strong) UILabel *pathLabel;
@end

@implementation FFDirectoryPickerViewController

- (instancetype)initWithRootPath:(NSString *)rootPath
                      completion:(void (^)(NSString *))completion
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _rootPath = [rootPath copy];
        _currentPath = [rootPath copy];
        _completion = [completion copy];
        _subdirectories = @[];
        self.title = @"选择文件夹";
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
        target:self action:@selector(cancelTapped)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"选择"
        style:UIBarButtonItemStyleDone target:self action:@selector(chooseTapped)];

    self.pathLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 0, 34)];
    self.pathLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.pathLabel.textColor = UIColor.secondaryLabelColor;
    self.pathLabel.textAlignment = NSTextAlignmentCenter;
    self.pathLabel.lineBreakMode = NSLineBreakByTruncatingHead;
    self.tableView.tableHeaderView = self.pathLabel;

    [self reloadCurrentPath];
}

- (void)cancelTapped
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)chooseTapped
{
    NSString *path = self.currentPath;
    void (^completion)(NSString *) = self.completion;
    [self dismissViewControllerAnimated:YES completion:^{
        if (completion) completion(path);
    }];
}

- (BOOL)isAtRoot
{
    return [self.currentPath.stringByStandardizingPath isEqualToString:
        self.rootPath.stringByStandardizingPath];
}

- (void)reloadCurrentPath
{
    self.pathLabel.text = self.currentPath.lastPathComponent.length ?
        self.currentPath.lastPathComponent : self.currentPath;
    NSString *path = self.currentPath;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *manager = NSFileManager.defaultManager;
        NSArray<NSString *> *names = [[manager contentsOfDirectoryAtPath:path error:nil] ?: @[]
            sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
        NSMutableArray<NSString *> *directories = [NSMutableArray array];
        for (NSString *name in names) {
            if ([name hasPrefix:@"."]) continue;
            if (FFIsInternalStorageEntry(path, name)) continue;
            BOOL isDirectory = NO;
            NSString *child = [path stringByAppendingPathComponent:name];
            if ([manager fileExistsAtPath:child isDirectory:&isDirectory] && isDirectory)
                [directories addObject:child];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.subdirectories = directories;
            [strongSelf.tableView reloadData];
        });
    });
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return 1; }

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section
{
    return (NSInteger)self.subdirectories.count + (self.isAtRoot ? 0 : 1);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell"];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:@"Cell"];
    NSUInteger row = (NSUInteger)indexPath.row;
    if (!self.isAtRoot) {
        if (row == 0) {
            cell.textLabel.text = @"上一级";
            cell.imageView.image = [UIImage systemImageNamed:@"arrow.up"];
            cell.imageView.tintColor = UIColor.secondaryLabelColor;
            return cell;
        }
        row -= 1;
    }
    if (row < self.subdirectories.count) {
        NSString *path = self.subdirectories[row];
        cell.textLabel.text = path.lastPathComponent;
        cell.imageView.image = [UIImage systemImageNamed:@"folder"];
        cell.imageView.tintColor = UIColor.systemBlueColor;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSUInteger row = (NSUInteger)indexPath.row;
    if (!self.isAtRoot) {
        if (row == 0) {
            self.currentPath = self.currentPath.stringByDeletingLastPathComponent;
            [self reloadCurrentPath];
            return;
        }
        row -= 1;
    }
    if (row >= self.subdirectories.count) return;
    self.currentPath = self.subdirectories[row];
    [self reloadCurrentPath];
}

@end
