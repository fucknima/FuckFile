#import "FFTextEditorViewController.h"
#import "FFLogger.h"
#import "FFPathPolicy.h"
#import "FFTextCodec.h"
#import "FFPreviewRouter.h"
#import "FFBrowserViewController.h"
#import "FFFileInfoViewController.h"
#import "FuckFile-Swift.h"

// 大文件策略（见 docs/ARCHITECTURE.md「文本编辑器」）：
//   ≤ FFEditorHighlightLimitBytes：完整编辑 + 语法高亮（tree-sitter 全文件解析）
//   ≤ FFEditorEditableLimitBytes：完整编辑，禁用高亮（轻量文本模式）
//   > FFEditorEditableLimitBytes：只读，仅显示前 FFEditorPreviewBytes（分段只读预览）
static const unsigned long long FFEditorHighlightLimitBytes = 2 * 1024 * 1024;
static const unsigned long long FFEditorEditableLimitBytes = 8 * 1024 * 1024;
static const unsigned long long FFEditorPreviewBytes = 1024 * 1024;

// 键盘 accessory 按钮语义。
typedef NS_ENUM(NSInteger, FFEditorAccessoryAction) {
    FFEditorAccessoryActionTab = 0,
    FFEditorAccessoryActionIndentOut,
    FFEditorAccessoryActionIndentIn,
    FFEditorAccessoryActionBrace,
    FFEditorAccessoryActionParen,
    FFEditorAccessoryActionQuote,
    FFEditorAccessoryActionUndo,
    FFEditorAccessoryActionRedo,
    FFEditorAccessoryActionFind,
};

@class FFTextEditorViewController;

// 键盘 accessory：紧凑原生风格（Tab｜缩进｜{} () ""｜撤销 重做）。
@interface FFEditorAccessoryBar : UIView
@property(nonatomic, weak) FFTextEditorViewController *controller;
@end

@interface FFTextEditorViewController () <UITextFieldDelegate>
- (void)accessoryAction:(FFEditorAccessoryAction)action;
@property(nonatomic, copy) NSString *filePath;
@property(nonatomic, strong) FFCodeEditorView *editorView;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic) BOOL changed;
@property(nonatomic) BOOL loaded;
@property(nonatomic) BOOL readOnlyMode;       // >8MB 只读
@property(nonatomic) BOOL lightHighlightMode; // 2-8MB 禁高亮

@property(nonatomic) FFTextEncoding encoding;
@property(nonatomic) BOOL hasBOM;
@property(nonatomic) FFLineEnding lineEnding;
@property(nonatomic) BOOL encodingOverride;
@property(nonatomic) BOOL lineEndingOverride;

@property(nonatomic) BOOL wrapEnabled;
@property(nonatomic) BOOL invisibleEnabled;
@property(nonatomic) BOOL indentUsesTabs;
@property(nonatomic) NSInteger indentWidth;

@property(nonatomic, strong) FFEditorAccessoryBar *accessoryBar;
@property(nonatomic, strong) UIView *findBar;
@property(nonatomic, strong) UISearchTextField *findField;
@property(nonatomic, strong) UITextField *replaceField;
@property(nonatomic, strong) UIButton *findCaseButton;
@property(nonatomic, strong) UIButton *findRegexButton;
@property(nonatomic) BOOL caseSensitive;
@property(nonatomic) BOOL regexEnabled;
@property(nonatomic, strong) NSArray<NSValue *> *matchRanges;
@property(nonatomic) NSInteger currentMatchIndex;
@end

@implementation FFEditorAccessoryBar

