#import "FFSearchSession.h"
#import "FFLogger.h"

@interface FFSearchSession ()
@property(nonatomic, copy) NSString *query;
@property(nonatomic) BOOL caseSensitive;
@property(nonatomic) BOOL regexEnabled;
@property(nonatomic) FFSearchSessionState state;
@property(nonatomic) unsigned long long latestGeneration;
@property(nonatomic, copy) NSString *searchText;
@property(nonatomic, copy) NSArray<NSValue *> *matches;
@property(nonatomic) NSInteger currentIndex;
@end

static const NSRange FFNoRange = {NSNotFound, 0};

@implementation FFSearchSession

- (instancetype)initWithInitialText:(NSString *)text
{
    self = [super init];
    if (self) {
        _searchText = text ?: @"";
        _query = @"";
        _state = FFSearchSessionStateIdle;
        _latestGeneration = 0;
        _matches = @[];
        _currentIndex = -1;
        _lastPublishedState = FFSearchSessionStateIdle;
    }
    return self;
}

- (NSUInteger)matchCount
{
    return self.matches.count;
}

- (NSRange)currentRange
{
    if (self.currentIndex < 0 || (NSUInteger)self.currentIndex >= self.matches.count)
        return FFNoRange;
    return [self.matches[(NSUInteger)self.currentIndex] rangeValue];
}

#pragma mark - Query / text mutations

- (void)setQuery:(NSString *)query regexEnabled:(BOOL)regex caseSensitive:(BOOL)caseSensitive
{
    if ([_query isEqualToString:query] && _regexEnabled == regex && _caseSensitive == caseSensitive)
        return;
    _query = query ?: @"";
    _regexEnabled = regex;
    _caseSensitive = caseSensitive;
    _latestGeneration++;
    _state = FFSearchSessionStateSearching;
    [self notifyChanged];
}

- (void)setSearchText:(NSString *)text
{
    _searchText = text ?: @"";
    // 正文变更会让旧 matches 失效：不得沿用旧 currentIndex，
    // 改为发布后按旧 currentRange 就近修复。
    if (self.state != FFSearchSessionStateIdle) {
        _state = FFSearchSessionStateSearching;
        _latestGeneration++;
    }
}

#pragma mark - Scan & publish

+ (NSRegularExpression *)regexForQuery:(NSString *)query
                          regexEnabled:(BOOL)regexEnabled
                         caseSensitive:(BOOL)caseSensitive
{
    if (query.length == 0) return nil;
    NSString *pattern = regexEnabled ? query : [NSRegularExpression escapedPatternForString:query];
    NSRegularExpressionOptions options = NSRegularExpressionAnchorsMatchLines;
    if (!caseSensitive) options |= NSRegularExpressionCaseInsensitive;
    return [NSRegularExpression regularExpressionWithPattern:pattern options:options error:nil];
}

// 核心扫描：纯函数，输出升序/去重/合法 ranges。由 background/TEST 共用。
+ (NSArray<NSValue *> *)scanMatchesForQuery:(NSString *)query
                               regexEnabled:(BOOL)regexEnabled
                              caseSensitive:(BOOL)caseSensitive
                                       text:(NSString *)text
{
    if (text.length == 0 || query.length == 0) return @[];
    NSRegularExpression *regex = [FFSearchSession regexForQuery:query
                                  regexEnabled:regexEnabled caseSensitive:caseSensitive];
    if (!regex) return @[];
    NSMutableArray<NSValue *> *ranges = [NSMutableArray array];
    [regex enumerateMatchesInString:text options:0 range:NSMakeRange(0, text.length)
        usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
            (void)flags; (void)stop;
            NSRange r = result.range;
            if (r.location == NSNotFound || r.length == 0) return; // 忽略零宽/非法
            if (r.location + r.length > text.length) return;
            [ranges addObject:[NSValue valueWithRange:r]];
        }];
    // 按 location 升序 + 去重（同一 range 仅保留一次）。
    [ranges sortUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
        NSRange ra = a.rangeValue, rb = b.rangeValue;
        if (ra.location < rb.location) return NSOrderedAscending;
        if (ra.location > rb.location) return NSOrderedDescending;
        if (ra.length < rb.length) return NSOrderedAscending;
        if (ra.length > rb.length) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    NSMutableArray<NSValue *> *deduped = [NSMutableArray array];
    NSRange previous = FFNoRange;
    for (NSValue *value in ranges) {
        NSRange r = value.rangeValue;
        if (previous.location != NSNotFound && r.location == previous.location && r.length == previous.length)
            continue;
        [deduped addObject:value];
        previous = r;
    }
    return [deduped copy];
}

