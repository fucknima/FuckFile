#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// 设置 → 文件查看 → 文件关联：原生 iOS 列表风格的扩展名 → 查看器
// 映射编辑器。支持改关联、新增自定义扩展名、删除覆盖/自定义项，
// 修改立即生效（NSUserDefaults 只存覆盖，内置默认表在代码中）。
@interface FFFileAssociationsViewController : UITableViewController

@end

NS_ASSUME_NONNULL_END
