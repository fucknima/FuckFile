#import "FFProbeViewController.h"
#import "BadQueryProbe.h"

#import <sys/utsname.h>

@interface FFProbeViewController ()
@property(nonatomic, strong) NSDictionary *report;
@property(nonatomic) int64_t lastHandle;
@property(nonatomic) BOOL running;
@end

@implementation FFProbeViewController

- (instancetype)init
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) self.title = @"bad_query";
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self reloadReport];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self reloadReport];
}

- (void)reloadReport
{
    self.report = BadQueryProbeLastReport();
    [self.tableView reloadData];
}

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case 0: return 4;
        case 1: return 7;
        case 2: {
            NSArray *probes = [self.report[@"Probes"] isKindOfClass:NSArray.class]
                ? self.report[@"Probes"] : @[];
            return probes.count;
        }
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case 0: return @"Status";
        case 1: return @"Actions";
        case 2: return @"Probes";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 2 && [self.report[@"Probes"] isKindOfClass:NSArray.class])
        return @"Tap a probe for the full step result. Escaped paths are symlinked into Device Storage/[BadQuery] Escaped.";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Status"];
        if (!cell)
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                          reuseIdentifier:@"Status"];
        cell.detailTextLabel.numberOfLines = 0;
        cell.accessoryType = UITableViewCellAccessoryNone;
        NSDictionary *environment = [self.report[@"Environment"] isKindOfClass:NSDictionary.class]
            ? self.report[@"Environment"] : nil;
        switch (indexPath.row) {
            case 0:
                cell.textLabel.text = @"System";
                cell.detailTextLabel.text = environment
                    ? [NSString stringWithFormat:@"iOS %@ (%@)", environment[@"SystemVersion"], environment[@"Build"]]
                    : [NSString stringWithFormat:@"iOS %@", UIDevice.currentDevice.systemVersion];
                break;
            case 1:
                cell.textLabel.text = @"Report";
                if (!self.report) {
                    cell.detailTextLabel.text = @"Not run yet";
                } else {
                    NSArray *probes = [self.report[@"Probes"] isKindOfClass:NSArray.class]
                        ? self.report[@"Probes"] : @[];
                    NSUInteger escaped = 0;
                    for (NSDictionary *probe in probes)
                        if ([probe[@"Status"] isKindOfClass:NSString.class] &&
                            [probe[@"Status"] isEqualToString:@"escaped"]) escaped++;
                    cell.detailTextLabel.text = [NSString stringWithFormat:
                        @"%lu/%lu escaped", (unsigned long)escaped, (unsigned long)probes.count];
                }
                break;
            case 2:
                cell.textLabel.text = @"Last run";
                cell.detailTextLabel.text = [self.report[@"CreatedAt"] isKindOfClass:NSDate.class]
                    ? [NSDateFormatter localizedStringFromDate:self.report[@"CreatedAt"]
                        dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterMediumStyle]
                    : @"Never";
                break;
            case 3:
                cell.textLabel.text = @"App Group sacrifice";
                cell.detailTextLabel.text = [self.report[@"SacrificeGroupConfigured"] boolValue]
                    ? @"Configured" : @"Not configured";
                break;
        }
        return cell;
    }

    if (indexPath.section == 1) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Action"];
        if (!cell)
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:@"Action"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.textLabel.textColor = [UIColor labelColor];
        cell.textLabel.textAlignment = NSTextAlignmentLeft;
        switch (indexPath.row) {
            case 0: cell.textLabel.text = @"Re-run Probe"; break;
            case 1: cell.textLabel.text = @"View Step Log"; break;
            case 2: cell.textLabel.text = @"View Results Plist"; break;
            case 3: cell.textLabel.text = @"Consume Custom Path"; break;
            case 4: cell.textLabel.text = self.lastHandle >= 0
                ? [NSString stringWithFormat:@"Release Extension (handle %lld)", self.lastHandle]
                : @"Release Extension"; break;
            case 5: cell.textLabel.text = @"Enumerate Containers (UUID → Bundle ID)"; break;
            case 6: cell.textLabel.text = @"Set App Group Sacrifice"; break;
        }
        return cell;
    }

    NSArray *probes = [self.report[@"Probes"] isKindOfClass:NSArray.class]
        ? self.report[@"Probes"] : @[];
    NSDictionary *probe = probes[indexPath.row];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Probe"];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"Probe"];
    cell.textLabel.text = [probe[@"Name"] isKindOfClass:NSString.class] ? probe[@"Name"] : @"Probe";
    NSString *status = [probe[@"Status"] isKindOfClass:NSString.class] ? probe[@"Status"] : @"?";
    NSString *path = [probe[@"Path"] isKindOfClass:NSString.class] ? probe[@"Path"] : @"";
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ — %@", status, path];
    cell.detailTextLabel.numberOfLines = 0;
    cell.imageView.image = [UIImage systemImageNamed:
        [status isEqualToString:@"escaped"] ? @"checkmark.circle.fill" : @"xmark.circle.fill"];
    cell.imageView.tintColor = [status isEqualToString:@"escaped"]
        ? [UIColor systemGreenColor] : [UIColor systemRedColor];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) return;
    if (indexPath.section == 1) {
        switch (indexPath.row) {
            case 0: [self rerunProbe]; break;
            case 1: [self presentText:@"Probe Log" body:BadQueryProbeLogText()]; break;
            case 2: [self presentResults]; break;
            case 3: [self consumeCustomPath]; break;
            case 4: [self releaseHandle]; break;
            case 5: [self enumerateContainers]; break;
            case 6: [self setSacrificeGroup]; break;
        }
        return;
    }
    NSArray *probes = [self.report[@"Probes"] isKindOfClass:NSArray.class]
        ? self.report[@"Probes"] : @[];
    NSDictionary *probe = probes[indexPath.row];
    [self presentProbeDetail:probe];
}

