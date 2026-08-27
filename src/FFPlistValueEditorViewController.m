#import "FFPlistValueEditorViewController.h"

#import <CoreFoundation/CoreFoundation.h>
#import <math.h>

static BOOL FFPlistIsBoolean(id value)
{
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL FFPlistNumberIsReal(NSNumber *value)
{
    const char *type = value.objCType;
    return strcmp(type, @encode(float)) == 0 ||
           strcmp(type, @encode(double)) == 0;
}

@interface FFPlistValueEditorViewController () <UITextViewDelegate, UITextFieldDelegate>
@property(nonatomic, strong) id originalValue;
@property(nonatomic, copy) FFPlistValueCommitHandler commitHandler;
@property(nonatomic, strong) UIScrollView *scrollView;
@property(nonatomic, strong) UIStackView *stack;
@property(nonatomic, strong) UITextView *textView;
@property(nonatomic, strong) UITextField *numberField;
@property(nonatomic, strong) UISwitch *booleanSwitch;
@property(nonatomic, strong) UIDatePicker *datePicker;
@property(nonatomic, strong) UISegmentedControl *dataMode;
@property(nonatomic, strong) UILabel *hintLabel;
@property(nonatomic, strong) NSData *workingData;
@property(nonatomic) NSInteger previousDataMode;
@end

@implementation FFPlistValueEditorViewController

- (instancetype)initWithValue:(id)value
                         title:(NSString *)title
                 commitHandler:(FFPlistValueCommitHandler)commitHandler
{
    self = [super init];
    if (self) {
        _originalValue = value;
        _commitHandler = [commitHandler copy];
        self.title = title.length ? title : @"编辑值";
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    UIBarButtonItem *save = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemSave
        target:self action:@selector(commit)];
    self.navigationItem.rightBarButtonItem = save;

    self.scrollView = [UIScrollView new];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:self.scrollView];

    UIView *content = [UIView new];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:content];

    self.stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    self.stack.axis = UILayoutConstraintAxisVertical;
    self.stack.spacing = 12;
    [content addSubview:self.stack];

    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [content.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor],
        [content.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor],
        [content.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor],
        [content.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor],
        [self.stack.topAnchor constraintEqualToAnchor:content.topAnchor constant:20],
        [self.stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
        [self.stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
        [self.stack.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor constant:-20],
    ]];

    [self configureForValue:self.originalValue];
}

- (UILabel *)sectionLabel:(NSString *)text
{
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    label.textColor = UIColor.secondaryLabelColor;
    label.numberOfLines = 0;
    return label;
}

- (void)configureForValue:(id)value
{
    if (FFPlistIsBoolean(value)) {
        [self configureBoolean:[value boolValue]];
        return;
    }
    if ([value isKindOfClass:NSNumber.class]) {
        [self configureNumber:value];
        return;
    }
    if ([value isKindOfClass:NSDate.class]) {
        [self configureDate:value];
        return;
    }
    if ([value isKindOfClass:NSData.class]) {
        [self configureData:value];
        return;
    }
    [self configureString:[value isKindOfClass:NSString.class] ? value : [value description]];
}

- (void)configureBoolean:(BOOL)value
{
    UIView *card = [self cardView];
    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = @"布尔值";
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    [card addSubview:label];

    self.booleanSwitch = [UISwitch new];
    self.booleanSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    self.booleanSwitch.on = value;
    [card addSubview:self.booleanSwitch];

    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [label.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [self.booleanSwitch.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [self.booleanSwitch.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:self.booleanSwitch.leadingAnchor constant:-12],
        [card.heightAnchor constraintGreaterThanOrEqualToConstant:58],
    ]];
    [self.stack addArrangedSubview:card];
    [self.stack addArrangedSubview:[self sectionLabel:@"保存后仍保持 Property List 的 Boolean 类型。"]];
}

