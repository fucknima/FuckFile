#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, FFSearchSessionState) {
    FFSearchSessionStateIdle = 0,    // 无 query
    FFSearchSessionStateSearching,   // 扫描中（结果未发布）
    FFSearchSessionStateReady,       // 有稳定 snapshot 且 matches>0
    FFSearchSessionStateEmpty,       // 有稳定 snapshot 但 0 命中
};

// 唯一权威搜索会话：query/options → generation → 后台全量扫描 →
// 排序/去重/校验 → 原子发布 immutable matches snapshot →
// Navigation(Prev/Next) 只允许在同一个 snapshot 上进行。
//
// 不变量：
// - matches 按 NSRange.location 升序、去重、range 合法（相对 searchText）；
// - currentIndex ∈ [-1, count-1]；currentRange == matches[currentIndex]
//   （-1 时为 {NSNotFound, 0}）；
// - 发布时若扫描时 generation 已过期 → 丢弃，绝不发布半成品；
// - 任一改变 matches 的操作后：以旧 currentMatchRange 为中心找「最近合法
//   命中」修复索引，禁止沿用旧下标。
@interface FFSearchSession : NSObject

@property(nonatomic, copy, readonly) NSString *query;
@property(nonatomic, readonly) BOOL caseSensitive;
@property(nonatomic, readonly) BOOL regexEnabled;
@property(nonatomic, readonly) FFSearchSessionState state;
@property(nonatomic, readonly) unsigned long long latestGeneration;

// 不可变快照（升序/去重/合法）。读取一律走它。
@property(nonatomic, copy, readonly) NSArray<NSValue *> *matches;
@property(nonatomic, readonly) NSInteger currentIndex;  // -1 = 未选中
@property(nonatomic, readonly) NSRange currentRange;    // currentIndex 对应值

// 最新正文快照（主线程写）。搜索滚动时用到 count。
@property(nonatomic, assign, readonly) NSUInteger matchCount;

// 数据源：后台扫描使用的正文（主线程读取一次后传入 setSearchText）。
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithInitialText:(NSString *)text NS_DESIGNATED_INITIALIZER;
+ (instancetype)new NS_UNAVAILABLE;

// Query/options 变更：generation++，状态 → Searching，触发扫描（后台）。
- (void)setQuery:(NSString *)query regexEnabled:(BOOL)regex caseSensitive:(BOOL)caseSensitive;

// 正文变更（编辑/Undo/Redo/Replace 后）：标记结构变化，重建 snapshot。
- (void)setSearchText:(NSString *)text;

// 立即后台扫描并按 generation 原子发布；结果发布后调用 onChanged（主线程）。
- (void)scheduleRefresh;

// 同步扫描（测试用）：与 scheduleRefresh 相同的 publish 逻辑，无异步。
- (void)refreshNow;

// —— 导航（只基于 snapshot；未 Ready 时 no-op）——
// Next: 未选中→第一个；否则 index+1 wrap。
// Previous: 未选中→最后一个；否则 index-1 wrap。
- (void)navigateNext;
- (void)navigatePrevious;

// 每次内部状态变化（扫描发布/导航）回调，主线程。
@property(nonatomic, copy) void (^onChanged)(void);

// 导航产生的滚动请求（编辑器在 onChanged 内消费后置 NO）。
@property(nonatomic) BOOL scrollPendingNavigation;

@end

NS_ASSUME_NONNULL_END
