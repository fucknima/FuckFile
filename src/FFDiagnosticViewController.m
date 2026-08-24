#import "FFDiagnosticViewController.h"

#import "FFIPSParser.h"
#import "FFRHWNDecoder.h"
#import "FFContentProbe.h"
#import "FFPreviewRouter.h"
#import "FFViewerRegistry.h"
#import "FFLogger.h"
#import "FFBrowserViewController.h" // FFEntry

@interface FFDiagnosticViewController ()

@property(nonatomic, copy) NSString *filePath;
@property(nonatomic) FFIPSParseResult *parseResult;
@property(nonatomic) BOOL loading;
@property(nonatomic) BOOL parseFailed;

@end

@implementation FFDiagnosticViewController

- (instancetype)initWithFilePath:(NSString *)path
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = path.lastPathComponent;
        _filePath = [path copy];
        _loading = YES;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"Cell"];
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"Value"];
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"Action"];
    [self startParse];
}

#pragma mark - Parse (background)

- (void)startParse
{
    NSString *path = self.filePath;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        FFIPSParseResult *result = [FFIPSParser parseFile:path];
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.parseResult = result;
            weakSelf.loading = NO;
            weakSelf.parseFailed = result.status != FFIPSStatusOK;
            [weakSelf.tableView reloadData];
        });
    });
}

#pragma mark - Header accessors

- (NSDictionary *)header
{
    return self.parseResult.header ?: @{};
}

- (NSString *)headerString:(NSString *)key
{
    id value = self.header[key];
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSNumber.class]) return [value stringValue];
    return nil;
}

- (NSString *)customHeaderString:(NSString *)key
{
    id custom = self.header[@"custom_headers"];
    if (![custom isKindOfClass:NSDictionary.class]) return nil;
    id value = custom[key];
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSNumber.class]) return [value stringValue];
    return nil;
}

- (NSString *)compressionName:(FFIPSCompression)compression
{
    switch (compression) {
        case FFIPSCompressionZlib: return @"zlib";
        case FFIPSCompressionRawDeflate: return @"raw DEFLATE";
        case FFIPSCompressionNone: return @"无压缩";
        case FFIPSCompressionUnknown: return @"未知";
    }
}

+ (NSString *)byteCount:(unsigned long long)bytes
{
    return [NSByteCountFormatter stringFromByteCount:(long long)bytes
        countStyle:NSByteCountFormatterCountStyleFile];
}

#pragma mark - Rows

// section 0：概览（header 可确认元数据 + payload 信息）。
- (NSArray<NSArray<NSString *> *> *)overviewRows
{
    FFIPSParseResult *result = self.parseResult;
    NSMutableArray<NSArray<NSString *> *> *rows = [NSMutableArray array];
    NSString *sender = [self customHeaderString:@"sender"] ?: @"—";
    NSString *client = [self customHeaderString:@"clientName"] ?: @"—";
    NSString *type = [self customHeaderString:@"type"] ?: @"—";
    [rows addObject:@[@"{overview}", [NSString stringWithFormat:@"%@ · %@ · %@",
        sender, client, type]]];
    [rows addObject:@[@"Bug Type", [self headerString:@"bug_type"] ?: @"—"]];
    [rows addObject:@[@"系统", [self headerString:@"os_version"] ?: @"—"]];
    [rows addObject:@[@"报告类型", type]];
    [rows addObject:@[@"发送模块", sender]];
    [rows addObject:@[@"客户端", client]];
    if (result.hasPayload) {
        [rows addObject:@[@"声明压缩", [self compressionName:result.declaredCompression]]];
        [rows addObject:@[@"实际解码", [self compressionName:result.actualCompression]]];
        [rows addObject:@[@"格式", result.payloadFormat ?: @"—"]];
    }
    [rows addObject:@[@"状态", result.hasPayload ? @"成功" : @"无 payload"]];
    [rows addObject:@[@"文件大小",
        [self.class byteCount:result.payloadOffset + result.payloadLength]]];
    if (result.hasPayload) {
        [rows addObject:@[@"解压大小", [self.class byteCount:result.payloadDecodedSize]]];
    }
    return rows;
}

- (NSArray<NSArray<NSString *> *> *)payloadRows
{
    FFIPSParseResult *result = self.parseResult;
    BOOL isRHWN = result.payloadFormat &&
        [result.payloadFormat isEqualToString:@"RHWN"];
    if (isRHWN) {
        FFRHWNDecoder *decoder = [[FFRHWNDecoder alloc] initWithData:result.payload];
        return @[
            @[@"格式", @"RHWN"],
            @[@"Payload 大小", [self.class byteCount:result.payloadDecodedSize]],
            @[@"可读字符串", [NSString stringWithFormat:@"%lu 条",
                (unsigned long)decoder.printableStrings.count]],
        ];
    }
    return @[
        @[@"格式", result.payloadFormat ?: @"—"],
        @[@"解压大小", [self.class byteCount:result.payloadDecodedSize]],
        @[@"原始大小", [self.class byteCount:result.payloadLength]],
    ];
}