- (void)configureNumber:(NSNumber *)value
{
    BOOL real = FFPlistNumberIsReal(value);
    [self.stack addArrangedSubview:[self sectionLabel:real ? @"实数（Real）" : @"整数（Integer）"]];

    self.numberField = [UITextField new];
    self.numberField.translatesAutoresizingMaskIntoConstraints = NO;
    self.numberField.borderStyle = UITextBorderStyleRoundedRect;
    self.numberField.font = [UIFont monospacedSystemFontOfSize:17 weight:UIFontWeightRegular];
    self.numberField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.numberField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    self.numberField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.numberField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.numberField.text = real ? [NSString stringWithFormat:@"%.17g", value.doubleValue]
                                 : [NSString stringWithFormat:@"%lld", value.longLongValue];
    [self.numberField.heightAnchor constraintEqualToConstant:50].active = YES;
    [self.stack addArrangedSubview:self.numberField];
    [self.stack addArrangedSubview:[self sectionLabel:
        real ? @"只接受完整的十进制实数；非法输入不会被替换成 0。"
             : @"只接受完整的十进制整数；非法输入不会被替换成 0。"]];
}

- (UITextView *)configuredTextView
{
    UITextView *view = [UITextView new];
    view.translatesAutoresizingMaskIntoConstraints = NO;
    view.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
    view.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    view.textContainerInset = UIEdgeInsetsMake(12, 10, 12, 10);
    view.layer.cornerRadius = 12;
    view.layer.masksToBounds = YES;
    view.autocorrectionType = UITextAutocorrectionTypeNo;
    view.autocapitalizationType = UITextAutocapitalizationTypeNone;
    view.smartQuotesType = UITextSmartQuotesTypeNo;
    view.smartDashesType = UITextSmartDashesTypeNo;
    [view.heightAnchor constraintGreaterThanOrEqualToConstant:220].active = YES;
    return view;
}

- (void)configureString:(NSString *)value
{
    [self.stack addArrangedSubview:[self sectionLabel:@"字符串（String）"]];
    self.textView = [self configuredTextView];
    self.textView.text = value ?: @"";
    [self.stack addArrangedSubview:self.textView];
}

- (void)configureDate:(NSDate *)value
{
    [self.stack addArrangedSubview:[self sectionLabel:@"日期（Date）"]];
    self.datePicker = [UIDatePicker new];
    self.datePicker.translatesAutoresizingMaskIntoConstraints = NO;
    self.datePicker.datePickerMode = UIDatePickerModeDateAndTime;
    self.datePicker.preferredDatePickerStyle = UIDatePickerStyleInline;
    self.datePicker.date = value ?: NSDate.date;
    [self.stack addArrangedSubview:self.datePicker];
    [self.stack addArrangedSubview:[self sectionLabel:@"以 NSDate 保存，不会在编辑后退化成 String。"]];
}

- (void)configureData:(NSData *)value
{
    self.workingData = value ?: NSData.data;
    self.previousDataMode = 0;

    [self.stack addArrangedSubview:[self sectionLabel:
        [NSString stringWithFormat:@"数据（Data） · %lu 字节", (unsigned long)self.workingData.length]]];

    self.dataMode = [[UISegmentedControl alloc] initWithItems:@[@"HEX", @"Base64"]];
    self.dataMode.selectedSegmentIndex = 0;
    [self.dataMode addTarget:self action:@selector(dataModeChanged:)
        forControlEvents:UIControlEventValueChanged];
    [self.stack addArrangedSubview:self.dataMode];

    self.textView = [self configuredTextView];
    self.textView.text = [self hexStringForData:self.workingData];
    [self.stack addArrangedSubview:self.textView];

    self.hintLabel = [self sectionLabel:@"HEX 可包含空格和换行；必须由完整的两位十六进制字节组成。"];
    [self.stack addArrangedSubview:self.hintLabel];
}

- (UIView *)cardView
{
    UIView *view = [UIView new];
    view.translatesAutoresizingMaskIntoConstraints = NO;
    view.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    view.layer.cornerRadius = 12;
    view.layer.masksToBounds = YES;
    return view;
}

- (NSString *)hexStringForData:(NSData *)data
{
    if (data.length == 0) return @"";
    const uint8_t *bytes = data.bytes;
    NSMutableString *result = [NSMutableString stringWithCapacity:data.length * 3];
    for (NSUInteger i = 0; i < data.length; i++) {
        if (i > 0) [result appendString:(i % 16 == 0) ? @"\n" : @" "];
        [result appendFormat:@"%02X", bytes[i]];
    }
    return result;
}

