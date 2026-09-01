#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Header-only by design: the resolver is currently the sole consumer, so this
// does not add another build target/source-list dependency.
static inline NSDictionary<NSString *, NSString *> *FFBuiltInAppNames(void)
{
    static NSDictionary<NSString *, NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = @{
            // Deliberately conservative, high-confidence short names.
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

static inline NSString * _Nullable FFBuiltInAppNameForIdentifier(NSString *identifier)
{
    if (!identifier.length) return nil;
    return FFBuiltInAppNames()[identifier];
}

static inline NSString *FFCollapseAppNameWhitespace(NSString *value)
{
    if (!value.length) return @"";
    NSArray<NSString *> *parts = [value componentsSeparatedByCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSString *> *nonEmpty = [NSMutableArray array];
    for (NSString *part in parts) if (part.length) [nonEmpty addObject:part];
    return [nonEmpty componentsJoinedByString:@" "];
}

static inline BOOL FFAppNameContainsCJK(NSString *value)
{
    for (NSUInteger i = 0; i < value.length; i++) {
        unichar c = [value characterAtIndex:i];
        if ((c >= 0x3400 && c <= 0x9FFF) || (c >= 0xF900 && c <= 0xFAFF))
            return YES;
    }
    return NO;
}

static inline BOOL FFAppNameContainsAnyPhrase(NSString *value, NSArray<NSString *> *phrases)
{
    for (NSString *phrase in phrases) {
        if ([value rangeOfString:phrase options:NSCaseInsensitiveSearch].location != NSNotFound)
            return YES;
    }
    return NO;
}

static inline BOOL FFAppNameSuffixLooksPromotional(NSString *left, NSString *right,
                                                    BOOL strongSeparator)
{
    if (left.length < 2 || right.length < 3) return NO;
    if (left.length > 40 || right.length > 96) return NO;

    static NSArray<NSString *> *terms;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        terms = @[
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
    if (FFAppNameContainsAnyPhrase(right, terms)) score += 2;
    if ([right rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:
            @",，、;；/｜|"]].location != NSNotFound) score++;
    if (right.length >= 8 && FFAppNameContainsCJK(right)) score++;
    if (right.length > left.length * 2) score++;
    return score >= 2;
}

static inline NSString *FFAppNameTrimAtSeparator(NSString *value, NSString *separator,
                                                  BOOL strong)
{
    NSRange range = [value rangeOfString:separator];
    if (range.location == NSNotFound || range.location == 0) return value;
    NSString *left = [[value substringToIndex:range.location]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *right = [[value substringFromIndex:NSMaxRange(range)]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!FFAppNameSuffixLooksPromotional(left, right, strong)) return value;
    return left;
}

// Conservative App Store title normalization. Raw titles are still kept in the
// resolver cache, so the policy can evolve later without re-querying the store.
static inline NSString *FFNormalizeAppDisplayName(NSString *name)
{
    NSString *value = FFCollapseAppNameWhitespace([name stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet]);
    if (!value.length) return @"";

    NSArray<NSString *> *strongSeparators =
        @[@" - ", @" – ", @" — ", @" ｜ ", @" | ", @"："];
    for (NSString *separator in strongSeparators) {
        NSString *trimmed = FFAppNameTrimAtSeparator(value, separator, YES);
        if (![trimmed isEqualToString:value]) return trimmed;
    }

    // Chinese store titles commonly omit spaces around '-'. For the plain
    // hyphen we demand explicit promotional evidence, protecting names such as
    // X-plore from accidental truncation.
    NSString *trimmed = FFAppNameTrimAtSeparator(value, @"-", NO);
    return trimmed.length ? trimmed : value;
}

NS_ASSUME_NONNULL_END
