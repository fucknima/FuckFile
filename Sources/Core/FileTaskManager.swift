import Foundation
#if canImport(Combine)
import Combine
#endif

/// 串行任务执行器：操作在后台队列跑，模型状态统一回主线程更新。
/// 具体执行体（复制/移动/解压…）在阶段 2 接入，这里先把队列/取消/状态打通。
final class FileTaskManager: ObservableObject {
    static let shared = FileTaskManager()

    @Published private(set) var tasks: [FileTask] = []

    private let workQueue = DispatchQueue(label: "ff.tasks", qos: .userInitiated)

    @discardableResult
    func enqueue(kind: FileTaskKind,
                 displayName: String,
                 operation: @escaping (FileTask) throws -> Void,
                 completion: ((FileTask) -> Void)? = nil) -> FileTask {
        let task = FileTask(kind: kind, displayName: displayName)
        onMain { self.tasks.insert(task, at: 0) }
        workQueue.async { [weak self] in
            self?.run(task, operation: operation, completion: completion)
        }
        return task
    }

    func remove(_ task: FileTask) {
        onMain { self.tasks.removeAll { $0 === task } }
    }

    func removeFinished() {
        onMain {
            self.tasks.removeAll { task in
                task.state == .completed || task.state == .failed || task.state == .cancelled
            }
        }
    }

    private func run(_ task: FileTask,
                     operation: (FileTask) throws -> Void,
                     completion: ((FileTask) -> Void)?) {
        onMain { task.state = .running }
        do {
            try operation(task)
            onMain {
                if task.isCancelled {
                    task.state = .cancelled
                } else {
                    task.state = .completed
                    task.progress = 1
                }
                completion?(task)
            }
        } catch {
            onMain {
                task.state = task.isCancelled ? .cancelled : .failed
                task.errorText = error.localizedDescription
                completion?(task)
            }
            AppLog.tag("Tasks", "failed \(task.displayName): \(error.localizedDescription)")
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