#pragma mark - Table source

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView
{
    if (self.loading || self.parseFailed) return 1;
    return 3;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (self.loading || self.parseFailed) return nil;
    if (section == 0) return @"系统诊断报告";
    if (section == 1) {
        if (self.parseResult.payloadFormat &&
            [self.parseResult.payloadFormat isEqualToString:@"RHWN"]) return @"RHWN";
        return @"Payload";
    }
    return @"操作";
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 1 && self.parseResult.payloadFormat &&
        [self.parseResult.payloadFormat isEqualToString:@"RHWN"]) {
        return @"该 Payload 使用 Apple 私有诊断格式，当前仅展示可以可靠识别的信息。";
    }
    return nil;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (self.loading || self.parseFailed) return 1;
    if (section == 0) return [self overviewRows].count;
    if (section == 1) return [self payloadRows].count;
    return 4;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (self.loading) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell"
                                                               forIndexPath:indexPath];
        UIListContentConfiguration *config = [cell defaultContentConfiguration];
        config.text = @"正在解析诊断文件…";
        config.textProperties.color = UIColor.secondaryLabelColor;
        cell.contentConfiguration = config;
        return cell;
    }

    if (self.parseFailed) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell"
                                                               forIndexPath:indexPath];
        UIListContentConfiguration *config = [cell defaultContentConfiguration];
        config.text = @"无法解析该文件";
        config.secondaryText = self.parseFailureLine;
        config.secondaryTextProperties.numberOfLines = 0;
        config.secondaryTextProperties.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        config.secondaryTextProperties.color = UIColor.secondaryLabelColor;
        config.textProperties.color = UIColor.systemRedColor;
        cell.contentConfiguration = config;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    if (indexPath.section == 0) {
        NSArray<NSString *> *pair = [self overviewRows][(NSUInteger)indexPath.row];
        if (pair.count == 2 && [pair[0] isEqualToString:@"{overview}"]) {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell"
                                                                   forIndexPath:indexPath];
            UIListContentConfiguration *config = [cell defaultContentConfiguration];
            config.text = [self customHeaderString:@"sender"] ?: self.title;
            config.textProperties.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
            config.secondaryText = pair[1];
            config.secondaryTextProperties.numberOfLines = 0;
            config.secondaryTextProperties.color = UIColor.secondaryLabelColor;
            config.secondaryTextProperties.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
            cell.contentConfiguration = config;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }
        return [self valueCell:tableView indexPath:indexPath label:pair[0] value:pair[1]];
    }

    if (indexPath.section == 1) {
        NSArray<NSString *> *pair = [self payloadRows][(NSUInteger)indexPath.row];
        return [self valueCell:tableView indexPath:indexPath label:pair[0] value:pair[1]];
    }

    NSArray<NSString *> *actions = @[@"原始 Header", @"查看解码 Payload",
        @"查看原文件 Hex", @"导出 Payload"];
    return [self actionCell:tableView indexPath:indexPath
                      title:actions[(NSUInteger)indexPath.row]];
}

- (UITableViewCell *)valueCell:(UITableView *)tableView
                     indexPath:(NSIndexPath *)indexPath
                         label:(NSString *)label
                         value:(NSString *)value
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Value"
                                                           forIndexPath:indexPath];
    UIListContentConfiguration *config = [cell defaultContentConfiguration];
    config.text = label;
    config.textProperties.color = UIColor.secondaryLabelColor;
    config.secondaryText = value;
    config.secondaryTextProperties.numberOfLines = 0;
    config.secondaryTextProperties.font =
        [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    cell.contentConfiguration = config;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (UITableViewCell *)actionCell:(UITableView *)tableView
                      indexPath:(NSIndexPath *)indexPath
                          title:(NSString *)title
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Action"
                                                           forIndexPath:indexPath];
    UIListContentConfiguration *config = [cell defaultContentConfiguration];
    config.text = title;
    config.textProperties.color = UIColor.systemBlueColor;
    cell.contentConfiguration = config;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (NSString *)parseFailureLine
{
    switch (self.parseResult.status) {
        case FFIPSStatusNotIPS:
            return @"文件不是 Apple 诊断格式（无 JSON Header）。";
        case FFIPSStatusDecompressFailed:
            return @"zlib 与 raw DEFLATE 均无法解压（数据可能损坏）。";
        case FFIPSStatusDecompressBomb:
            return @"解压超过安全上限（64 MB / 比率 256:1），已中止。";
        case FFIPSStatusUnsupported:
            return @"该诊断文件当前无法处理。";
        case FFIPSStatusOK:
            return @"";
    }
}

#pragma mark - Actions

- (void)tableView:(__unused UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.loading || self.parseFailed) return;
    if (indexPath.section != 2) return;
    switch (indexPath.row) {
        case 0: [self showHeader]; break;
        case 1: [self showPayload]; break;
        case 2: [self showOriginalHex]; break;
        default: [self exportPayload]; break;
    }
}

