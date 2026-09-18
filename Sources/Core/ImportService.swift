import Foundation

struct ImportResult {
    let success: Bool
    let sourcePath: String
    let destinationPath: String?
    let error: Error?
}

enum ImportError: LocalizedError {
    case invalidInput
    case copyFailed(String?)
    case commitFailed(String?)
    case noDestinationName
    case coordinationFailed(String?)

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "导入参数无效"
        case .copyFailed(let detail):
            return detail ?? "复制来源文件失败"
        case .commitFailed(let detail):
            return detail ?? "提交导入文件失败"
        case .noDestinationName:
            return "无法生成不冲突的目标文件名"
        case .coordinationFailed(let detail):
            return detail ?? "文件协调失败"
        }
    }
}

/// 外部 URL 导入核心：security scope + NSFileCoordinator 读取，
/// staging 复制后原子 move 提交；同步阻塞，调用方放后台。
enum ImportService {

    static func importURL(_ url: URL, displayName: String?, toDirectory directory: String) -> ImportResult {
        let sourcePath = url.path
        guard url.isFileURL, !sourcePath.isEmpty, !directory.isEmpty else {
            return ImportResult(success: false, sourcePath: sourcePath,
                                destinationPath: nil, error: ImportError.invalidInput)
        }

        let display = displayName.map { ($0 as NSString).lastPathComponent } ?? ""
        let name = !display.isEmpty
            ? display
            : (!url.lastPathComponent.isEmpty ? url.lastPathComponent : "imported")
        let staging = (directory as NSString).appendingPathComponent(".ffimport-\(UUID().uuidString)")

        var copied = false
        var copyError: Error?
        if pathInsideRoot(sourcePath, root: NSHomeDirectory()) {
            AppLog.tag("Import", "COPY direct src=\(sourcePath) staging=\(staging)")
            do {
                try FileManager.default.copyItem(atPath: sourcePath, toPath: staging)
                copied = true
            } catch {
                copyError = error
            }
        } else {
            let outcome = coordinatedCopy(url: url, staging: staging)
            copied = outcome.copied
            copyError = outcome.error
        }

        guard copied else {
            try? FileManager.default.removeItem(atPath: staging)
            let error = copyError ?? ImportError.copyFailed(nil)
            AppLog.tag("Import", "COPY FAIL src=\(sourcePath) error=\(error)")
            return ImportResult(success: false, sourcePath: sourcePath,
                                destinationPath: nil, error: error)
        }

        guard let destination = distinctDestination(name: name, directory: directory) else {
            try? FileManager.default.removeItem(atPath: staging)
            return ImportResult(success: false, sourcePath: sourcePath,
                                destinationPath: nil, error: ImportError.noDestinationName)
        }

        do {
            try FileManager.default.moveItem(atPath: staging, toPath: destination)
        } catch {
            try? FileManager.default.removeItem(atPath: staging)
            AppLog.tag("Import", "COMMIT FAIL staging=\(staging) dest=\(destination) error=\(error)")
            return ImportResult(success: false, sourcePath: sourcePath, destinationPath: nil,
                                error: ImportError.commitFailed(error.localizedDescription))
        }

        AppLog.tag("Import", "OK src=\(sourcePath) dest=\(destination)")
        return ImportResult(success: true, sourcePath: sourcePath,
                            destinationPath: destination, error: nil)
    }

    /// 非 App 容器内的来源：security scope + NSFileCoordinator 读取后再复制。
    private static func coordinatedCopy(url: URL, staging: String) -> (copied: Bool, error: Error?) {
        #if canImport(Darwin)
        let scoped = url.startAccessingSecurityScopedResource()
        AppLog.tag("Import", "COPY external scope=\(scoped) src=\(url.path)")

        var copied = false
        var copyError: Error?
        var accessorEntered = false
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: url,
                               options: [.withoutChanges],
                               error: &coordinationError) { coordinatedURL in
            accessorEntered = true
            AppLog.tag("Import", "COORDINATED COPY src=\(coordinatedURL.path) staging=\(staging)")
            do {
                try FileManager.default.copyItem(atPath: coordinatedURL.path, toPath: staging)
                copied = true
            } catch {
                copyError = error
            }
        }
        if scoped { url.stopAccessingSecurityScopedResource() }

        if copied { return (true, nil) }
        if let coordinationError {
            return (false, ImportError.coordinationFailed(coordinationError.localizedDescription))
        }
        if !accessorEntered {
            return (false, ImportError.coordinationFailed("系统没有提供可读取的文件 URL"))
        }
        return (false, copyError ?? ImportError.copyFailed(nil))
        #else
        AppLog.tag("Import", "COPY external src=\(url.path) staging=\(staging)")
        do {
            try FileManager.default.copyItem(atPath: url.path, toPath: staging)
            return (true, nil)
        } catch {
            return (false, error)
        }
        #endif
    }

    private static func pathInsideRoot(_ path: String, root: String) -> Bool {
        guard !path.isEmpty, !root.isEmpty else { return false }
        let candidate = (path as NSString).standardizingPath
        let base = (root as NSString).standardizingPath
        if candidate == base { return true }
        return candidate.hasPrefix(base + "/")
    }

    /// 重名唯一化：`name`、`name 2`、`name 3`…；超过上限返回 nil。
    private static func distinctDestination(name: String, directory: String) -> String? {
        let safeName = (name as NSString).lastPathComponent
        let finalName = safeName.isEmpty ? "imported" : safeName
        let first = (directory as NSString).appendingPathComponent(finalName)
        if !FileManager.default.fileExists(atPath: first) { return first }

        let fileExtension = (finalName as NSString).pathExtension
        let stem = (finalName as NSString).deletingPathExtension
        let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
        for index in 2..<10000 {
            let candidate = (directory as NSString)
                .appendingPathComponent("\(stem) \(index)\(suffix)")
            if !FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }
}
