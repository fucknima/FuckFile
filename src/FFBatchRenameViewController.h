#import <UIKit/UIKit.h>

@class FFEntry;

NS_ASSUME_NONNULL_BEGIN

// 批量重命名：查找替换 / 前缀后缀 / 序号命名，带实时预览与冲突校验。
@interface FFBatchRenameViewController : UIViewController
- (instancetype)initWithEntries:(NSArray<FFEntry *> *)entries
                    inDirectory:(NSString *)directory;
@property(nonatomic, copy, nullable) void (^onFinished)(BOOL applied);
@end

NS_ASSUME_NONNULL_END