#pragma mark - Actions

- (void)rerunProbe
{
    if (self.running) return;
    self.running = YES;
    [self flash:@"Probe running in the background…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BadQueryProbeRunAgain();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.running = NO;
            [self reloadReport];
            [self flash:@"Probe complete"];
        });
    });
}

- (void)consumeCustomPath
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Consume Custom Path"
        message:@"Runs bad_query against an absolute path and keeps the sandbox extension handle."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = @"/var/mobile/Containers/Data/Application";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.keyboardType = UIKeyboardTypeURL;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Consume" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            NSString *path = alert.textFields.firstObject.text;
            [weakSelf runConsume:path];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)runConsume:(NSString *)path
{
    if (!path.length) return;
    [self flash:@"Consuming sandbox extension…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error = nil;
        int64_t handle = BadQueryConsumePath(path, nil, NO, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (handle >= 0) {
                self.lastHandle = handle;
                [self flash:[NSString stringWithFormat:@"Escaped! handle=%lld (%@)", handle, path]];
            } else {
                [self flash:error ?: [NSString stringWithFormat:@"Failed (code=%lld)", handle]];
            }
            [self.tableView reloadData];
        });
    });
}

- (void)releaseHandle
{
    if (self.lastHandle < 0) {
        [self flash:@"No active handle"];
        return;
    }
    BadQueryReleaseHandle(self.lastHandle);
    self.lastHandle = -1;
    [self flash:@"Extension released"];
    [self.tableView reloadData];
}

- (void)enumerateContainers
{
    if (self.running) return;
    self.running = YES;
    [self flash:@"Enumerating containers with bad_query_list…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *summary = BadQueryEnumerateAllContainers();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.running = NO;
            NSUInteger total = 0;
            for (NSDictionary *result in [summary[@"Results"] isKindOfClass:NSArray.class]
                ? summary[@"Results"] : @[]) {
                NSNumber *count = [result[@"Count"] isKindOfClass:NSNumber.class]
                    ? result[@"Count"] : nil;
                total += count ? count.unsignedIntegerValue : 0;
            }
            [self reloadReport];
            [self flash:[NSString stringWithFormat:
                @"Mapped %lu containers into Device Storage/[BadQuery] Escaped/", total]];
        });
    });
}

- (void)setSacrificeGroup
{
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [documents stringByAppendingPathComponent:@"AppGroupSacrifice.plist"];
    NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:path];
    NSString *current = [existing[@"GroupId"] isKindOfClass:NSString.class]
        ? existing[@"GroupId"] : @"";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"App Group Sacrifice"
        message:@"iOS 26 App Group access requires a group that your signing identity owns. Enter the group id and make sure it is in your entitlements."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = current;
        field.placeholder = @"group.your.own.group";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            NSString *groupId = alert.textFields.firstObject.text;
            groupId = [groupId stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!groupId.length) {
                [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            } else {
                [@{@"GroupId": groupId} writeToFile:path atomically:YES];
            }
            [weakSelf reloadReport];
            [weakSelf flash:@"Saved. Re-run the probe (and the container enumeration) to use the group route."];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)presentResults
{
    if (!self.report) {
        [self flash:@"No results yet"];
        return;
    }
    NSError *error = nil;
    NSData *xml = [NSPropertyListSerialization dataWithPropertyList:self.report
        format:NSPropertyListXMLFormat_v1_0 options:0 error:&error];
    NSString *text = xml ? [[NSString alloc] initWithData:xml encoding:NSUTF8StringEncoding]
        : (error.localizedDescription ?: @"Serialization failed");
    [self presentText:@"Probe Results" body:text];
}

- (void)presentProbeDetail:(NSDictionary *)probe
{
    NSMutableString *text = [NSMutableString string];
    for (NSString *key in @[@"Name", @"Path", @"Status", @"Stage", @"Error", @"Class",
                            @"GroupIdentifier", @"Traversal", @"Flags", @"Handle",
                            @"Readable", @"Openable", @"StatOk", @"IsDirectory", @"ChildCount"]) {
        id value = probe[key];
        if (value) [text appendFormat:@"%@: %@\n", key, value];
    }
    [self presentText:probe[@"Name"] ?: @"Probe" body:text];
}

#pragma mark - Helpers

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
    [viewer.view addSubview:textView];
    [self.navigationController pushViewController:viewer animated:YES];
}

- (void)flash:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.5 * NSEC_PER_SEC),
            dispatch_get_main_queue(), ^{
                [alert dismissViewControllerAnimated:YES completion:nil];
            });
    }];
}

@end
