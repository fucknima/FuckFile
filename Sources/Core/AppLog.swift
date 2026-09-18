import Foundation

/// 与 Objective-C 版共用同一份日志文件（tmp/FuckFile/Diagnostics/FuckFile Log.txt），
/// 真机排障与「运行日志」页的习惯保持不变。
enum AppLog {
    private static let queue = DispatchQueue(label: "ff.log")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static var logURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FuckFile", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("FuckFile Log.txt")
    }

    static func info(_ message: String) {
        write(tag: "FuckFile", message)
    }

    static func tag(_ tag: String, _ message: String) {
        write(tag: tag, message)
    }

    /// 读取日志尾部（供日志页显示）。
    static func tail(maxBytes: Int = 128 * 1024) -> String {
        guard let data = try? Data(contentsOf: logURL) else { return "" }
        return String(decoding: data.suffix(maxBytes), as: UTF8.self)
    }

    private static func write(tag: String, _ message: String) {
        queue.async {
            let line = "[\(formatter.string(from: Date()))] [\(tag)] \(message)\n"
            let url = logURL
            let directory = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true)
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