- (instancetype)initWithController:(FFTextEditorViewController *)controller
{
    self = [super initWithFrame:CGRectMake(0, 0, 0, 44)];
    if (self) {
        _controller = controller;
        self.backgroundColor = [UIColor clearColor];
        UIVisualEffectView *blur = [[UIVisualEffectView alloc]
            initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
        blur.frame = self.bounds;
        blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:blur];

        NSArray<NSArray *> *specs = @[
            @[@(FFEditorAccessoryActionTab), @"keyboard.tabkey", @"", @"Tab"],
            @[@(FFEditorAccessoryActionIndentOut), @"decrease.indent", @"", @"减少缩进"],
            @[@(FFEditorAccessoryActionIndentIn), @"increase.indent", @"", @"增加缩进"],
            @[@(FFEditorAccessoryActionBrace), NSNull.null, @"{}", @"花括号"],
            @[@(FFEditorAccessoryActionParen), NSNull.null, @"()", @"圆括号"],
            @[@(FFEditorAccessoryActionQuote), NSNull.null, @"\"\"", @"引号"],
            @[@(FFEditorAccessoryActionUndo), @"arrow.uturn.backward", @"", @"撤销"],
            @[@(FFEditorAccessoryActionRedo), @"arrow.uturn.forward", @"", @"重做"],
            @[@(FFEditorAccessoryActionFind), @"magnifyingglass", @"", @"查找"],
        ];
        NSMutableArray<UIView *> *buttons = [NSMutableArray array];
        for (NSArray *spec in specs) {
            FFEditorAccessoryAction action = (FFEditorAccessoryAction)[spec[0] integerValue];
            NSString *symbol = spec[1];
            NSString *title = spec[2];
            UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
            symbol = [symbol isKindOfClass:NSNull.class] ? nil : symbol;
            if (symbol.length) {
                [button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
                if (button.imageView.image == nil) {
                    // SDK 无该符号（低系统）：降级为文字 glyph。
                    NSString *fallback = nil;
                    switch (action) {
                        case FFEditorAccessoryActionTab: fallback = @"⇥"; break;
                        case FFEditorAccessoryActionIndentOut: fallback = @"◀"; break;
                        case FFEditorAccessoryActionIndentIn: fallback = @"▶"; break;
                        case FFEditorAccessoryActionUndo: fallback = @"↩︎"; break;
                        case FFEditorAccessoryActionRedo: fallback = @"↪︎"; break;
                        case FFEditorAccessoryActionFind: fallback = @"🔍"; break;
                        default: break;
                    }
                    if (fallback) {
                        [button setTitle:fallback forState:UIControlStateNormal];
                        button.titleLabel.font =
                            [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
                    }
                }
            } else {
                [button setTitle:title forState:UIControlStateNormal];
                button.titleLabel.font =
                    [UIFont monospacedSystemFontOfSize:17 weight:UIFontWeightRegular];
            }
            button.accessibilityLabel = spec[3];
            button.tag = action;
            button.tintColor = UIColor.labelColor;
            [button addTarget:self action:@selector(buttonTapped:)
                forControlEvents:UIControlEventTouchUpInside];
            [buttons addObject:button];
        }
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:buttons];
        stack.axis = UILayoutConstraintAxisHorizontal;
        stack.distribution = UIStackViewDistributionFillEqually;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.topAnchor constraintEqualToAnchor:self.topAnchor],
            [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        ]];
    }
    return self;
}

- (void)buttonTapped:(UIButton *)button
{
    [self.controller accessoryAction:(FFEditorAccessoryAction)button.tag];
}

@end

@implementation FFTextEditorViewController

- (instancetype)initWithPath:(NSString *)path
{
    self = [super init];
    if (self) {
        _filePath = [path copy];
        self.title = path.lastPathComponent;
        _encoding = FFTextEncodingUTF8;
        _lineEnding = FFLineEndingLF;
        _wrapEnabled = YES;
        _invisibleEnabled = NO;
        _indentUsesTabs = NO;
        _indentWidth = 4;
        _currentMatchIndex = -1;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.editorView = [[FFCodeEditorView alloc] initWithFrame:CGRectZero];
    self.editorView.translatesAutoresizingMaskIntoConstraints = NO;
    __weak typeof(self) weakEditor = self;
    self.editorView.onTextChanged = ^{
        __strong typeof(weakEditor) strongEditor = weakEditor;
        [strongEditor codeEditorDidChangeText];
    };
    [self.view addSubview:self.editorView];
    [NSLayoutConstraint activateConstraints:@[
        [self.editorView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.editorView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.editorView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.editorView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
    ]];

    self.spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.spinner];
    [NSLayoutConstraint activateConstraints:@[
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];
    [self.spinner startAnimating];

    self.accessoryBar = [[FFEditorAccessoryBar alloc] initWithController:self];
    [self configureFindBar];
    self.editorView.editorInputAccessoryView = self.accessoryBar;
    UIBarButtonItem *save = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:
        UIBarButtonSystemItemSave target:self action:@selector(save)];
    save.enabled = NO;
    UIBarButtonItem *menu = [[UIBarButtonItem alloc] initWithTitle:@"⋯"
        style:UIBarButtonItemStylePlain target:nil action:nil];
    menu.menu = [self buildMoreMenu];
    self.navigationItem.rightBarButtonItems = @[save, menu];

    UIBarButtonItem *back = [[UIBarButtonItem alloc] initWithTitle:@"返回"
        style:UIBarButtonItemStylePlain target:self action:@selector(backTapped)];
    self.navigationItem.leftBarButtonItem = back;
    self.navigationController.interactivePopGestureRecognizer.delegate =
        (id<UIGestureRecognizerDelegate>)self;

    [self loadFile];
}

#pragma mark - Loading

- (void)loadFile
{
    NSString *path = self.filePath;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        unsigned long long fileSize = 0;
        NSDictionary *attrs = [NSFileManager.defaultManager
            attributesOfItemAtPath:path error:nil];
        fileSize = [attrs[NSFileSize] unsignedLongLongValue];

        BOOL tooBig = fileSize > FFEditorEditableLimitBytes;
        BOOL light = !tooBig && fileSize > FFEditorHighlightLimitBytes;

        NSData *data = nil;
        NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
        if (handle) {
            data = tooBig ? [handle readDataOfLength:FFEditorPreviewBytes]
                          : [handle readDataToEndOfFile];
            [handle closeFile];
        }

        FFTextEncoding encoding = FFTextEncodingUTF8;
        BOOL bom = NO;
        FFLineEnding lineEnding = FFLineEndingLF;
        NSString *text = data ? [FFTextCodec decodeData:data encoding:&encoding
                                                    bom:&bom lineEnding:&lineEnding] : nil;
        if (tooBig && text) {
            text = [text stringByAppendingFormat:
                @"\n\n… 文件较大（%@），已超过编辑上限 %@，仅显示前 %@ 只读预览。",
                [NSByteCountFormatter stringFromByteCount:(long long)fileSize
                    countStyle:NSByteCountFormatterCountStyleFile],
                [NSByteCountFormatter stringFromByteCount:FFEditorEditableLimitBytes
                    countStyle:NSByteCountFormatterCountStyleFile],
                [NSByteCountFormatter stringFromByteCount:FFEditorPreviewBytes
                    countStyle:NSByteCountFormatterCountStyleFile]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!weakSelf) return;
            [weakSelf applyLoadedText:text encoding:encoding bom:bom
                lineEnding:lineEnding tooBig:tooBig light:light];
        });
    });
}

