#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// App Group 共享的标识符（与 Share Extension 一致；TrollStore/带
// entitlement 的侧载环境才能建立共享容器）。
FOUNDATION_EXPORT NSString * const FFAppGroupID;
FOUNDATION_EXPORT NSString * const FFAppGroupInboxFolder;

// 把 Share Extension 写入 App Group SharedInbox 的文件搬运到
// Documents/Device Storage/Imported/（与 AppData 同级，浏览器可见）。
@interface FFImportService : NSObject

+ (instancetype)sharedService;

// App Group 共享目录 URL；不可用时返回 nil。
- (nullable NSURL *)groupContainerURL;

// 扫描共享 Inbox，把文件移动到 Imported/（重名自动加序号）。
// 返回成功搬运数量。
- (NSUInteger)collectGroupInboxToImported;

@end

NS_ASSUME_NONNULL_END