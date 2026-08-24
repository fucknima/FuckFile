#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 统一文件内容探测（Previews/Integrations 层共享）。
//
// 设计约束：
// - 只采样必要字节（默认 64 KB 头窗口），绝不整读大文件；
// - isTextData 与 decodeTextData 彻底分离：自动文本判定只认
//   UTF-8 / UTF-16（BOM 或 NUL 模式），禁止用 Latin-1 兜底把
//   随机二进制误判成文本；Latin-1 仅允许「用户强制以文本打开」。
typedef NS_ENUM(NSInteger, FFContentKind) {
    FFContentKindUnknown = 0,
    FFContentKindTextUTF8,
    FFContentKindTextUTF16,
    FFContentKindJSON,
    FFContentKindXML,
    FFContentKindPlist,
    FFContentKindSQLite,
    FFContentKindZIP,
    FFContentKindIPSDiagnostic,
    FFContentKindBinary,
};

@interface FFContentProbe : NSObject

// 探测窗口大小：文本统计与 magic 判断都以该采样为准。
+ (NSUInteger)sampleLength;

// 采样文件头（读取 sampleLength 字节，大文件安全）。失败返回 nil。
+ (nullable NSData *)sampleFile:(NSString *)path;

// 从采样数据得出内容类别。
+ (FFContentKind)contentKindOfSample:(NSData *)sample;

// 便捷：文件 → 类别（内部采样）。
+ (FFContentKind)contentKindOfFile:(NSString *)path;
+ (FFContentKind)contentKindOfData:(NSData *)data; // 数据较小（≤16MB）整份传入

// 纯文本判定（不包含 Latin-1 兜底、不包含 JSON 优先）。
// YES 表示内容可用于解码为文本展示。
+ (BOOL)isTextSample:(NSData *)sample;

// 检测文本编码：UTF-8（BOM 与否）/ UTF-16 LE/BE。
// 不是合法文本时返回 nil。*hasBOM 有输出时刷新指示 BOM 是否存在。
+ (nullable NSString *)detectedEncodingOfSample:(NSData *)sample hasBOM:(BOOL *)hasBOM;

// 严格的 UTF-8 有效性校验（供 FFTextCodec / 测试复用）。
+ (BOOL)isValidUTF8Sample:(NSData *)data;

// IPS 识别调用方：header JSON 扫描完成后判定 True Negative 用。
+ (BOOL)looksLikeIPSDiagnostic:(NSData *)sample;

+ (BOOL)isSQLite:(NSData *)sample;
+ (BOOL)isZIP:(NSData *)sample;

@end

NS_ASSUME_NONNULL_END