- (void)applyLoadedText:(NSString *)text encoding:(FFTextEncoding)encoding
                    bom:(BOOL)bom lineEnding:(FFLineEnding)lineEnding
                 tooBig:(BOOL)tooBig light:(BOOL)light
{
    [self.spinner stopAnimating];
    self.loaded = YES;
    self.readOnlyMode = tooBig;
    self.lightHighlightMode = light;
    self.encoding = encoding;
    self.hasBOM = bom;
    self.lineEnding = lineEnding;

    if (text == nil) {
        self.editorView.text = @"（该文件不是有效文本或无法按支持的编码解码。）";
        self.editorView.editorIsEditable = NO;
        return;
    }

    self.editorView.text = text;
    self.editorView.editorIsEditable = !tooBig;
    self.editorView.lineWrappingEnabled = self.wrapEnabled;
    self.editorView.invisibleCharactersVisible = self.invisibleEnabled;
    [self.editorView setIndentUsesTabs:self.indentUsesTabs width:(int)self.indentWidth];
    [self.editorView setLineEndingStyle:[self lineEndingStyleValue:self.lineEnding]];

    if (light || tooBig) {
        // 轻量文本模式 / 只读预览：不开启 tree-sitter 语言。
        [self.editorView setLanguageEnabled:NO];
    } else {
        [self.editorView setLanguageForExtension:self.filePath.pathExtension];
    }
}

- (NSInteger)lineEndingStyleValue:(FFLineEnding)lineEnding
{
    switch (lineEnding) {
        case FFLineEndingCRLF: return 1;
        case FFLineEndingCR: return 2;
        default: return 0;
    }
}

#pragma mark - Change tracking

- (void)setSaveEnabled:(BOOL)enabled
{
    for (UIBarButtonItem *item in self.navigationItem.rightBarButtonItems) {
        if (item.action == @selector(save)) item.enabled = enabled;
    }
}

- (void)codeEditorDidChangeText
{
    if (self.loaded && !self.readOnlyMode) {
        self.changed = YES;
        [self setSaveEnabled:YES];
    }
}



#pragma mark - Back / unsaved

- (void)backTapped
{
    if (!self.changed) {
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"未保存的修改"
        message:@"是否保存对此文件的修改？"
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            [weakSelf save];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.3 * NSEC_PER_SEC),
                dispatch_get_main_queue(), ^{
                    if (!weakSelf.changed)
                        [weakSelf.navigationController popViewControllerAnimated:YES];
                });
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"放弃" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            [weakSelf.navigationController popViewControllerAnimated:YES];
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer
{
    if (self.changed && gestureRecognizer ==
        self.navigationController.interactivePopGestureRecognizer) {
        [self backTapped];
        return NO;
    }
    return YES;
}

