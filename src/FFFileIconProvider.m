#import "FFFileIconProvider.h"
#import "FFBrowserViewController.h"

@interface FFFileIconStyle : NSObject
@property(nonatomic, strong) UIColor *color;
@property(nonatomic, copy, nullable) NSString *symbol;
@property(nonatomic, copy, nullable) NSString *label;
@property(nonatomic) BOOL square;
@end
@implementation FFFileIconStyle
@end

@implementation FFFileIconProvider

+ (NSCache<NSString *, UIImage *> *)cache
{
    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSCache new];
        cache.countLimit = 160;
    });
    return cache;
}

+ (UIColor *)resolved:(UIColor *)color
{
    if (@available(iOS 13.0, *))
        return [color resolvedColorWithTraitCollection:UITraitCollection.currentTraitCollection];
    return color;
}

+ (FFFileIconStyle *)styleWithColor:(UIColor *)color symbol:(NSString *)symbol label:(NSString *)label square:(BOOL)square
{
    FFFileIconStyle *style = [FFFileIconStyle new];
    style.color = color;
    style.symbol = symbol;
    style.label = label;
    style.square = square;
    return style;
}

+ (FFFileIconStyle *)styleForExtension:(NSString *)ext
{
    static NSDictionary<NSString *, FFFileIconStyle *> *styles;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        void (^set)(NSArray<NSString *> *, UIColor *, NSString *, NSString *, BOOL) =
        ^(NSArray<NSString *> *exts, UIColor *color, NSString *symbol, NSString *label, BOOL square) {
            for (NSString *e in exts) m[e] = [self styleWithColor:color symbol:symbol label:label square:square];
        };

        // Office / documents.
        set(@[@"doc",@"docx",@"docm",@"dot",@"dotx",@"dotm"], UIColor.systemBlueColor, nil, @"DOC", NO);
        set(@[@"xls",@"xlsx",@"xlsm",@"xlsb",@"xlt",@"xltx",@"xltm",@"csv",@"tsv"], UIColor.systemGreenColor, nil, @"XLS", NO);
        set(@[@"ppt",@"pptx",@"pptm",@"pps",@"ppsx",@"ppsm",@"pot",@"potx",@"potm"], UIColor.systemOrangeColor, nil, @"PPT", NO);
        set(@[@"pdf"], UIColor.systemRedColor, nil, @"PDF", NO);
        set(@[@"pages"], UIColor.systemOrangeColor, @"pencil", nil, NO);
        set(@[@"numbers"], UIColor.systemGreenColor, @"chart.bar.fill", nil, NO);
        set(@[@"key"], UIColor.systemBlueColor, @"rectangle.on.rectangle.angled", nil, NO);
        set(@[@"rtf",@"rtfd",@"txt"], UIColor.systemBlueColor, @"text.alignleft", nil, NO);
        set(@[@"md",@"markdown",@"mdown"], UIColor.systemIndigoColor, nil, @"MD", NO);
        set(@[@"epub"], UIColor.systemBrownColor, @"book.closed.fill", nil, NO);

        // Structured data / source / config.
        set(@[@"json"], UIColor.systemGreenColor, nil, @"{}", NO);
        set(@[@"xml"], UIColor.systemBlueColor, nil, @"XML", NO);
        set(@[@"plist"], UIColor.systemTealColor, nil, @"PL", NO);
        set(@[@"ini",@"conf",@"config",@"yaml",@"yml",@"toml"], UIColor.systemTealColor, @"gearshape.fill", nil, NO);
        set(@[@"c",@"h",@"m",@"mm",@"swift",@"py",@"js",@"ts",@"tsx",@"java",@"kt",@"go",@"rs",@"rb",@"php",@"css",@"html",@"htm"], UIColor.systemPurpleColor, @"chevron.left.forwardslash.chevron.right", nil, NO);
        set(@[@"sh",@"command",@"bash",@"zsh"], UIColor.systemGrayColor, @"terminal.fill", nil, YES);
        set(@[@"log"], UIColor.systemTealColor, nil, @"LOG", NO);

        // Archives / installers / packages.
        set(@[@"zip",@"tar",@"gz",@"tgz",@"bz2",@"xz"], UIColor.systemBrownColor, @"archivebox.fill", nil, NO);
        set(@[@"rar"], UIColor.systemOrangeColor, nil, @"RAR", NO);
        set(@[@"7z"], UIColor.systemYellowColor, nil, @"7Z", NO);
        set(@[@"ipa"], UIColor.systemIndigoColor, @"arrow.down.app.fill", nil, YES);
        set(@[@"apk"], UIColor.systemGreenColor, nil, @"APK", YES);
        set(@[@"dmg"], UIColor.systemBlueColor, @"externaldrive.fill", nil, NO);
        set(@[@"app",@"appex"], UIColor.systemBlueColor, @"app.fill", nil, YES);
        set(@[@"bundle",@"framework",@"dylib",@"so",@"a"], UIColor.systemGrayColor, @"shippingbox.fill", nil, NO);

        // Media.
        set(@[@"png",@"jpg",@"jpeg",@"gif",@"heic",@"webp",@"bmp",@"tif",@"tiff",@"ico",@"svg",@"car"], UIColor.systemGrayColor, @"photo.fill", nil, NO);
        set(@[@"mp4",@"mov",@"m4v",@"avi",@"mkv",@"3gp"], UIColor.systemPurpleColor, @"play.rectangle.fill", nil, YES);
        set(@[@"mp3",@"m4a",@"wav",@"aac",@"caf",@"flac",@"aiff",@"aif"], UIColor.systemPinkColor, @"music.note", nil, YES);
        set(@[@"ttf",@"otf",@"woff",@"woff2"], UIColor.systemBlueColor, nil, @"Aa", YES);

        // Data / design / binary.
        set(@[@"db",@"sqlite",@"sqlite3",@"sqlitedb"], UIColor.systemTealColor, @"cylinder.fill", nil, NO);
        set(@[@"dwg",@"dxf"], UIColor.systemRedColor, @"ruler.fill", nil, NO);
        set(@[@"psd"], UIColor.systemTealColor, nil, @"PSD", YES);
        set(@[@"ai"], UIColor.systemOrangeColor, nil, @"AI", YES);
        set(@[@"sketch"], UIColor.systemPinkColor, @"diamond.fill", nil, YES);
        set(@[@"bin",@"dat",@"hex"], UIColor.systemGrayColor, nil, @"01", NO);
        set(@[@"cer",@"crt",@"p12",@"mobileconfig"], UIColor.systemTealColor, @"lock.doc.fill", nil, NO);
        styles = [m copy];
    });
    return styles[ext];
}

