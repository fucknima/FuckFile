#import "FFViewerPickerViewController.h"
#import "FFBrowserViewController.h"
#import "FFViewerRegistry.h"
#import "FFFileAssociationService.h"
#import "FFPreviewRouter.h"
#import "FFLogger.h"

@interface FFViewerPickerViewController ()
@property(nonatomic, strong) FFEntry *item;
@property(nonatomic, copy) NSString *extension;
@end

@implementation FFViewerPickerViewController

- (instancetype)initWithFile:(FFEntry *)item
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _item = item;
        _extension = item.name.pathExtension.lowercaseString;
        self.title = item.displayName.length ? item.displayName : item.name;
    }
    return self;
}

- (instancetype)initWithExtension:(NSString *)extension
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _extension = extension;
        self.title = [NSString stringWithFormat:@".%@ 使用", extension];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"Viewer"];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(tableReload)
        name:FFFileAssociationsDidChangeNotification object:nil];
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)tableReload
{
    [self.tableView reloadData];
}

#pragma mark - Table

- (NSInteger)tableView:(__unused UITableView *)tableView
    numberOfRowsInSection:(__unused NSInteger)section
{
    return (NSInteger)[[FFViewerRegistry sharedRegistry] allViewers].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Viewer"
        forIndexPath:indexPath];
    FFViewerInfo *viewer =
        [[FFViewerRegistry sharedRegistry] allViewers][(NSUInteger)indexPath.row];
    NSString *current = [[FFFileAssociationService sharedService]
        effectiveViewerIDForExtension:self.extension];
    BOOL isDefault = current.length > 0 && [current isEqualToString:viewer.viewerID];

    UIListContentConfiguration *config = [cell defaultContentConfiguration];
    config.text = viewer.displayName;
    config.image = [UIImage systemImageNamed:viewer.iconName] ?:
        [UIImage systemImageNamed:@"doc.text"];
    config.imageProperties.tintColor = UIColor.systemBlueColor;
    config.imageProperties.maximumSize = CGSizeMake(28, 28);
    config.secondaryText = viewer.summary;
    config.secondaryTextProperties.font =
        [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    config.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    config.secondaryTextProperties.numberOfLines = 0;
    cell.contentConfiguration = config;
    cell.accessoryType = isDefault ? UITableViewCellAccessoryCheckmark
                                   : UITableViewCellAccessoryNone;
    return cell;
}

- (NSString *)tableView:(__unused UITableView *)tableView
    titleForFooterInSection:(__unused NSInteger)section
{
    return self.item ? @"选择后设为该类型的默认关联并立即打开。"
                     : @"选择后立即生效；扩展名覆盖项可在「文件关联」列表中删除恢复默认。";
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    FFViewerInfo *viewer =
        [[FFViewerRegistry sharedRegistry] allViewers][(NSUInteger)indexPath.row];
    if (!viewer) return;

    FFFileAssociationService *service = [FFFileAssociationService sharedService];
    [service setOverrideViewerID:viewer.viewerID forExtension:self.extension];
    // 服务在设置后立即发出通知，切换（overrides）与「删除此项」均由
    // 关联页与本地监听处理。

    if (!self.item || !self.navigationController) return;
    // 「用其他查看器打开」：选中即打开（关联写入立即生效）。
    FFLogTag(@"ViewerPicker", @"set extension=%@ viewer=%@ open=1",
             self.extension, viewer.viewerID);
    [FFPreviewRouter openItem:self.item viewerID:viewer.viewerID
        navigationController:self.navigationController];
}

@end
