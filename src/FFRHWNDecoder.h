#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// RHWN（Apple 私有诊断容器格式）安全解码器。
//
// 当前没有公开的格式规范。本解码器只输出「通过通用数据结构可以
// 可靠确认」的内容：
//   - Header：magic "RHWN"（起始 4 字节，可确认）
//   - 文件总大小（调用方提供的数据长度，可确认）
//   - 版本：仅在样本中出现「干净」的版本字段模式时确认，否则不显示
//   - 可打印字符串：≥ 5 字符的 ASCII 可打印连续段（通用信息提取，
//     用途为「预览疑似内容」而非字段解释）
//   - ASCII 预览
//
// 严禁：猜测未知 offset 含义、计算「network latency/bitrate」等
// 无法通过公开资料或多样本验证的字段。
@interface FFRHWNDecoder : NSObject

@property(nonatomic, readonly) BOOL isRHWN;

// 是否显示「版本」：需要样本中干净版本模式（见实现中的检查）。
@property(nonatomic, readonly) BOOL versionReliable;
@property(nonatomic, readonly) NSString * _Nullable versionString;
@property(nonatomic, readonly) unsigned long long payloadSize;
@property(nonatomic, readonly) NSArray<NSString *> *printableStrings;
@property(nonatomic, readonly) NSString * _Nullable asciiHeadPreview;

- (instancetype)initWithData:(NSData *)data;

@end

NS_ASSUME_NONNULL_END