#pragma mark - Save

- (void)save
{
    NSString *text = self.editorView.text ?: @"";
    FFTextEncoding encoding = self.encoding;
    BOOL bom = self.hasBOM;
    if (self.encodingOverride) {
        // 用户主动切换编码：UTF-8 无 BOM；UTF-16 默认带 BOM（可再选菜单开关编码）。
        bom = (encoding == FFTextEncodingUTF16LE ||
               encoding == FFTextEncodingUTF16BE ||
               encoding == FFTextEncodingUTF8BOM);
    }
    FFLineEnding lineEnding = self.lineEnding;
    NSData *data = [FFTextCodec encodeString:text encoding:encoding
                                         bom:bom lineEnding:lineEnding];
    if (!data) {
        [self flash:@"无法用所选编码编码此内容（存在无法表示的字符）。"];
        return;
    }

    NSString *detail = nil;
    NSString *finalName = nil;
    NSString *parent = [FFPathPolicy resolveParentForMutation:self.filePath
        finalName:&finalName errorMessage:&detail];
    if (!parent) {
        FFLogTag(@"TextEditor", @"save REJECT path=%@ reason=%@",
            self.filePath, detail ?: @"路径不合法");
        [self flash:[NSString stringWithFormat:@"无法保存：%@", detail ?: @"路径不合法"]];
        return;
    }
    NSString *target = [parent stringByAppendingPathComponent:finalName];
    NSError *error = nil;
    if ([data writeToFile:target options:NSDataWritingAtomic error:&error]) {
        [self flash:@"已保存"];
        self.changed = NO;
        [self setSaveEnabled:NO];
        return;
    }
    FFLogTag(@"TextEditor", @"save FAIL path=%@ error=%@", self.filePath, error);
    [self offerCopyOnFailure:data];
}

