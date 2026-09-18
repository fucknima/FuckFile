import Foundation
#if canImport(Combine)
import Combine
#endif

/// 全局剪贴板状态：只记录路径与复制/剪切模式，不执行文件操作。
/// 粘贴成功后由集成方清理（剪切模式）并调用 `clear()`；路径失效时状态仍保留，
/// 缺失项由集成方在粘贴时处理。
final class ClipboardService: ObservableObject {
    static let shared = ClipboardService()

    enum Mode {
        case copy
        case cut
    }

    @Published private(set) var paths: [String] = []
    @Published private(set) var mode: Mode?

    var isEmpty: Bool { paths.isEmpty }
    var count: Int { paths.count }

    private init() {}

    func copy(_ paths: [String]) {
        set(paths, mode: .copy)
    }

    func cut(_ paths: [String]) {
        set(paths, mode: .cut)
    }

    func clear() {
        set([], mode: nil)
    }

    private func set(_ paths: [String], mode: Mode?) {
        var seen = Set<String>()
        let unique = paths.filter { seen.insert($0).inserted }
        onMain {
            self.paths = unique
            self.mode = unique.isEmpty ? nil : mode
        }
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}