- (NSData *)dataFromText:(NSString *)text mode:(NSInteger)mode error:(NSString **)error
{
    NSString *source = text ?: @"";
    if (mode == 1) {
        NSArray *parts = [source componentsSeparatedByCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *compact = [parts componentsJoinedByString:@""];
        if (compact.length == 0) return NSData.data;
        NSData *data = [[NSData alloc] initWithBase64EncodedString:compact options:0];
        if (!data && error) *error = @"Base64 内容无效。";
        return data;
    }

    NSCharacterSet *whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSMutableString *compact = [NSMutableString string];
    for (NSUInteger i = 0; i < source.length; i++) {
        unichar c = [source characterAtIndex:i];
        if ([whitespace characterIsMember:c] || c == '<' || c == '>') continue;
        [compact appendFormat:@"%C", c];
    }
    if (compact.length == 0) return NSData.data;
    if (compact.length % 2 != 0) {
        if (error) *error = @"HEX 字符数必须为偶数。";
        return nil;
    }

    NSMutableData *data = [NSMutableData dataWithCapacity:compact.length / 2];
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    for (NSUInteger i = 0; i < compact.length; i += 2) {
        NSString *pair = [compact substringWithRange:NSMakeRange(i, 2)];
        if ([pair rangeOfCharacterFromSet:hex.invertedSet].location != NSNotFound) {
            if (error) *error = [NSString stringWithFormat:@"“%@” 不是有效的 HEX 字节。", pair];
            return nil;
        }
        unsigned int byte = 0;
        NSScanner *scanner = [NSScanner scannerWithString:pair];
        if (![scanner scanHexInt:&byte] || !scanner.isAtEnd) {
            if (error) *error = @"HEX 内容无效。";
            return nil;
        }
        uint8_t value = (uint8_t)byte;
        [data appendBytes:&value length:1];
    }
    return data;
}

- (void)dataModeChanged:(UISegmentedControl *)sender
{
    NSString *message = nil;
    NSData *parsed = [self dataFromText:self.textView.text
        mode:self.previousDataMode error:&message];
    if (!parsed) {
        sender.selectedSegmentIndex = self.previousDataMode;
        [self showError:message ?: @"数据格式无效"];
        return;
    }

    self.workingData = parsed;
    self.previousDataMode = sender.selectedSegmentIndex;
    if (sender.selectedSegmentIndex == 0) {
        self.textView.text = [self hexStringForData:parsed];
        self.hintLabel.text = @"HEX 可包含空格和换行；必须由完整的两位十六进制字节组成。";
    } else {
        self.textView.text = [parsed base64EncodedStringWithOptions:0] ?: @"";
        self.hintLabel.text = @"Base64 必须完整有效；空白字符会被忽略。";
    }
}

- (NSNumber *)parsedNumberWithError:(NSString **)error
{
    NSString *text = [self.numberField.text stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (text.length == 0) {
        if (error) *error = @"数值不能为空。";
        return nil;
    }

    if (FFPlistNumberIsReal(self.originalValue)) {
        NSScanner *scanner = [NSScanner scannerWithString:text];
        double value = 0;
        if (![scanner scanDouble:&value] || !scanner.isAtEnd || !isfinite(value)) {
            if (error) *error = @"请输入完整、有限的十进制实数。";
            return nil;
        }
        return @(value);
    }

    NSScanner *scanner = [NSScanner scannerWithString:text];
    long long value = 0;
    if (![scanner scanLongLong:&value] || !scanner.isAtEnd) {
        if (error) *error = @"请输入完整的十进制整数。";
        return nil;
    }
    return @(value);
}

- (void)commit
{
    id value = nil;
    NSString *error = nil;

    if (FFPlistIsBoolean(self.originalValue)) {
        value = @(self.booleanSwitch.isOn);
    } else if ([self.originalValue isKindOfClass:NSNumber.class]) {
        value = [self parsedNumberWithError:&error];
    } else if ([self.originalValue isKindOfClass:NSDate.class]) {
        value = self.datePicker.date;
    } else if ([self.originalValue isKindOfClass:NSData.class]) {
        value = [self dataFromText:self.textView.text
            mode:self.dataMode.selectedSegmentIndex error:&error];
    } else {
        value = self.textView.text ?: @"";
    }

    if (!value) {
        [self showError:error ?: @"无法解析当前输入"];
        return;
    }

    if (self.commitHandler) self.commitHandler(value);
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)showError:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法保存"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好"
        style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