- (void)offerCopyOnFailure:(NSData *)data
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法写入"
        message:@"该位置不可写（沙盒只读扩展）。\n保存副本到 FuckFile 文档？"
        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存副本" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            NSString *documents = NSSearchPathForDirectoriesInDomains(
                NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            NSString *folder = [documents stringByAppendingPathComponent:@"Edited Copies"];
            [[NSFileManager defaultManager] createDirectoryAtPath:folder
                withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *copyPath = [folder stringByAppendingPathComponent:
                weakSelf.filePath.lastPathComponent];
            NSError *error = nil;
            if ([data writeToFile:copyPath options:NSDataWritingAtomic error:&error]) {
                [weakSelf flash:[NSString stringWithFormat:@"已保存副本：\n%@", copyPath]];
            } else {
                [weakSelf flash:[NSString stringWithFormat:@"副本保存失败：%@",
                    error.localizedDescription]];
            }
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - More menu

- (UIMenu *)buildMoreMenu
{
    __weak typeof(self) weakSelf = self;

    NSArray<NSArray *> *encodings = @[
        @[@(FFTextEncodingUTF8), @"UTF-8"],
        @[@(FFTextEncodingUTF8BOM), @"UTF-8 (BOM)"],
        @[@(FFTextEncodingUTF16LE), @"UTF-16 LE"],
        @[@(FFTextEncodingUTF16BE), @"UTF-16 BE"],
        @[@(FFTextEncodingLatin1), @"Latin-1（强制）"],
    ];
    NSMutableArray<UIAction *> *encodingActions = [NSMutableArray array];
    for (NSArray *spec in encodings) {
        FFTextEncoding value = (FFTextEncoding)[spec[0] integerValue];
        UIAction *action = [UIAction actionWithTitle:spec[1]
            image:nil identifier:[NSString stringWithFormat:@"enc.%ld", (long)value]
            handler:^(__unused UIAction *action) {
                weakSelf.encodingOverride = YES;
                weakSelf.encoding = value;
                weakSelf.hasBOM = (value == FFTextEncodingUTF8BOM);
                weakSelf.changed = YES;
                [weakSelf setSaveEnabled:YES];
            }];
        action.state = (value == self.encoding) ? UIMenuElementStateOn : UIMenuElementStateOff;
        [encodingActions addObject:action];
    }

    NSArray<NSArray *> *lineEndings = @[
        @[@(FFLineEndingLF), @"LF (Unix)"],
        @[@(FFLineEndingCRLF), @"CRLF (Windows)"],
        @[@(FFLineEndingCR), @"CR (Mac)"],
    ];
    NSMutableArray<UIAction *> *lineEndingActions = [NSMutableArray array];
    for (NSArray *spec in lineEndings) {
        FFLineEnding value = (FFLineEnding)[spec[0] integerValue];
        UIAction *action = [UIAction actionWithTitle:spec[1]
            image:nil identifier:[NSString stringWithFormat:@"le.%ld", (long)value]
            handler:^(__unused UIAction *action) {
                weakSelf.lineEndingOverride = YES;
                weakSelf.lineEnding = value;
                [weakSelf.editorView setLineEndingStyle:[weakSelf lineEndingStyleValue:value]];
                weakSelf.changed = YES;
                [weakSelf setSaveEnabled:YES];
            }];
        action.state = (value == self.lineEnding) ? UIMenuElementStateOn : UIMenuElementStateOff;
        [lineEndingActions addObject:action];
    }

    UIAction *spacesAction = [UIAction actionWithTitle:@"空格（推荐）"
        image:nil identifier:@"indent.spaces" handler:^(__unused UIAction *a) {
            weakSelf.indentUsesTabs = NO;
            [weakSelf.editorView setIndentUsesTabs:NO width:(int)weakSelf.indentWidth];
        }];
    spacesAction.state = self.indentUsesTabs ? UIMenuElementStateOff : UIMenuElementStateOn;
    UIAction *tabsAction = [UIAction actionWithTitle:@"制表符"
        image:nil identifier:@"indent.tabs" handler:^(__unused UIAction *a) {
            weakSelf.indentUsesTabs = YES;
            [weakSelf.editorView setIndentUsesTabs:YES width:(int)weakSelf.indentWidth];
        }];
    tabsAction.state = self.indentUsesTabs ? UIMenuElementStateOn : UIMenuElementStateOff;
    NSMutableArray<UIAction *> *widthActions = [NSMutableArray array];
    for (NSNumber *width in @[@2, @4, @8]) {
        UIAction *action = [UIAction actionWithTitle:[width stringValue]
            image:nil identifier:[NSString stringWithFormat:@"indent.width.%@", width]
            handler:^(__unused UIAction *action) {
                weakSelf.indentWidth = width.integerValue;
                [weakSelf.editorView setIndentUsesTabs:weakSelf.indentUsesTabs
                                                 width:(int)weakSelf.indentWidth];
            }];
        action.state = (width.integerValue == self.indentWidth)
            ? UIMenuElementStateOn : UIMenuElementStateOff;
        [widthActions addObject:action];
    }

    UIAction *findAction = [UIAction actionWithTitle:@"查找与替换"
        image:[UIImage systemImageNamed:@"magnifyingglass"]
        identifier:@"find" handler:^(__unused UIAction *a) { [self showFindBar]; }];
    UIAction *gotoAction = [UIAction actionWithTitle:@"跳转到行"
        image:[UIImage systemImageNamed:@"arrow.down.to.line"]
        identifier:@"goto" handler:^(__unused UIAction *a) { [self promptGoToLine]; }];

    UIAction *wrapAction = [UIAction actionWithTitle:@"自动换行"
        image:nil identifier:@"wrap" handler:^(__unused UIAction *a) {
            weakSelf.wrapEnabled = !weakSelf.wrapEnabled;
            weakSelf.editorView.lineWrappingEnabled = weakSelf.wrapEnabled;
        }];
    wrapAction.state = self.wrapEnabled ? UIMenuElementStateOn : UIMenuElementStateOff;
    UIAction *invisibleAction = [UIAction actionWithTitle:@"显示不可见字符"
        image:nil identifier:@"invisible" handler:^(__unused UIAction *a) {
            weakSelf.invisibleEnabled = !weakSelf.invisibleEnabled;
            weakSelf.editorView.invisibleCharactersVisible = weakSelf.invisibleEnabled;
        }];
    invisibleAction.state = self.invisibleEnabled ? UIMenuElementStateOn : UIMenuElementStateOff;

    UIAction *infoAction = [UIAction actionWithTitle:@"文件信息"
        image:[UIImage systemImageNamed:@"info.circle"]
        identifier:@"info" handler:^(__unused UIAction *a) { [self showFileInfo]; }];

    UIMenu *encodingMenu = [UIMenu menuWithTitle:@"文本编码" children:encodingActions];
    UIMenu *lineEndingMenu = [UIMenu menuWithTitle:@"换行符" children:lineEndingActions];
    UIMenu *indentMenu = [UIMenu menuWithTitle:@"缩进设置" children:@[
        spacesAction, tabsAction,
        [UIMenu menuWithTitle:@"Tab / 空格宽度" children:widthActions],
    ]];

    return [UIMenu menuWithTitle:@"" children:@[
        findAction, gotoAction,
        [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline
                      children:@[wrapAction, invisibleAction]],
        [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline
                      children:@[indentMenu, encodingMenu, lineEndingMenu]],
        [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline
                      children:@[infoAction]],
    ]];
}

- (void)showFileInfo
{
    FFEntry *entry = [FFEntry new];
    entry.name = self.filePath.lastPathComponent;
    entry.path = self.filePath;
    NSDictionary *attrs = [NSFileManager.defaultManager
        attributesOfItemAtPath:self.filePath error:nil];
    entry.size = [attrs[NSFileSize] unsignedLongLongValue];
    entry.modificationDate = attrs[NSFileModificationDate];
    FFFileInfoViewController *info =
        [[FFFileInfoViewController alloc] initWithEntry:entry icon:nil];
    [self.navigationController pushViewController:info animated:YES];
}

#pragma mark - Go To Line

- (void)promptGoToLine
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"跳转到行"
        message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.keyboardType = UIKeyboardTypeNumberPad;
        field.placeholder = @"行号";
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"跳转"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            NSString *raw = alert.textFields.firstObject.text ?: @"";
            NSInteger line = raw.integerValue;
            if (line < 1) {
                [weakSelf flash:@"请输入有效行号"];
                return;
            }
            (void)[weakSelf.editorView goToLine:line];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Accessory actions

- (void)accessoryAction:(FFEditorAccessoryAction)action
{
    switch (action) {
        case FFEditorAccessoryActionTab:
            [self.editorView insertText:@"\t"];
            break;
        case FFEditorAccessoryActionIndentOut:
            [self.editorView indentOut];
            break;
        case FFEditorAccessoryActionIndentIn:
            [self.editorView indentIn];
            break;
        case FFEditorAccessoryActionBrace:
            [self.editorView insertText:@"{}"];
            break;
        case FFEditorAccessoryActionParen:
            [self.editorView insertText:@"()"];
            break;
        case FFEditorAccessoryActionQuote:
            [self.editorView insertText:@"\"\""];
            break;
        case FFEditorAccessoryActionUndo:
            [self.editorView undo];
            break;
        case FFEditorAccessoryActionRedo:
            [self.editorView redo];
            break;
        case FFEditorAccessoryActionFind:
            [self showFindBar];
            break;
    }
}

#pragma mark - Find / Replace bar

- (void)configureFindBar
{
    self.findBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 92)];
    UIVisualEffectView *blur = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    blur.frame = self.findBar.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.findBar addSubview:blur];

    UISearchTextField *search = [[UISearchTextField alloc] init];
    search.placeholder = @"查找";
    search.returnKeyType = UIReturnKeyNext;
    search.autocorrectionType = UITextAutocorrectionTypeNo;
    search.autocapitalizationType = UITextAutocapitalizationTypeNone;
    search.delegate = self;
    [search addTarget:self action:@selector(findTextChanged:)
        forControlEvents:UIControlEventEditingChanged];
    self.findField = search;

    UITextField *replaceField = [[UITextField alloc] init];
    replaceField.placeholder = @"替换为";
    replaceField.returnKeyType = UIReturnKeyDone;
    replaceField.autocorrectionType = UITextAutocorrectionTypeNo;
    replaceField.borderStyle = UITextBorderStyleRoundedRect;
    replaceField.delegate = self;
    self.replaceField = replaceField;

    UIButton *caseButton = [self findButtonTitle:@"Aa" symbol:nil tag:21];
    UIButton *regexButton = [self findButtonTitle:@".*" symbol:nil tag:22];
    UIButton *prevButton = [self findButtonTitle:nil symbol:@"chevron.up" tag:23];
    UIButton *nextButton = [self findButtonTitle:nil symbol:@"chevron.down" tag:24];
    UIButton *closeButton = [self findButtonTitle:nil symbol:@"xmark.circle.fill" tag:25];
    UIButton *replaceButton = [self findButtonTitle:@"替换" symbol:nil tag:26];
    UIButton *replaceAllButton = [self findButtonTitle:@"全部替换" symbol:nil tag:27];
    self.findCaseButton = caseButton;
    self.findRegexButton = regexButton;

    UIStackView *row1 = [[UIStackView alloc] initWithArrangedSubviews:@[
        search, caseButton, regexButton, prevButton, nextButton, closeButton]];
    row1.axis = UILayoutConstraintAxisHorizontal;
    row1.spacing = 6;
    row1.distribution = UIStackViewDistributionFill;
    [search setContentHuggingPriority:UILayoutPriorityDefaultLow
        forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *row2 = [[UIStackView alloc] initWithArrangedSubviews:@[
        replaceField, replaceButton, replaceAllButton]];
    row2.axis = UILayoutConstraintAxisHorizontal;
    row2.spacing = 6;
    [replaceField setContentHuggingPriority:UILayoutPriorityDefaultLow
        forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *vstack = [[UIStackView alloc] initWithArrangedSubviews:@[row1, row2]];
    vstack.axis = UILayoutConstraintAxisVertical;
    vstack.spacing = 6;
    vstack.distribution = UIStackViewDistributionFillEqually;
    vstack.translatesAutoresizingMaskIntoConstraints = NO;
    vstack.layoutMargins = UIEdgeInsetsMake(6, 8, 6, 8);
    vstack.layoutMarginsRelativeArrangement = YES;
    [self.findBar addSubview:vstack];
    [NSLayoutConstraint activateConstraints:@[
        [vstack.topAnchor constraintEqualToAnchor:self.findBar.topAnchor],
        [vstack.bottomAnchor constraintEqualToAnchor:self.findBar.bottomAnchor],
        [vstack.leadingAnchor constraintEqualToAnchor:self.findBar.leadingAnchor],
        [vstack.trailingAnchor constraintEqualToAnchor:self.findBar.trailingAnchor],
    ]];

    // 关键：查找栏是「两个输入框自己的 accessory」，谁获得焦点都带着它。
    // 若是挂在编辑器文本视图上，输入框一接管焦点原 accessory 就被系统丢弃
    // （表现为点输入框工具栏消失、键盘收起）。
    self.findField.inputAccessoryView = self.findBar;
    self.replaceField.inputAccessoryView = self.findBar;
}

- (UIButton *)findButtonTitle:(NSString *)title symbol:(NSString *)symbol tag:(NSInteger)tag
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    if (symbol.length) {
        [button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    } else {
        [button setTitle:title forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    }
    button.tag = tag;
    [button addTarget:self action:@selector(findButtonTapped:)
        forControlEvents:UIControlEventTouchUpInside];
    [button setContentHuggingPriority:UILayoutPriorityRequired
        forAxis:UILayoutConstraintAxisHorizontal];
    return button;
}

- (void)showFindBar
{
    self.currentMatchIndex = -1;
    [self refreshFindMatches];
    [self updateFindButtons];
    // 输入框自己带 accessory（findBar），获得焦点即带出键盘+查找栏；
    // 编辑器文本视图自动释放焦点，不再有 accessory 被丢弃的问题。
    (void)[self.findField becomeFirstResponder];
}

- (void)hideFindBar
{
    (void)[self.findField resignFirstResponder];
    (void)[self.replaceField resignFirstResponder];
    // 焦点还给编辑器：恢复「编辑」accessory 与光标。
    (void)[self.editorView becomeFirstResponder];
    [self.editorView clearSearchHighlights];
}

- (void)findTextChanged:(__unused UITextField *)field
{
    self.currentMatchIndex = -1;
    [self refreshFindMatches];
}

- (void)findButtonTapped:(UIButton *)button
{
    switch (button.tag) {
        case 21: self.caseSensitive = !self.caseSensitive; break;
        case 22:
            self.regexEnabled = !self.regexEnabled;
            if (self.regexEnabled) self.caseSensitive = NO;
            break;
        case 23: [self findPrevious]; return;
        case 24: [self findNext]; return;
        case 25: [self hideFindBar]; return;
        case 26: [self replaceCurrent]; return;
        default: [self replaceAll]; return; // 27
    }
    self.currentMatchIndex = -1;
    [self refreshFindMatches];
    [self updateFindButtons];
}

- (void)updateFindButtons
{
    self.findCaseButton.alpha = self.caseSensitive ? 1.0 : 0.35;
    self.findRegexButton.alpha = self.regexEnabled ? 1.0 : 0.35;
}

- (NSRegularExpression *)currentRegex
{
    NSString *pattern = self.findField.text ?: @"";
    if (pattern.length == 0) return nil;
    if (!self.regexEnabled) {
        pattern = [NSRegularExpression escapedPatternForString:pattern];
    }
    NSRegularExpressionOptions options = NSRegularExpressionAnchorsMatchLines;
    if (!self.caseSensitive) options |= NSRegularExpressionCaseInsensitive;
    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern
        options:options error:&error];
    if (error) return nil;
    return regex;
}

- (void)refreshFindMatches
{
    NSRegularExpression *regex = [self currentRegex];
    NSString *text = [self.editorView currentText];
    NSMutableArray<NSValue *> *ranges = [NSMutableArray array];
    if (regex && text.length) {
        [regex enumerateMatchesInString:text options:0
            range:NSMakeRange(0, text.length)
            usingBlock:^(NSTextCheckingResult *result, __unused NSMatchingFlags flags,
                          __unused BOOL *stop) {
                [ranges addObject:[NSValue valueWithRange:result.range]];
            }];
    }
    self.matchRanges = ranges;
    [self.editorView setSearchHighlights:ranges];
}

- (void)findNext
{
    [self stepMatch:1];
}

- (void)findPrevious
{
    [self stepMatch:-1];
}

- (void)stepMatch:(NSInteger)step
{
    if (self.matchRanges.count == 0) return;
    self.currentMatchIndex = (self.currentMatchIndex + step + (NSInteger)self.matchRanges.count)
        % (NSInteger)self.matchRanges.count;
    NSValue *value = self.matchRanges[(NSUInteger)self.currentMatchIndex];
    [self.editorView selectRange:value.rangeValue];
}

- (void)replaceCurrent
{
    if (self.currentMatchIndex < 0 || (NSUInteger)self.currentMatchIndex >= self.matchRanges.count) {
        [self findNext];
        return;
    }
    NSRange range = self.matchRanges[(NSUInteger)self.currentMatchIndex].rangeValue;
    NSString *replacement = [self replacementForRange:range];
    [self.editorView applyReplacements:@[[NSValue valueWithRange:range]]
                                  texts:@[replacement]];
    self.changed = YES;
    [self setSaveEnabled:YES];
    [self refreshFindMatches];
}

- (void)replaceAll
{
    if (self.matchRanges.count == 0) return;
    NSRegularExpression *regex = [self currentRegex];
    NSString *text = [self.editorView currentText];
    NSString *pattern = self.replaceField.text ?: @"";
    NSMutableArray<NSValue *> *ranges = [NSMutableArray array];
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (NSValue *value in self.matchRanges) {
        NSRange range = value.rangeValue;
        NSString *replacement = pattern;
        if (self.regexEnabled && regex) {
            NSTextCheckingResult *result = [regex firstMatchInString:text options:0 range:range];
            if (result) {
                replacement = [regex replacementStringForResult:result inString:text
                    offset:0 template:pattern];
            }
        }
        [ranges addObject:value];
        [texts addObject:replacement];
    }
    [self.editorView applyReplacements:ranges texts:texts];
    self.currentMatchIndex = -1;
    self.changed = YES;
    [self setSaveEnabled:YES];
    [self refreshFindMatches];
}

- (NSString *)replacementForRange:(NSRange)range
{
    NSString *pattern = self.replaceField.text ?: @"";
    if (!self.regexEnabled) return pattern;
    NSRegularExpression *regex = [self currentRegex];
    NSString *text = [self.editorView currentText];
    NSTextCheckingResult *result = regex ? [regex firstMatchInString:text options:0 range:range] : nil;
    if (result) {
        return [regex replacementStringForResult:result inString:text offset:0 template:pattern];
    }
    return pattern;
}

#pragma mark - Text field delegate (close keyboard on done in find bar)

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    if (textField == self.findField) {
        [self.findField resignFirstResponder];
    } else {
        [self.replaceField resignFirstResponder];
    }
    return YES;
}

