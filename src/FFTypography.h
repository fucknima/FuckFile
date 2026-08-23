#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Dynamic Type 字体：按文本样式缩放并指定字重。content size 变化后由
// table 重载重新生成（UIFontMetrics 返回的是当前 category 下的静态字体）。
FOUNDATION_EXPORT UIFont *FFPreferredFont(UIFontTextStyle style, UIFontWeight weight);

NS_ASSUME_NONNULL_END
