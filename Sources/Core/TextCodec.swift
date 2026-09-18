import Foundation

/// 文本编码种类（保存时按用户选择输出）。
enum TextEncodingKind: String, CaseIterable, Identifiable {
    case utf8, utf8BOM, utf16LE, utf16BE, latin1

    var id: String { rawValue }
}

/// 换行符种类。
enum LineEnding: String, CaseIterable, Identifiable {
    case lf, crlf, cr

    var id: String { rawValue }
}

/// 解码结果：文本 + 探测出的编码 / BOM / 换行符。
struct DecodedText {
    let text: String
    let encoding: TextEncodingKind
    let bom: Bool
    let lineEnding: LineEnding
}

/// 统一文本编解码。
/// BOM 优先；无 BOM 时先看 UTF-16 零字节分布，再做严格 UTF-8 校验，
/// 都不成立时以 Latin-1 兜底。
enum TextCodec {

    // MARK: - Decode

    /// BOM / 启发式探测并解码；无法按判定出的编码解码时返回 nil。
    static func decode(_ data: Data) -> DecodedText? {
        if data.isEmpty {
            return DecodedText(text: "", encoding: .utf8, bom: false, lineEnding: .lf)
        }
        let detection = detectEncoding(data)
        guard let text = decode(data, as: detection.encoding) else { return nil }
        return DecodedText(text: text,
                           encoding: detection.encoding,
                           bom: detection.bom,
                           lineEnding: detectLineEnding(text))
    }

    // MARK: - Encode

    /// 先按目标换行符归一化，再按指定编码 / BOM 输出；
    /// 目标编码无法表示（Latin-1 遇到非 Latin-1 字符）时返回 nil。
    static func encode(_ text: String,
                       encoding: TextEncodingKind,
                       bom: Bool,
                       lineEnding: LineEnding) -> Data? {
        let normalized = normalizeLineEndings(text, to: lineEnding)
        guard var data = normalized.data(using: stringEncoding(for: encoding),
                                         allowLossyConversion: false) else {
            return nil
        }
        if bom {
            switch encoding {
            case .utf8BOM:
                data.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0)
            case .utf16LE:
                data.insert(contentsOf: [0xFF, 0xFE], at: 0)
            case .utf16BE:
                data.insert(contentsOf: [0xFE, 0xFF], at: 0)
            case .utf8, .latin1:
                break
            }
        }
        return data
    }

    // MARK: - Detection

    private static func detectEncoding(_ data: Data) -> (encoding: TextEncodingKind, bom: Bool) {
        let prefix = [UInt8](data.prefix(3))
        if prefix.count >= 3, prefix[0] == 0xEF, prefix[1] == 0xBB, prefix[2] == 0xBF {
            return (.utf8BOM, true)
        }
        if prefix.count >= 2, prefix[0] == 0xFF, prefix[1] == 0xFE {
            return (.utf16LE, true)
        }
        if prefix.count >= 2, prefix[0] == 0xFE, prefix[1] == 0xFF {
            return (.utf16BE, true)
        }
        if data.count < 2 {
            return (.utf8, false)
        }
        // 无 BOM：NUL 分布启发式必须在严格 UTF-8 校验之前，
        // 否则纯 ASCII 的 UTF-16 无 BOM 文本会被当成合法 UTF-8（NUL 也是合法码点）。
        let sample = [UInt8](data.prefix(8192))
        let limit = sample.count / 2
        var leEvidence = 0
        var beEvidence = 0
        for pair in 0..<limit {
            let low = sample[pair * 2]
            let high = sample[pair * 2 + 1]
            if low != 0 && high == 0 { leEvidence += 1 }
            if low == 0 && high != 0 { beEvidence += 1 }
        }
        // 阈值至少 1：样本只有一对字节时不能凭「零个证据」判成 UTF-16。
        let threshold = max(limit / 2, 1)
        if leEvidence >= threshold || beEvidence >= threshold {
            return (beEvidence > leEvidence ? .utf16BE : .utf16LE, false)
        }
        if isValidUTF8(data) {
            return (.utf8, false)
        }
        return (.latin1, false)
    }

    private static func decode(_ data: Data, as encoding: TextEncodingKind) -> String? {
        let nsEncoding = stringEncoding(for: encoding)
        var string = String(data: data, encoding: nsEncoding)
        if string == nil, encoding == .utf16LE || encoding == .utf16BE, data.count > 1 {
            // 允许末尾截断的序列：丢掉末尾单字节再试。
            string = String(data: data.prefix(data.count & ~1), encoding: nsEncoding)
        }
        guard var result = string else { return nil }
        // UTF-8 BOM 解码后残留的 U+FEFF，以及 UTF-16 解码保留的 BOM 字符。
        if result.hasPrefix("\u{FEFF}") {
            result.removeFirst()
        }
        return result
    }

    private static func stringEncoding(for encoding: TextEncodingKind) -> String.Encoding {
        switch encoding {
        case .utf8, .utf8BOM: return .utf8
        case .utf16LE: return .utf16LittleEndian
        case .utf16BE: return .utf16BigEndian
        case .latin1: return .isoLatin1
        }
    }

    /// 严格 UTF-8 校验：拒绝过长编码、代理区、截断与非法续字节。
    private static func isValidUTF8(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            var index = 0
            while index < count {
                let byte = bytes[index]
                let continuationCount: Int
                var code: UInt32
                if byte < 0x80 {
                    index += 1
                    continue
                } else if byte & 0xE0 == 0xC0 {
                    continuationCount = 1
                    code = UInt32(byte & 0x1F)
                    if code < 2 { return false }
                } else if byte & 0xF0 == 0xE0 {
                    continuationCount = 2
                    code = UInt32(byte & 0x0F)
                } else if byte & 0xF8 == 0xF0 {
                    continuationCount = 3
                    code = UInt32(byte & 0x07)
                    if code > 4 { return false }
                } else {
                    return false
                }
                if index + continuationCount >= count { return false }
                for offset in 1...continuationCount {
                    let continuation = bytes[index + offset]
                    if continuation & 0xC0 != 0x80 { return false }
                    code = (code << 6) | UInt32(continuation & 0x3F)
                }
                if code >= 0xD800 && code <= 0xDFFF { return false }
                index += continuationCount + 1
            }
            return true
        }
    }

    /// 换行符统计：LF / CRLF / CR 取多数；并列按 LF > CRLF > CR；无换行返回 LF。
    private static func detectLineEnding(_ text: String) -> LineEnding {
        var lfCount = 0
        var crlfCount = 0
        var crCount = 0
        var pendingCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                if pendingCR { crlfCount += 1 } else { lfCount += 1 }
                pendingCR = false
            } else if scalar == "\r" {
                if pendingCR { crCount += 1 }
                pendingCR = true
            } else {
                if pendingCR { crCount += 1 }
                pendingCR = false
            }
        }
        if pendingCR { crCount += 1 }

        var best = LineEnding.lf
        var bestCount = lfCount
        if crlfCount > bestCount {
            best = .crlf
            bestCount = crlfCount
        }
        if crCount > bestCount {
            best = .cr
        }
        return best
    }

    private static func normalizeLineEndings(_ text: String, to lineEnding: LineEnding) -> String {
        var work = text.replacingOccurrences(of: "\r\n", with: "\n")
        work = work.replacingOccurrences(of: "\r", with: "\n")
        switch lineEnding {
        case .lf: return work
        case .crlf: return work.replacingOccurrences(of: "\n", with: "\r\n")
        case .cr: return work.replacingOccurrences(of: "\n", with: "\r")
        }
    }
}