#pragma mark - Keyboard shortcuts (iPad)

- (NSArray<UIKeyCommand *> *)keyCommands
{
    return @[
        [UIKeyCommand keyCommandWithInput:@"s" modifierFlags:UIKeyModifierCommand
            action:@selector(keySave:)],
        [UIKeyCommand keyCommandWithInput:@"f" modifierFlags:UIKeyModifierCommand
            action:@selector(keyFind:)],
        [UIKeyCommand keyCommandWithInput:@"g" modifierFlags:UIKeyModifierCommand
            action:@selector(keyGoToLine:)],
        [UIKeyCommand keyCommandWithInput:@"z" modifierFlags:UIKeyModifierCommand
            action:@selector(keyUndo:)],
        [UIKeyCommand keyCommandWithInput:@"z" modifierFlags:UIKeyModifierCommand|UIKeyModifierShift
            action:@selector(keyRedo:)],
    ];
}

- (void)keySave:(__unused UIKeyCommand *)command { [self save]; }
- (void)keyFind:(__unused UIKeyCommand *)command { [self showFindBar]; }
- (void)keyGoToLine:(__unused UIKeyCommand *)command { [self promptGoToLine]; }
- (void)keyUndo:(__unused UIKeyCommand *)command { [self.editorView undo]; }
- (void)keyRedo:(__unused UIKeyCommand *)command { [self.editorView redo]; }

#pragma mark - Feedback

- (void)flash:(NSString *)message
{
    [FFPreviewRouter toastOnNav:self.navigationController message:message];
}

@end
