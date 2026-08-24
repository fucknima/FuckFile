#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Apple .ips 诊断文件解析结果（解析过程在后台执行；仅解包/推断安全）。
//
// 支持形态：
//   A. 纯文本 / 纯 JSON（无二进制 payload）
//   B. JSON Header + Binary Payload（AMTStreamingStallNetworkDiagnostics-* 等）
//
// 解压策略：Header 声明 compression 优先；标准 zlib inflate 失败（Z_DATA_ERROR）
// 时回退 raw DEFLATE（inflateInit2(-15)）——真实样本存在 metadata 说 zlib、
// 实际是 raw DEFLATE 的情况，metadata 不可全信。
//
// 安全限制：最大解压输出 64 MB；压缩比上限 256:1；超限/损坏/截断/炸弹
// 均以明确失败状态返回，不允许 OOM。
typedef NS_ENUM(NSInteger, FFIPSCompression) {
    FFIPSCompressionNone = 0,
    FFIPSCompressionZlib,
    FFIPSCompressionRawDeflate,
    FFIPSCompressionUnknown,
};

typedef NS_ENUM(NSInteger, FFIPSStatus) {
    FFIPSStatusOK = 0,
    FFIPSStatusNotIPS,             // 非 .ips 或无 Header
    FFIPSStatusUnsupported,        // 结构可解析但当前无法处理
    FFIPSStatusDecompressFailed,   // 两种 inflate 都失败
    FFIPSStatusDecompressBomb,     // 超过输出/比率上限
};

@interface FFIPSParseResult : NSObject
@property(nonatomic, strong) NSDictionary<NSString *, id> *header;   // 顶层 JSON dict
@property(nonatomic, copy) NSData *headerData;                       // 原样 Header JSON 字节
@property(nonatomic) unsigned long long payloadOffset;               // 文件字节偏移
@property(nonatomic) unsigned long long payloadLength;               // 剩余 payload 字节
@property(nonatomic) FFIPSCompression declaredCompression;           // Header 声称
@property(nonatomic) FFIPSCompression actualCompression;             // 实际解码结果
@property(nonatomic) BOOL hasPayload;
@property(nonatomic) FFIPSStatus status;
@property(nonatomic, copy, nullable) NSData *payload;                // 解压成功时为输出
@property(nonatomic) unsigned long long payloadDecodedSize;
@property(nonatomic, copy, nullable) NSString *failureDetail;        // 失败原因文案
// payload 内容探测（解压成功后）："RHWN" / "bplist" / "json" / "xml" / "text" / "binary"
@property(nonatomic, copy, nullable) NSString *payloadFormat;
@property(nonatomic) BOOL isRHWN;
@end

@interface FFIPSParser : NSObject

// 边界扫描：找到 Header JSON 的结束位置（含嵌套与字符串转义）。
// 返回 -1 表示未找到（文件开头非法）。
+ (long long)headerJSONEndOffset:(NSData *)data;

// 完整解析（同步；调用方应放入后台队列）。非 IPS / 失败时 status 说明原因。
+ (FFIPSParseResult *)parseData:(NSData *)data;
+ (FFIPSParseResult *)parseFile:(NSString *)path;

// 便利：识别元信息（供 Viewer 与测试）。
+ (BOOL)fileLooksLikeIPS:(NSString *)path;

// 解压边界常量（公开给测试）。
+ (unsigned long long)maxDecompressedBytes;
+ (unsigned long)maxCompressionRatio;

@end

NS_ASSUME_NONNULL_END