// 旧选择就近修复：以 oldRange 为锚，选「location 距离最近」的命中；平局取更小 index。
+ (NSInteger)repairIndexForKeyRange:(NSRange)keyRange
                            matches:(NSArray<NSValue *> *)matches
{
    if (keyRange.location == NSNotFound || matches.count == 0) return -1;
    NSInteger best = 0;
    NSUInteger bestDistance = NSUIntegerMax;
    for (NSUInteger i = 0; i < matches.count; i++) {
        NSUInteger location = [matches[i] rangeValue].location;
        NSUInteger distance = location >= (NSUInteger)keyRange.location
            ? location - (NSUInteger)keyRange.location
            : (NSUInteger)keyRange.location - location;
        if (distance < bestDistance) {
            bestDistance = distance;
            best = (NSInteger)i;
            if (distance == 0) break; // 完全同位置：最优
        }
    }
    return best;
}

// 同步发布：g 过期则整体丢弃（防半成品）。
- (void)publishMatchesForGeneration:(unsigned long long)g
                               text:(NSString *)text
{
    if (g != self.latestGeneration) {
        FFLogTag(@"Find", @"discard stale scan gen=%llu latest=%llu", g, self.latestGeneration);
        return;
    }
    // 查询/正文在扫描期间没有变化才发布。
    NSRange keyRange = self.currentRange;
    NSArray<NSValue *> *snapshot = [FFSearchSession scanMatchesForQuery:self.query
                                           regexEnabled:self.regexEnabled
                                          caseSensitive:self.caseSensitive
                                                  text:text];
    self.matches = snapshot;
    self.currentIndex = [FFSearchSession repairIndexForKeyRange:keyRange matches:snapshot];
    self.state = snapshot.count > 0 ? FFSearchSessionStateReady : FFSearchSessionStateEmpty;
    [self notifyChanged];
}

- (void)refreshNow
{
    NSString *text = self.searchText ?: @"";
    unsigned long long g = self.latestGeneration;
    if (self.query.length == 0) {
        self.matches = @[];
        self.currentIndex = -1;
        self.state = FFSearchSessionStateIdle;
        [self notifyChanged];
        return;
    }
    [self publishMatchesForGeneration:g text:text];
}

- (void)scheduleRefresh
{
    if (self.query.length == 0) {
        // 空白 query：稳定空结果。
        self.matches = @[];
        self.currentIndex = -1;
        if (self.state != FFSearchSessionStateIdle) {
            self.state = FFSearchSessionStateIdle;
            [self notifyChanged];
        }
        return;
    }
    self.state = FFSearchSessionStateSearching;
    [self notifyChanged];
    unsigned long long g = self.latestGeneration;
    NSString *text = self.searchText ?: @"";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        // 预计算扫描（后台纯数据，不碰文本视图）。
        NSArray<NSValue *> *scanned = [FFSearchSession scanMatchesForQuery:self.query
                                                             regexEnabled:self.regexEnabled
                                                            caseSensitive:self.caseSensitive
                                                                    text:text];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (g != self.latestGeneration) return; // 已被新请求取代
            self.matches = scanned;
            NSRange keyRange = self.currentRange;
            self.currentIndex = [FFSearchSession repairIndexForKeyRange:keyRange matches:scanned];
            self.state = scanned.count > 0 ? FFSearchSessionStateReady : FFSearchSessionStateEmpty;
            [self notifyChanged];
        });
    });
}

#pragma mark - Navigation（唯一入口：snapshot + wrap 语义）

- (void)navigateNext
{
    if (self.state != FFSearchSessionStateReady || self.matches.count == 0) return;
    NSInteger count = (NSInteger)self.matches.count;
    if (self.currentIndex < 0) {
        self.currentIndex = 0;                       // 未选中 → 第一个
    } else {
        self.currentIndex = (self.currentIndex + 1) % count;
    }
    self.scrollPendingNavigation = YES;
    [self notifyChanged];
}

- (void)navigatePrevious
{
    if (self.state != FFSearchSessionStateReady || self.matches.count == 0) return;
    NSInteger count = (NSInteger)self.matches.count;
    if (self.currentIndex < 0) {
        self.currentIndex = count - 1;               // 未选中 → 最后一个
    } else {
        self.currentIndex = (self.currentIndex - 1 + count) % count;
    }
    self.scrollPendingNavigation = YES;
    [self notifyChanged];
}

#pragma mark - Notification

- (void)notifyChanged
{
    if (self.onChanged) self.onChanged();
}

@end
