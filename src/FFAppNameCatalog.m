#import "FFAppNameCatalog.h"

static NSDictionary<NSString *, NSString *> *FFBuiltInAppNames(void)
{
    static NSDictionary<NSString *, NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = @{
            // High-confidence identifiers seen commonly on Chinese iOS devices.
            // Keep this list deliberately conservative: a wrong short name is
            // worse than falling back to the online resolver.
            @"com.baidu.netdisk": @"百度网盘",
            @"com.chowjoe.wp2free": @"壁纸",
            @"net.colorfulclouds.app.pro": @"彩云天气Pro",
            @"com.ss.iphone.ugc.Aweme": @"抖音",
            @"com.autonavi.amap": @"高德地图",
            @"com.xhey.XCamera": @"今日水印相机",
            @"com.360buy.jdmobile": @"京东",
            @"com.coolapk.app": @"酷安",
            @"com.quark.clouddrive": @"夸克网盘",
            @"com.tencent.xin": @"微信",
            @"com.tencent.mqq": @"QQ",
            @"com.taobao.taobao4iphone": @"淘宝",
            @"com.alibaba.Alipay": @"支付宝",
            @"com.sina.weibo": @"微博",
            @"com.zhihu.ios": @"知乎",
            @"com.xingin.discover": @"小红书",
            @"com.netease.cloudmusic": @"网易云音乐",
            @"tv.danmaku.bilianime": @"哔哩哔哩",
            @"com.baidu.BaiduMobile": @"百度",
        };
    });
    return names;
}

NSString *FFBuiltInAppNameForIdentifier(NSString *identifier)
{
    if (!identifier.length) return nil;
    return FFBuiltInAppNames()[identifier];
}

static NSString *FFCollapseWhitespace(NSString *value)
{
    if (!value.length) return @"";
    NSArray<NSString *> *parts = [value componentsSeparatedByCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSString *> *nonEmpty = [NSMutableArray array];
    for (NSString *part in parts) if (part.length) [nonEmpty addObject:part];
    return [nonEmpty componentsJoinedByString:@" "];
}

static BOOL FFStringContainsCJK(NSString *value)
{
    for (NSUInteger i = 0; i < value.length; i++) {
        unichar c = [value characterAtIndex:i];
        if ((c >= 0x3400 && c <= 0x9FFF) || (c >= 0xF900 && c <= 0xFAFF))
            return YES;
    }
    return NO;
}

static BOOL FFContainsAnyPhrase(NSString *value, NSArray<NSString *> *phrases)
{
    for (NSString *phrase in phrases)
        if ([value rangeOfString:phrase options:NSCaseInsensitiveSearch].location != NSNotFound)
            return YES;
    return NO;
}

static BOOL FFSuffixLooksPromotional(NSString *left, NSString *right, BOOL strongSeparator)
{
    if (left.length < 2 || right.length < 3) return NO;
    if (left.length > 40 || right.length > 80) return NO;

    static NSArray<NSString *> *marketingTerms;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        marketingTerms = @[
            @"导航", @"公交", @"地铁", @"出行", @"打车", @"壁纸", @"高清",
            @"背景", @"主题", @"拍照", @"打卡", @"时间", @"地点", @"经纬度",
            @"分享", @"生活", @"科技", @"极速", @"无广", @"无广告", @"便宜",
            @"优惠", @"省钱", @"精选", @"海量", @"全能", @"一站式", @"助手",
            @"工具", @"智能", @"官方", @"专业", @"免费", @"必备", @"购物",
            @"短剧", @"直播", @"小说", @"视频", @"音乐", @"相机", @"图片",
            @"AI", @"Live图", @"美好", @"又好又便宜"
        ];
    });

    NSInteger score = 0;
    if (strongSeparator) score++;
    if (FFContainsAnyPhrase(right, marketingTerms)) score += 2;
    if ([right rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:
            @",，、;；/｜|"]].location != NSNotFound) score++;
    if (right.length >= 8 && FFStringContainsCJK(right)) score++;
    if (right.length > left.length * 2) score++;
    return score >= 2;
}

static NSString *FFTrimAtSeparator(NSString *value, NSString *separator, BOOL strong)
{
    NSRange range = [value rangeOfString:separator];
    if (range.location == NSNotFound || range.location == 0) return value;
    NSString *left = [[value substringToIndex:range.location]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *right = [[value substringFromIndex:NSMaxRange(range)]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!FFSuffixLooksPromotional(left, right, strong)) return value;
    return left;
}

NSString *FFNormalizeAppDisplayName(NSString *name)
{
    NSString *value = FFCollapseWhitespace([name stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet]);
    if (!value.length) return @"";

    // Spaced/typographic separators are strong evidence that the right-hand
    // side is an App Store subtitle. Plain '-' is handled last and requires a
    // higher promotional score, avoiding names such as X-plore.
    NSArray<NSString *> *strongSeparators = @[@" - ", @" – ", @" — ", @" ｜ ", @" | ", @"："];
    for (NSString *separator in strongSeparators) {
        NSString *trimmed = FFTrimAtSeparator(value, separator, YES);
        if (![trimmed isEqualToString:value]) return trimmed;
    }

    // Many Chinese App Store titles omit spaces around '-'. Only cut when the
    // suffix itself strongly looks like marketing copy.
    NSString *hyphenTrimmed = FFTrimAtSeparator(value, @"-", NO);
    return hyphenTrimmed.length ? hyphenTrimmed : value;
}
