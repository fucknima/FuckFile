#import "FFFileAssociationsViewController.h"

#import "FFFileAssociationService.h"
#import "FFViewerRegistry.h"

@interface FFFileAssociationsViewController ()
@property(nonatomic, strong) NSArray<NSString *> *extensions;
@end

@implementation FFFileAssociationsViewController

- (instancetype)init
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = @"文件关联";
        self.navigationItem.largeTitleDisplayMode =
            UINavigationItemLargeTitleDisplayModeNever;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"Cell"];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self
                             action:@selector(addExtensionTapped)];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(associationChanged)
        name:FFFileAssociationsDidChangeNotification object:nil];
    [self reloadExtensions];
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)reloadExtensions
{
    self.extensions = [[FFFileAssociationService sharedService] allKnownExtensions];
}

// 关联变化（本页修改或恢复默认）都重算列表。
- (void)associationChanged
{
    [self reloadExtensions];
    [self.tableView reloadData];
}

#pragma mark - Add / remove custom extension

- (void)addExtensionTapped
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:
        @"新增自定义扩展名"
        message:@"输入不带点号的扩展名，例如 mkd；随后选择查看器。"
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"扩展名";
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"下一步"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            NSString *raw = alert.textFields.firstObject.text ?: @"";
            NSString *normalized =
                [FFFileAssociationService normalizedExtension:raw];
            if (normalized.length == 0) {
                [weakSelf flash:@"扩展名无效"];
                return;
            }
            [weakSelf pickViewerForExtension:normalized];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Association editing

// 点条目 → 查看器选择列表（含不可用状态的诚实标注）。
- (void)pickViewerForExtension:(NSString *)extension
{
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:
        [NSString stringWithFormat:@".%@ 使用", extension]
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    FFFileAssociationService *service =
        [FFFileAssociationService sharedService];
    for (FFViewerInfo *viewer in [[FFViewerRegistry sharedRegistry] allViewers]) {
        NSString *current = [service effectiveViewerIDForExtension:extension];
        BOOL isCurrent = [current isEqualToString:viewer.viewerID];
        UIAlertAction *action = [UIAlertAction actionWithTitle:
            isCurrent ? [NSString stringWithFormat:@"✓ %@", viewer.displayName]
                      : viewer.displayName
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *act) {
                [[FFFileAssociationService sharedService]
                    setOverrideViewerID:viewer.viewerID forExtension:extension];
                // 通知由服务发出并触发列表刷新。
            }];
        [sheet addAction:action];
    }
    // 内置默认项存在时允许删除覆盖。
    if ([service hasOverrideForExtension:extension]) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"删除此项（恢复默认）"
            style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
                [service removeOverrideForExtension:extension];
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

#pragma mark - Table

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section
{
    return (NSInteger)self.extensions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell"
        forIndexPath:indexPath];
    NSString *extension = self.extensions[(NSUInteger)indexPath.row];
    FFFileAssociationService *service = [FFFileAssociationService sharedService];
    NSString *viewerID = [service effectiveViewerIDForExtension:extension];
    FFViewerInfo *viewer = [[FFViewerRegistry sharedRegistry] viewerForID:viewerID];

    UIListContentConfiguration *config = [cell defaultContentConfiguration];
    config.text = [NSString stringWithFormat:@".%@", extension];
    config.textProperties.font =
        [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightMedium];

    if (viewer) {
        config.secondaryText = viewer.displayName;
        config.image = [UIImage systemImageNamed:viewer.iconName] ?:
            [UIImage systemImageNamed:@"doc.text"];
    } else {
        config.secondaryText = @"未关联";
        config.image = [UIImage systemImageNamed:@"questionmark.circle"];
    }
    config.imageProperties.tintColor = UIColor.systemBlueColor;
    config.imageProperties.maximumSize = CGSizeMake(24, 24);
    cell.contentConfiguration = config;

    if ([service hasOverrideForExtension:extension]) {
        UIButton *remove = [UIButton buttonWithType:UIButtonTypeSystem];
        [remove setTitle:@"删除" forState:UIControlStateNormal];
        [remove addTarget:self action:@selector(removeOverrideTapped:)
          forControlEvents:UIControlEventTouchUpInside];
        remove.tag = indexPath.row;
        [remove sizeToFit];
        cell.accessoryView = remove;
        cell.accessoryType = UITableViewCellAccessoryNone;
    } else {
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(__unused NSInteger)section
{
    return @"带「删除」的是自定义或覆盖项，删除后回到内置默认。匹配按最长后缀优先"
           "（backup.tar.gz 先试 .tar.gz 再试 .gz），大小写不敏感。";
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self pickViewerForExtension:self.extensions[(NSUInteger)indexPath.row]];
}

#pragma mark - Actions

- (void)removeOverrideTapped:(UIButton *)sender
{
    NSIndexPath *indexPath =
        [NSIndexPath indexPathForRow:sender.tag inSection:0];
    NSString *extension = self.extensions[(NSUInteger)indexPath.row];
    [[FFFileAssociationService sharedService]
        removeOverrideForExtension:extension];
}

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

@end
