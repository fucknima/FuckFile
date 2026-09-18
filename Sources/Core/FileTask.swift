import Foundation
#if canImport(Combine)
import Combine
#endif

enum FileTaskKind: String {
    case copy = "复制"
    case move = "移动"
    case trash = "删除"
    case extract = "解压"
    case compress = "压缩"
    case download = "下载"
}

enum FileTaskState: String {
    case queued = "排队中"
    case running = "进行中"
    case completed = "已完成"
    case failed = "失败"
    case cancelled = "已取消"
}

/// 统一任务模型：进度/状态只在主线程读写（FileTaskManager 负责派发）。
final class FileTask: ObservableObject, Identifiable {
    let id = UUID()
    let kind: FileTaskKind
    let displayName: String

    @Published var state: FileTaskState = .queued
    @Published var progress: Double = 0
    @Published var detail: String = ""
    @Published var errorText: String?
    @Published var isCancelled = false

    private let cancelLock = NSLock()
    private var cancelRequested = false

    /// 工作线程安全的取消标记（@Published 只能在主线程读写）。
    var cancelled: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return cancelRequested
    }

    init(kind: FileTaskKind, displayName: String) {
        self.kind = kind
        self.displayName = displayName
    }

    func cancel() {
        cancelLock.lock()
        cancelRequested = true
        cancelLock.unlock()
        DispatchQueue.main.async { self.isCancelled = true }
    }
}