+ (void)drawCenteredSymbol:(NSString *)name color:(UIColor *)color inRect:(CGRect)rect
{
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightSemibold];
    UIImage *symbol = [UIImage systemImageNamed:name withConfiguration:cfg];
    if (!symbol) symbol = [UIImage systemImageNamed:@"doc.fill" withConfiguration:cfg];
    symbol = [symbol imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal];
    CGSize size = symbol.size;
    CGFloat scale = MIN(rect.size.width / MAX(size.width, 1), rect.size.height / MAX(size.height, 1));
    size = CGSizeMake(size.width * scale, size.height * scale);
    CGRect target = CGRectMake(CGRectGetMidX(rect) - size.width / 2,
                               CGRectGetMidY(rect) - size.height / 2,
                               size.width, size.height);
    [symbol drawInRect:CGRectIntegral(target)];
}

+ (void)drawLabel:(NSString *)label color:(UIColor *)color inRect:(CGRect)rect
{
    CGFloat fontSize = label.length >= 3 ? 10.5 : 13.0;
    UIFont *font = [UIFont monospacedSystemFontOfSize:fontSize weight:UIFontWeightBold];
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.alignment = NSTextAlignmentCenter;
    NSDictionary *attrs = @{NSFontAttributeName:font,
                            NSForegroundColorAttributeName:color,
                            NSParagraphStyleAttributeName:paragraph};
    CGSize s = [label sizeWithAttributes:attrs];
    CGRect target = CGRectMake(rect.origin.x,
                               CGRectGetMidY(rect) - s.height / 2 - 0.5,
                               rect.size.width, s.height + 2);
    [label drawInRect:target withAttributes:attrs];
}

+ (UIImage *)renderFolderWithColor:(UIColor *)base canvas:(CGSize)size
{
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [[renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        (void)ctx;
        UIColor *color = [self resolved:base];
        UIColor *tab = [color colorWithAlphaComponent:0.8];
        [tab setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(2, 5, 28, 16) cornerRadius:5] fill];
        [color setFill];
        UIBezierPath *body = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0.5, 11, 47, 36) cornerRadius:9];
        [body fill];
        [[UIColor.whiteColor colorWithAlphaComponent:0.16] setStroke];
        body.lineWidth = 1;
        [body stroke];
    }] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

