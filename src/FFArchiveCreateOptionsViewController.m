#import "FFArchiveCreateOptionsViewController.h"

@interface FFArchiveCreateOptionsViewController ()
@property(nonatomic, copy) NSString *suggestedName;
@property(nonatomic) NSUInteger itemCount;
@property(nonatomic, copy) void (^completion)(NSString *, FFArchiveCreateOptions *);
@property(nonatomic, strong) UITextField *nameField;
@property(nonatomic, strong) UISegmentedControl *formatControl;
@property(nonatomic, strong) UISegmentedControl *levelControl;
@property(nonatomic, strong) UITextField *passwordField;
@end

@implementation FFArchiveCreateOptionsViewController

- (instancetype)initWithSuggestedName:(NSString *)suggestedName
                            itemCount:(NSUInteger)itemCount
                           completion:(void (^)(NSString *, FFArchiveCreateOptions *))completion
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _suggestedName = [suggestedName copy] ?: @"归档.zip";
        _itemCount = itemCount;
        _completion = [completion copy];
        self.title = @"压缩";
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
        target:self action:@selector(cancelTapped)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"压缩" style:UIBarButtonItemStyleDone
        target:self action:@selector(commitTapped)];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return 1;
    if (section == 1) return 1;
    if (section == 2) return self.formatControl.selectedSegmentIndex == 1 ? 0 : 2;
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0) return @"名称";
    if (section == 1) return @"格式";
    if (section == 2 && self.formatControl.selectedSegmentIndex != 1) return @"ZIP 选项";
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 0)
        return [NSString stringWithFormat:@"%lu 个项目，将保存到当前目录。", (unsigned long)self.itemCount];
    if (section == 2 && self.formatControl.selectedSegmentIndex != 1)
        return @"密码为空时创建普通 ZIP；填写密码后使用 WinZip AES-256。密码只保存在本次任务内存中，不写入任务历史。";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                   reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    if (indexPath.section == 0) {
        if (!self.nameField) {
            self.nameField = [[UITextField alloc] initWithFrame:CGRectZero];
            self.nameField.text = self.suggestedName;
            self.nameField.placeholder = @"归档.zip";
            self.nameField.clearButtonMode = UITextFieldViewModeWhileEditing;
            self.nameField.autocapitalizationType = UITextAutocapitalizationTypeNone;
            self.nameField.autocorrectionType = UITextAutocorrectionTypeNo;
        }
        self.nameField.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:self.nameField];
        [NSLayoutConstraint activateConstraints:@[
            [self.nameField.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
            [self.nameField.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
            [self.nameField.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
            [self.nameField.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10],
        ]];
        return cell;
    }

    if (indexPath.section == 1) {
        if (!self.formatControl) {
            self.formatControl = [[UISegmentedControl alloc] initWithItems:@[@"ZIP", @"TAR"]];
            self.formatControl.selectedSegmentIndex =
                [self.suggestedName.lowercaseString hasSuffix:@".tar"] ? 1 : 0;
            [self.formatControl addTarget:self action:@selector(formatChanged:)
                         forControlEvents:UIControlEventValueChanged];
        }
        self.formatControl.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:self.formatControl];
        [NSLayoutConstraint activateConstraints:@[
            [self.formatControl.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
            [self.formatControl.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
            [self.formatControl.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:8],
            [self.formatControl.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
        ]];
        return cell;
    }

    if (indexPath.row == 0) {
        cell.textLabel.text = @"压缩级别";
        if (!self.levelControl) {
            self.levelControl = [[UISegmentedControl alloc] initWithItems:@[@"存储", @"均衡", @"最小"]];
            self.levelControl.selectedSegmentIndex = 1;
        }
        cell.accessoryView = self.levelControl;
    } else {
        cell.textLabel.text = @"密码";
        if (!self.passwordField) {
            self.passwordField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 190, 34)];
            self.passwordField.placeholder = @"可选 · AES-256";
            self.passwordField.secureTextEntry = YES;
            self.passwordField.textAlignment = NSTextAlignmentRight;
            self.passwordField.autocorrectionType = UITextAutocorrectionTypeNo;
            self.passwordField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        }
        cell.accessoryView = self.passwordField;
    }
    return cell;
}

- (void)formatChanged:(UISegmentedControl *)sender
{
    NSString *name = self.nameField.text ?: @"";
    if (sender.selectedSegmentIndex == 1) {
        if ([name.lowercaseString hasSuffix:@".zip"])
            self.nameField.text = [[name stringByDeletingPathExtension] stringByAppendingPathExtension:@"tar"];
    } else {
        if ([name.lowercaseString hasSuffix:@".tar"])
            self.nameField.text = [[name stringByDeletingPathExtension] stringByAppendingPathExtension:@"zip"];
    }
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:2]
                  withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)cancelTapped
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)commitTapped
{
    NSString *name = [self.nameField.text stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!name.length || ![name isEqualToString:name.lastPathComponent] ||
        [name isEqualToString:@"."] || [name isEqualToString:@".."]) {
        [self showError:@"请输入有效的压缩包名称"];
        return;
    }

    FFArchiveCreateOptions *options = [FFArchiveCreateOptions new];
    if (self.formatControl.selectedSegmentIndex == 1) {
        options.format = FFArchiveCreateFormatTAR;
        if (![name.lowercaseString hasSuffix:@".tar"])
            name = [name stringByAppendingPathExtension:@"tar"];
    } else {
        options.format = FFArchiveCreateFormatZIP;
        if (![name.lowercaseString hasSuffix:@".zip"])
            name = [name stringByAppendingPathExtension:@"zip"];
        NSInteger selected = self.levelControl ? self.levelControl.selectedSegmentIndex : 1;
        options.zipCompression = selected == 0 ? FFZipCompressionLevelStore :
            (selected == 2 ? FFZipCompressionLevelSmallest : FFZipCompressionLevelBalanced);
        NSString *password = self.passwordField.text ?: @"";
        if (password.length) {
            if (!FFArchiveEncryptedZIPWriterAvailable()) {
                [self showError:@"当前系统没有可用的 AES ZIP 写入后端。普通 ZIP 和 TAR 仍可使用。"];
                return;
            }
            options.zipEncryption = FFZipEncryptionModeAES256;
            options.password = password;
        }
    }

    void (^completion)(NSString *, FFArchiveCreateOptions *) = self.completion;
    [self dismissViewControllerAnimated:YES completion:^{
        if (completion) completion(name, options);
    }];
}

- (void)showError:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好"
        style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