- (void)showHeader
{
    NSString *body = self.prettyHeaderJSON;
    if (body.length > 1024 * 1024)
        body = [body substringToIndex:1024 * 1024];
    [FFPreviewRouter presentText:
        [NSString stringWithFormat:@"原始 Header · %@", self.title]
        body:body navigationController:self.navigationController];
}

- (NSString *)prettyHeaderJSON
{
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.parseResult.header
        options:NSJSONWritingPrettyPrinted error:&error];
    if (data) {
        NSString *pretty = [[NSString alloc] initWithData:data
                                                 encoding:NSUTF8StringEncoding];
        if (pretty) return pretty;
    }
    NSString *raw = [[NSString alloc] initWithData:self.parseResult.headerData
                                          encoding:NSUTF8StringEncoding];
    return raw ?: @"（Header 无法显示）";
}

- (NSString *)extensionForPayloadFormat:(NSString *)format
{
    if ([format isEqualToString:@"json"]) return @"json";
    if ([format isEqualToString:@"xml"]) return @"xml";
    if ([format isEqualToString:@"text"]) return @"txt";
    if ([format isEqualToString:@"bplist"]) return @"plist";
    if ([format isEqualToString:@"RHWN"]) return @"rhwn";
    return @"bin";
}

- (NSString *)viewerIDForPayloadFormat:(NSString *)format
{
    if ([format isEqualToString:@"json"] ||
        [format isEqualToString:@"xml"] ||
        [format isEqualToString:@"text"]) return @"text";
    if ([format isEqualToString:@"bplist"]) return @"plist";
    return @"hex";
}

- (void)showPayload
{
    FFIPSParseResult *result = self.parseResult;
    if (!result.hasPayload) {
        [self flash:@"该文件没有 payload"];
        return;
    }
    if (result.payload.length == 0) {
        [self flash:@"Payload 无法解码，可使用「查看原文件 Hex」"];
        return;
    }
    NSString *extension = [self extensionForPayloadFormat:result.payloadFormat];
    NSString *folder = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory,
        NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"IPS Payload"];
    [[NSFileManager defaultManager] createDirectoryAtPath:folder
        withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *name = [NSString stringWithFormat:
        @"payload-%.0f", [NSDate date].timeIntervalSince1970 * 1000];
    NSString *tempPath = [folder stringByAppendingPathComponent:
        [name stringByAppendingPathExtension:extension]];
    NSData *content = result.payload;
    if ([result.payloadFormat isEqualToString:@"json"]) {
        id json = [NSJSONSerialization JSONObjectWithData:content options:0 error:nil];
        NSData *pretty = [NSJSONSerialization dataWithJSONObject:json
            options:NSJSONWritingPrettyPrinted error:nil];
        if (pretty) content = pretty;
    }
    if (![content writeToFile:tempPath atomically:YES]) {
        [self flash:@"写入临时 payload 失败"];
        return;
    }
    FFEntry *item = [FFEntry new];
    item.name = tempPath.lastPathComponent;
    item.path = tempPath;
    NSString *viewerID = [self viewerIDForPayloadFormat:result.payloadFormat];
    if (![FFPreviewRouter openItem:item viewerID:viewerID
            navigationController:self.navigationController]) {
        [FFPreviewRouter toastOnNav:self.navigationController
            message:@"Payload 无法预览"];
    }
}

- (void)showOriginalHex
{
    FFEntry *item = [FFEntry new];
    item.name = self.title;
    item.path = self.filePath;
    [FFPreviewRouter openItem:item viewerID:@"hex"
        navigationController:self.navigationController];
}

- (void)exportPayload
{
    FFIPSParseResult *result = self.parseResult;
    if (result.payload.length == 0) {
        [self flash:@"没有可导出的 payload"];
        return;
    }
    NSString *extension = [self extensionForPayloadFormat:result.payloadFormat];
    NSString *folder = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
        NSUserDomainMask, YES).firstObject
        stringByAppendingPathComponent:@"Exported Diagnostics"];
    [[NSFileManager defaultManager] createDirectoryAtPath:folder
        withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *base = self.title.stringByDeletingPathExtension;
    NSString *target = [folder stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%@.payload.%@", base, extension]];
    NSInteger i = 2;
    while ([[NSFileManager defaultManager] fileExistsAtPath:target]) {
        target = [folder stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@ %ld.payload.%@", base, (long)i++, extension]];
    }
    if (![result.payload writeToFile:target atomically:YES]) {
        [self flash:@"导出失败（无写入权限）"];
        return;
    }
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:@[[NSURL fileURLWithPath:target]] applicationActivities:nil];
    activity.popoverPresentationController.sourceView = self.view;
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)flash:(NSString *)message
{
    [FFPreviewRouter toastOnNav:self.navigationController message:message];
}

@end
