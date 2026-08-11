#import "FFHomeViewController.h"
#import "FFBrowserViewController.h"
#import "FFProbeViewController.h"
#import "FFGestaltEditorViewController.h"
#import "BadQueryProbe.h"
#import "MCMManager.h"

@interface FFHomeViewController ()
@property(nonatomic) NSUInteger categoryCount;
@property(nonatomic) NSUInteger linkCount;
@property(nonatomic) NSUInteger escapedCount;
@property(nonatomic, copy) NSString *gestaltStatus;
@end

@implementation FFHomeViewController

- (instancetype)init
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) self.title = @"FuckFile";
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self
        action:@selector(reloadStatus)];

    __weak typeof(self) weakSelf = self;
    [[NSNotificationCenter defaultCenter] addObserverForName:@"FFProbeFinished"
        object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf reloadStatus]; });
        }];
    [self reloadStatus];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    [self reloadStatus];
}

- (void)reloadStatus
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *root = MCMVirtualRoot();
        NSFileManager *manager = NSFileManager.defaultManager;
        NSUInteger categories = 0;
        NSUInteger links = 0;
        for (NSString *name in [manager contentsOfDirectoryAtPath:root error:nil] ?: @[]) {
            NSString *path = [root stringByAppendingPathComponent:name];
            BOOL isDirectory = NO;
            if ([manager fileExistsAtPath:path isDirectory:&isDirectory] && isDirectory) {
                categories++;
                links += [[manager contentsOfDirectoryAtPath:path error:nil] count];
            }
        }
        NSDictionary *report = BadQueryProbeLastReport();
        NSUInteger escaped = 0;
        for (NSDictionary *probe in [report[@"Probes"] isKindOfClass:NSArray.class]
            ? report[@"Probes"] : @[]) {
            if ([probe[@"Status"] isKindOfClass:NSString.class] &&
                [probe[@"Status"] isEqualToString:@"escaped"]) escaped++;
        }
        NSString *error = nil;
        NSString *gestaltPath = [[MCMManager sharedManager] mobileGestaltPath:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.categoryCount = categories;
            self.linkCount = links;
            self.escapedCount = escaped;
            self.gestaltStatus = gestaltPath ? @"Editable" : (error ?: @"Unavailable");
            [self.tableView reloadData];
        });
    });
}

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 4;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case 0: return 1;
        case 1: return 1;
        case 2: return 2;
        case 3: return 2;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case 0: return @"Storage";
        case 1: return @"bad_query Probe";
        case 2: return @"Tools";
        case 3: return @"About";
        default: return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Home"];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"Home"];
    cell.detailTextLabel.numberOfLines = 0;
    cell.imageView.tintColor = [UIColor systemBlueColor];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    switch (indexPath.section) {
        case 0: {
            cell.textLabel.text = @"Device Storage";
            cell.detailTextLabel.text = [NSString stringWithFormat:
                @"%lu category folders, %lu active links", (unsigned long)self.categoryCount,
                (unsigned long)self.linkCount];
            cell.imageView.image = [UIImage systemImageNamed:@"folder.fill"];
            break;
        }
        case 1: {
            cell.textLabel.text = @"Probe Console";
            cell.detailTextLabel.text = [NSString stringWithFormat:
                @"%lu escaped paths — results, log, container mapping (UUID → bundle ID)",
                (unsigned long)self.escapedCount];
            cell.imageView.image = [UIImage systemImageNamed:@"waveform.path.ecg"];
            break;
        }
        case 2: {
            if (indexPath.row == 0) {
                cell.textLabel.text = @"MobileGestalt Editor";
                cell.detailTextLabel.text = [NSString stringWithFormat:@"Status: %@",
                    self.gestaltStatus ?: @"Checking…"];
                cell.imageView.image = [UIImage systemImageNamed:@"iphone.gen3"];
            } else {
                cell.textLabel.text = @"Wallpaper Lab";
                cell.detailTextLabel.text = @"PosterBoard .tendies import, inspect & rollback";
                cell.imageView.image = [UIImage systemImageNamed:@"photo.on.rectangle.angled"];
            }
            break;
        }
        case 3: {
            if (indexPath.row == 0) {
                cell.textLabel.text = @"Version";
                cell.detailTextLabel.text = [NSString stringWithFormat:
                    @"%@ (build %@) · iOS %@",
                    NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"?",
                    NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"?",
                    UIDevice.currentDevice.systemVersion];
                cell.imageView.image = [UIImage systemImageNamed:@"info.circle.fill"];
            } else {
                cell.textLabel.text = @"Credits";
                cell.detailTextLabel.text = @"MCM: FilzaSlop · Escape: bad_query · UI ideas: mond";
                cell.imageView.image = [UIImage systemImageNamed:@"person.3.fill"];
            }
            break;
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    UIViewController *next = nil;
    switch (indexPath.section) {
        case 0:
            next = [[FFBrowserViewController alloc] initWithPath:MCMVirtualRoot()];
            break;
        case 1:
            next = [FFProbeViewController new];
            break;
        case 2:
            if (indexPath.row == 0) {
                next = [FFGestaltEditorViewController new];
            } else {
                NSString *lab = [MCMVirtualRoot() stringByAppendingPathComponent:@"[MHA-C2] Wallpaper Lab"];
                next = [[FFBrowserViewController alloc] initWithPath:lab];
            }
            break;
        case 3:
            if (indexPath.row == 1) {
                [self presentCredits];
                return;
            }
            return;
    }
    if (next) [self.navigationController pushViewController:next animated:YES];
}

- (void)presentCredits
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Credits"
        message:@"MCM identity bypass & PosterBoard lab: 0xjohnnydev/FilzaSlop\nSandbox escape: forcequitOS/bad_query\nMobileGestalt editor concept: rooootdev/mond"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
