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
    NSString *normalized = query ?: @"";
    if ([_query isEqualToString:normalized] && _regexEnabled == regex && _caseSensitive == caseSensitive)
        return;

    _query = normalized;
    _regexEnabled = regex;
    _caseSensitive = caseSensitive;
    _latestGeneration++;

    // 新 query/options 是一个全新的导航会话。旧 snapshot / index 不能继续参与
    // Previous/Next，否则第一次导航会从旧结果位置开始甚至在新数组中指向另一项。
    _matches = @[];
    _currentIndex = -1;
    _scrollPendingNavigation = NO;
    _state = normalized.length ? FFSearchSessionStateSearching : FFSearchSessionStateIdle;
    [self notifyChanged];
}

- (void)setSearchText:(NSString *)text
{
    NSString *normalized = text ?: @"";
    if ([_searchText isEqualToString:normalized]) return;

    _searchText = normalized;
    // 正文变化才让 generation 前进。此前每次 scheduleSearchRefresh 都会无条件
    // generation++，即使正文没变，会制造不必要的 stale scan 竞争。
    if (self.query.length > 0) {
        _latestGeneration++;
        _state = FFSearchSessionStateSearching;
        _scrollPendingNavigation = NO;
        [self notifyChanged];
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
            if (r.location == NSNotFound || r.length == 0) return;
            if (r.location > text.length || r.length > text.length - r.location) return;
            [ranges addObject:[NSValue valueWithRange:r]];
        }];

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
        if (previous.location != NSNotFound && NSEqualRanges(r, previous)) continue;
        [deduped addObject:value];
        previous = r;
    }
    return [deduped copy];
}

+ (NSInteger)repairIndexForKeyRange:(NSRange)keyRange
                            matches:(NSArray<NSValue *> *)matches
{
    if (keyRange.location == NSNotFound || matches.count == 0) return -1;
    NSInteger best = 0;
    NSUInteger bestDistance = NSUIntegerMax;
    for (NSUInteger i = 0; i < matches.count; i++) {
        NSUInteger location = [matches[i] rangeValue].location;
        NSUInteger distance = location >= keyRange.location
            ? location - keyRange.location : keyRange.location - location;
        if (distance < bestDistance) {
            bestDistance = distance;
            best = (NSInteger)i;
            if (distance == 0) break;
        }
    }
    return best;
}

- (void)publishMatchesForGeneration:(unsigned long long)g
                              query:(NSString *)query
                       regexEnabled:(BOOL)regexEnabled
                      caseSensitive:(BOOL)caseSensitive
                               text:(NSString *)text
                        anchorRange:(NSRange)anchorRange
{
    if (g != self.latestGeneration) {
        FFLogTag(@"Find", @"discard stale scan gen=%llu latest=%llu", g, self.latestGeneration);
        return;
    }

    NSArray<NSValue *> *snapshot = [FFSearchSession scanMatchesForQuery:query
                                                           regexEnabled:regexEnabled
                                                          caseSensitive:caseSensitive
                                                                   text:text];
    // 原子发布：anchor 必须来自旧 snapshot，在替换 matches 之前捕获。
    self.matches = snapshot;
    self.currentIndex = [FFSearchSession repairIndexForKeyRange:anchorRange matches:snapshot];
    self.state = snapshot.count > 0 ? FFSearchSessionStateReady : FFSearchSessionStateEmpty;
    self.scrollPendingNavigation = NO;
    [self notifyChanged];
}

- (void)refreshNow
{
    if (self.query.length == 0) {
        self.matches = @[];
        self.currentIndex = -1;
        self.state = FFSearchSessionStateIdle;
        self.scrollPendingNavigation = NO;
        [self notifyChanged];
        return;
    }

    unsigned long long g = self.latestGeneration;
    NSString *query = [self.query copy];
    NSString *text = [self.searchText copy] ?: @"";
    BOOL regexEnabled = self.regexEnabled;
    BOOL caseSensitive = self.caseSensitive;
    NSRange anchorRange = self.currentRange;
    [self publishMatchesForGeneration:g query:query regexEnabled:regexEnabled
        caseSensitive:caseSensitive text:text anchorRange:anchorRange];
}

- (void)scheduleRefresh
{
    if (self.query.length == 0) {
        self.matches = @[];
        self.currentIndex = -1;
        self.state = FFSearchSessionStateIdle;
        self.scrollPendingNavigation = NO;
        [self notifyChanged];
        return;
    }

    self.state = FFSearchSessionStateSearching;
    self.scrollPendingNavigation = NO;
    [self notifyChanged];

    // 一次 scan 使用一个完全冻结的输入快照。后台 block 绝不再读 self.query /
    // self.regexEnabled / self.searchText，避免 query 切换时混入另一代数据。
    unsigned long long g = self.latestGeneration;
    NSString *query = [self.query copy];
    NSString *text = [self.searchText copy] ?: @"";
    BOOL regexEnabled = self.regexEnabled;
    BOOL caseSensitive = self.caseSensitive;
    NSRange anchorRange = self.currentRange;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        NSArray<NSValue *> *scanned = [FFSearchSession scanMatchesForQuery:query
                                                             regexEnabled:regexEnabled
                                                            caseSensitive:caseSensitive
                                                                     text:text];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (g != self.latestGeneration) {
                FFLogTag(@"Find", @"discard stale async scan gen=%llu latest=%llu", g,
                    self.latestGeneration);
                return;
            }
            self.matches = scanned;
            self.currentIndex = [FFSearchSession repairIndexForKeyRange:anchorRange matches:scanned];
            self.state = scanned.count > 0 ? FFSearchSessionStateReady : FFSearchSessionStateEmpty;
            self.scrollPendingNavigation = NO;
            [self notifyChanged];
        });
    });
}

#pragma mark - Navigation

- (void)navigateNext
{
    if (self.state != FFSearchSessionStateReady || self.matches.count == 0) return;
    NSInteger count = (NSInteger)self.matches.count;
    self.currentIndex = self.currentIndex < 0 ? 0 : (self.currentIndex + 1) % count;
    self.scrollPendingNavigation = YES;
    [self notifyChanged];
}

- (void)navigatePrevious
{
    if (self.state != FFSearchSessionStateReady || self.matches.count == 0) return;
    NSInteger count = (NSInteger)self.matches.count;
    self.currentIndex = self.currentIndex < 0
        ? count - 1 : (self.currentIndex - 1 + count) % count;
    self.scrollPendingNavigation = YES;
    [self notifyChanged];
}

#pragma mark - Notification

- (void)notifyChanged
{
    if (self.onChanged) self.onChanged();
}

@end
