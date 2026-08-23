#import "FFSupportedViewersViewController.h"

#import "FFViewerRegistry.h"
#import "FFFileAssociationService.h"
#import "FFTypography.h"

@implementation FFSupportedViewersViewController

- (instancetype)init
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = @"支持的文件查看器";
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
        initWithTitle:@"恢复默认关联" style:UIBarButtonItemStylePlain
        target:self action:@selector(restoreDefaultsTapped)];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(reloadData)
        name:FFFileAssociationsDidChangeNotification object:nil];
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - Restore defaults

- (void)restoreDefaultsTapped
{
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:
        @"恢复默认关联"
        message:@"将清除全部自定义扩展名与覆盖项，恢复内置默认关联。此操作立即生效。"
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [confirm addAction:[UIAlertAction actionWithTitle:@"取消"
        style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"恢复默认"
        style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
            [[FFFileAssociationService sharedService] resetAllOverrides];
        }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)reloadData
{
    [self.tableView reloadData];
}

#pragma mark - Table

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section
{
    return [[FFViewerRegistry sharedRegistry] allViewers].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell"
        forIndexPath:indexPath];
    FFViewerInfo *viewer = [[FFViewerRegistry sharedRegistry] allViewers][(NSUInteger)indexPath.row];

    UIListContentConfiguration *config = [cell defaultContentConfiguration];
    config.text = viewer.displayName;
    config.textProperties.font = FFPreferredFont(UIFontTextStyleBody, UIFontWeightMedium);
    config.secondaryText = viewer.summary;
    config.secondaryTextProperties.numberOfLines = 0;
    config.secondaryTextProperties.font = FFPreferredFont(UIFontTextStyleFootnote, UIFontWeightRegular);
    config.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    UIImage *icon = [UIImage systemImageNamed:viewer.iconName];
    config.image = icon ?: [UIImage systemImageNamed:@"doc.text"];
    config.imageProperties.tintColor = [UIColor systemBlueColor];
    config.imageProperties.maximumSize = CGSizeMake(28, 28);
    cell.contentConfiguration = config;
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(__unused NSInteger)section
{
    return @"单击文件按「文件关联」选择查看器；长按文件可用「用其他查看器打开」。"
           "标注「暂不支持」的格式会明确提示，不会伪装成功。";
}

@end
