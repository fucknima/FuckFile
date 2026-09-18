import Foundation
#if canImport(Combine)
import Combine
#endif

extension Notification.Name {
    /// 文件操作任务完成/失败后广播；浏览器据此刷新列表。
    static let fileActionsDidChange = Notification.Name("FFFileActionsDidChange")
}

/// 浏览器动作统一入口（阶段 2 冻结接口，C 只调用这里）：
/// 冲突询问 → 入任务队列 → 执行 FileOperations/TrashService → 广播刷新。
@MainActor
final class FileActions: ObservableObject {
    static let shared = FileActions()

    struct ConflictRequest: Identifiable {
        let id = UUID()
        let name: String
        let isDirectory: Bool
        let completion: (FileConflictPolicy) -> Void
    }

    @Published var conflictRequest: ConflictRequest?
    @Published var errorMessage: String?

    private init() {}

    // MARK: - 冻结 API

    func copy(_ entries: [FileEntry], toDirectory directory: String) {
        transfer(entries, toDirectory: directory, kind: .copy)
    }

    func move(_ entries: [FileEntry], toDirectory directory: String) {
        transfer(entries, toDirectory: directory, kind: .move)
    }

    func trash(_ entries: [FileEntry]) {
        guard !entries.isEmpty else { return }
        FileTaskManager.shared.enqueue(kind: .trash,
                                       displayName: "删除 \(entries.count) 项") { task in
            for entry in entries {
                if task.cancelled { throw FileOperationError.cancelled }
                _ = try TrashService.moveToTrash(entry.path)
            }
        } completion: { [weak self] _ in
            self?.postChange()
        }
    }

    func rename(_ entry: FileEntry, to newName: String) {
        FileTaskManager.shared.enqueue(kind: .move,
                                       displayName: "重命名 \(entry.name)") { _ in
            _ = try FileOperations.renameItem(at: entry.path, to: newName)
        } completion: { [weak self] _ in
            self?.postChange()
        }
    }

    func createFolder(named name: String, inDirectory directory: String) {
        do {
            _ = try FileOperations.createFolder(named: name, in: directory)
            postChange()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createFile(named name: String, inDirectory directory: String) {
        do {
            _ = try FileOperations.createFile(named: name, in: directory)
            postChange()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 内部

    private func transfer(_ entries: [FileEntry],
                          toDirectory directory: String,
                          kind: FileTaskKind) {
        guard !entries.isEmpty else { return }
        let conflicting = entries.filter {
            FileOperations.destinationExists(in: directory, name: $0.name)
        }
        guard let first = conflicting.first else {
            enqueueTransfer(entries, toDirectory: directory, kind: kind, policy: .keepBoth)
            return
        }
        // 一次询问应用到本批全部同名项（阶段 2 约定）。
        askConflict(name: first.name, isDirectory: first.isDirectory) { [weak self] policy in
            self?.enqueueTransfer(entries, toDirectory: directory, kind: kind, policy: policy)
        }
    }

    private func askConflict(name: String,
                             isDirectory: Bool,
                             completion: @escaping (FileConflictPolicy) -> Void) {
        conflictRequest = ConflictRequest(name: name,
                                          isDirectory: isDirectory) { [weak self] policy in
            self?.conflictRequest = nil
            completion(policy)
        }
    }

    private func enqueueTransfer(_ entries: [FileEntry],
                                 toDirectory directory: String,
                                 kind: FileTaskKind,
                                 policy: FileConflictPolicy) {
        let displayName = "\(kind.rawValue) \(entries.count) 项"
        FileTaskManager.shared.enqueue(kind: kind, displayName: displayName) { task in
            let total = max(entries.count, 1)
            for (index, entry) in entries.enumerated() {
                if task.cancelled { throw FileOperationError.cancelled }
                let progress: (Double) -> Void = { value in
                    let overall = (Double(index) + min(max(value, 0), 1)) / Double(total)
                    DispatchQueue.main.async { task.progress = min(max(overall, 0), 1) }
                }
                let cancel: () -> Bool = { task.cancelled }
                switch kind {
                case .copy:
                    _ = try FileOperations.copyItem(at: entry.path,
                                                    toDirectory: directory,
                                                    conflict: policy,
                                                    progress: progress,
                                                    shouldCancel: cancel)
                case .move:
                    _ = try FileOperations.moveItem(at: entry.path,
                                                    toDirectory: directory,
                                                    conflict: policy,
                                                    progress: progress,
                                                    shouldCancel: cancel)
                default:
                    break
                }
            }
        } completion: { [weak self] _ in
            self?.postChange()
        }
    }

    private func postChange() {
        NotificationCenter.default.post(name: .fileActionsDidChange, object: nil)
    }
}