+ (UIImage *)renderSquareWithStyle:(FFFileIconStyle *)style canvas:(CGSize)size
{
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [[renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        (void)ctx;
        UIColor *color = [self resolved:style.color];
        [color setFill];
        UIBezierPath *card = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0.5, 0.5, 47, 47) cornerRadius:11];
        [card fill];
        [[UIColor.whiteColor colorWithAlphaComponent:0.18] setStroke];
        card.lineWidth = 1;
        [card stroke];
        CGRect glyphRect = CGRectMake(10, 10, 28, 28);
        if (style.label.length) [self drawLabel:style.label color:UIColor.whiteColor inRect:glyphRect];
        else [self drawCenteredSymbol:style.symbol ?: @"doc.fill" color:UIColor.whiteColor inRect:glyphRect];
    }] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

+ (UIImage *)renderFileWithStyle:(FFFileIconStyle *)style canvas:(CGSize)size
{
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [[renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        (void)ctx;
        UIColor *color = [self resolved:style.color];

        UIBezierPath *body = [UIBezierPath bezierPath];
        [body moveToPoint:CGPointMake(6, 0.5)];
        [body addLineToPoint:CGPointMake(35, 0.5)];
        [body addLineToPoint:CGPointMake(47.5, 13)];
        [body addLineToPoint:CGPointMake(47.5, 42)];
        [body addQuadCurveToPoint:CGPointMake(42, 47.5) controlPoint:CGPointMake(47.5, 47.5)];
        [body addLineToPoint:CGPointMake(6, 47.5)];
        [body addQuadCurveToPoint:CGPointMake(0.5, 42) controlPoint:CGPointMake(0.5, 47.5)];
        [body addLineToPoint:CGPointMake(0.5, 6)];
        [body addQuadCurveToPoint:CGPointMake(6, 0.5) controlPoint:CGPointMake(0.5, 0.5)];
        [body closePath];
        [color setFill];
        [body fill];

        [[UIColor.whiteColor colorWithAlphaComponent:0.32] setFill];
        UIBezierPath *fold = [UIBezierPath bezierPath];
        [fold moveToPoint:CGPointMake(35, 0.5)];
        [fold addLineToPoint:CGPointMake(35, 13)];
        [fold addLineToPoint:CGPointMake(47.5, 13)];
        [fold closePath];
        [fold fill];

        [[UIColor.whiteColor colorWithAlphaComponent:0.16] setStroke];
        body.lineWidth = 1;
        [body stroke];

        CGRect glyphRect = CGRectMake(8, 14, 32, 25);
        if (style.label.length) [self drawLabel:style.label color:UIColor.whiteColor inRect:glyphRect];
        else [self drawCenteredSymbol:style.symbol ?: @"doc.fill" color:UIColor.whiteColor inRect:glyphRect];
    }] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

+ (UIImage *)iconForEntry:(FFEntry *)entry
{
    NSString *ext = entry.name.pathExtension.lowercaseString ?: @"";
    BOOL packageDirectory = entry.isDirectory &&
        [@[@"app", @"appex", @"bundle", @"framework", @"xcarchive"] containsObject:ext];

    NSString *token = nil;
    FFFileIconStyle *style = nil;
    if (entry.isAppContainer) {
        token = @"app-container";
        style = [self styleWithColor:UIColor.systemIndigoColor symbol:@"cube.fill" label:nil square:YES];
    } else if (entry.isSymlink) {
        token = @"symlink";
        style = [self styleWithColor:UIColor.systemTealColor symbol:@"link" label:nil square:YES];
    } else if (entry.isDirectory && !packageDirectory) {
        token = @"folder";
    } else {
        style = [self styleForExtension:ext];
        if (!style) {
            if ([entry.name hasPrefix:@"."])
                style = [self styleWithColor:UIColor.systemGrayColor symbol:@"gearshape.fill" label:nil square:NO];
            else
                style = [self styleWithColor:UIColor.systemGray2Color symbol:@"doc.fill" label:nil square:NO];
        }
        token = [NSString stringWithFormat:@"file:%@:%@:%@:%d", ext,
                 style.symbol ?: @"", style.label ?: @"", style.square];
    }

    UIUserInterfaceStyle interfaceStyle = UITraitCollection.currentTraitCollection.userInterfaceStyle;
    NSString *key = [NSString stringWithFormat:@"%@|%ld", token, (long)interfaceStyle];
    UIImage *cached = [[self cache] objectForKey:key];
    if (cached) return cached;

    UIImage *image = nil;
    CGSize canvas = CGSizeMake(48, 48);
    if ([token isEqualToString:@"folder"])
        image = [self renderFolderWithColor:UIColor.systemBlueColor canvas:canvas];
    else if (style.square)
        image = [self renderSquareWithStyle:style canvas:canvas];
    else
        image = [self renderFileWithStyle:style canvas:canvas];

    if (image) [[self cache] setObject:image forKey:key];
    return image ?: [UIImage systemImageNamed:@"doc.fill"];
}

@end
