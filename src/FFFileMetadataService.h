#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 展示用路径缩略：只显示最后 2~3 层（"AppData › 微信 › Documents"），
// 绝不展示完整 /private/var/... 链路；完整路径只在文件信息页/复制路径出现。
FOUNDATION_EXPORT NSString *FFAbbreviatedDisplayPath(NSString *path);

// 属性页专用元数据读取：xattr、递归统计、哈希、MIME。
// 这些都是慢操作，只允许在后台队列调用，禁止进入目录扫描主路径。
@interface FFFileMetadataService : NSObject

// listxattr/getxattr 的可读行（"  name (N bytes)"），首行为"扩展属性："标题。
+ (NSArray<NSString *> *)extendedAttributeLinesForPath:(NSString *)path;

// 一次遍历得到递归大小与条目计数。
+ (void)statDirectoryAtPath:(NSString *)path
             completion:(void (^)(unsigned long long size,
                 NSUInteger fileCount, NSUInteger folderCount))completion;

// 普通文件的 SHA-256，不可读返回 nil。
+ (nullable NSString *)sha256OfFile:(NSString *)path;

// 扩展名对应 MIME（UTType），未知返回 nil。
+ (nullable NSString *)mimeTypeNameForFilenameExtension:(NSString *)extension;

@end

NS_ASSUME_NONNULL_END
