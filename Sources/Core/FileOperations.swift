import Foundation

enum FileOperationError: LocalizedError {
    case invalidPath(String)
    case sourceMissing(String)
    case nameConflict(String)
    case copyFailed(String)
    case moveFailed(String)
    case removeFailed(String)
    case renameFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidPath(let message),
             .sourceMissing(let message),
             .nameConflict(let message),
             .copyFailed(let message),
             .moveFailed(let message),
             .removeFailed(let message),
             .renameFailed(let message):
            return message
        case .cancelled:
            return "操作已取消"
        }
    }
}

enum FileOperations {

    static func uniqueDestination(in directory: String, preferredName: String) -> String {
        let name = preferredName.isEmpty ? "未命名" : preferredName
        var candidate = (directory as NSString).appendingPathComponent(name)
        if !itemExists(candidate) { return candidate }

        let fileExtension = (name as NSString).pathExtension
        let stem = fileExtension.isEmpty ? name : (name as NSString).deletingPathExtension
        var index = 2
        while true {
            var candidateName = stem + " \(index)"
            if !fileExtension.isEmpty {
                candidateName += "." + fileExtension
            }
            candidate = (directory as NSString).appendingPathComponent(candidateName)
            if !itemExists(candidate) { return candidate }
            index += 1
        }
    }

    static func destinationExists(in directory: String, name: String) -> Bool {
        itemExists((directory as NSString).appendingPathComponent(name))
    }

    @discardableResult
    static func copyItem(at source: String, toDirectory directory: String,
                         conflict: FileConflictPolicy,
                         progress: ((Double) -> Void)?,
                         shouldCancel: (() -> Bool)?) throws -> String {
        guard itemExists(source) else {
            throw FileOperationError.sourceMissing("源文件不存在：\(source)")
        }
        guard isDirectory(at: directory) else {
            throw FileOperationError.invalidPath("目标目录不存在：\(directory)")
        }
        let name = (source as NSString).lastPathComponent
        guard isValidItemName(name) else {
            throw FileOperationError.invalidPath("源路径不合法：\(source)")
        }

        var destination = (directory as NSString).appendingPathComponent(name)
        var replacing = false
        if itemExists(destination) {
            switch conflict {
            case .skip:
                progress?(1)
                return destination
            case .replace:
                replacing = true
            case .ask, .keepBoth:
                destination = uniqueDestination(in: directory, preferredName: name)
            }
        }

        if normalizedPath(source) == normalizedPath(destination) {
            throw FileOperationError.invalidPath("源和目标相同：\(source)")
        }
        if itemType(at: source) == mode_t(S_IFDIR) {
            let sourcePath = normalizedPath(source)
            let destinationPath = normalizedPath(destination)
            if destinationPath.hasPrefix(sourcePath + "/") {
                throw FileOperationError.invalidPath("不能把文件夹复制到自身内部：\(destination)")
            }
        }

        let total = countItems(at: source)
        var completed = 0
        var backupPath: String?

        do {
            if replacing {
                backupPath = try stageBackup(of: destination) {
                    FileOperationError.copyFailed($0)
                }
            }
            try copyTree(at: source, to: destination, total: total,
                         completed: &completed, progress: progress,
                         shouldCancel: shouldCancel)
            if let backupPath {
                try? FileManager.default.removeItem(atPath: backupPath)
            }
            return destination
        } catch {
            removeIfExists(destination)
            if let backupPath {
                do {
                    try FileManager.default.moveItem(atPath: backupPath, toPath: destination)
                } catch let rollbackError {
                    throw FileOperationError.copyFailed(
                        "替换失败且回滚失败。原目标仍保存在：\(backupPath)。回滚错误：\(rollbackError.localizedDescription)")
                }
            }
            throw error
        }
    }

    @discardableResult
    static func moveItem(at source: String, toDirectory directory: String,
                         conflict: FileConflictPolicy,
                         progress: ((Double) -> Void)?,
                         shouldCancel: (() -> Bool)?) throws -> String {
        guard itemExists(source) else {
            throw FileOperationError.sourceMissing("源文件不存在：\(source)")
        }
        guard isDirectory(at: directory) else {
            throw FileOperationError.invalidPath("目标目录不存在：\(directory)")
        }
        let name = (source as NSString).lastPathComponent
        guard isValidItemName(name) else {
            throw FileOperationError.invalidPath("源路径不合法：\(source)")
        }

        var destination = (directory as NSString).appendingPathComponent(name)
        var replacing = false
        if itemExists(destination) {
            switch conflict {
            case .skip:
                progress?(1)
                return destination
            case .replace:
                replacing = true
            case .ask, .keepBoth:
                destination = uniqueDestination(in: directory, preferredName: name)
            }
        }

        if shouldCancel?() == true {
            throw FileOperationError.cancelled
        }

        if rename(source, destination) == 0 {
            progress?(1)
            return destination
        }
        let saved = errno

        if saved == EXDEV {
            let copied = try copyItem(at: source, toDirectory: directory,
                                      conflict: conflict, progress: progress,
                                      shouldCancel: shouldCancel)
            if shouldCancel?() == true {
                throw FileOperationError.cancelled
            }
            do {
                try removeItem(at: source)
            } catch {
                throw FileOperationError.moveFailed("已复制到 \(copied)，但无法删除源：\(source)")
            }
            return copied
        }

        if replacing && (saved == ENOTEMPTY || saved == EEXIST || saved == EISDIR || saved == ENOTDIR) {
            try replaceDestinationByMoving(source: source, destination: destination)
            progress?(1)
            return destination
        }

        throw FileOperationError.moveFailed("移动失败：\(source) → \(destination)")
    }

    static func removeItem(at path: String) throws {
        guard !path.isEmpty else {
            throw FileOperationError.invalidPath("路径不合法：\(path)")
        }
        guard itemExists(path) else {
            throw FileOperationError.sourceMissing("源文件不存在：\(path)")
        }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            throw FileOperationError.removeFailed("删除失败：\(path)：\(error.localizedDescription)")
        }
    }

    @discardableResult
    static func renameItem(at path: String, to newName: String) throws -> String {
        guard isValidNewName(newName) else {
            throw FileOperationError.invalidPath("名称不合法：\(newName)")
        }
        guard itemExists(path) else {
            throw FileOperationError.sourceMissing("源文件不存在：\(path)")
        }
        let parent = (path as NSString).deletingLastPathComponent
        let destination = (parent as NSString).appendingPathComponent(newName)
        if itemExists(destination) {
            throw FileOperationError.nameConflict("目标已存在：\(newName)")
        }
        do {
            try FileManager.default.moveItem(atPath: path, toPath: destination)
        } catch {
            throw FileOperationError.renameFailed(
                "重命名失败：\(path) → \(destination)：\(error.localizedDescription)")
        }
        return destination
    }

    @discardableResult
    static func createFolder(named name: String, in directory: String) throws -> String {
        let path = try creationPath(named: name, in: directory)
        do {
            try FileManager.default.createDirectory(atPath: path,
                                                    withIntermediateDirectories: false)
        } catch {
            throw FileOperationError.copyFailed(
                "创建文件夹失败：\(path)：\(error.localizedDescription)")
        }
        return path
    }

    @discardableResult
    static func createFile(named name: String, in directory: String) throws -> String {
        let path = try creationPath(named: name, in: directory)
        guard FileManager.default.createFile(atPath: path, contents: nil) else {
            throw FileOperationError.copyFailed("创建文件失败：\(path)")
        }
        return path
    }

    private static func creationPath(named name: String, in directory: String) throws -> String {
        guard isValidNewName(name) else {
            throw FileOperationError.invalidPath("名称不合法：\(name)")
        }
        guard isDirectory(at: directory) else {
            throw FileOperationError.invalidPath("目标目录不存在：\(directory)")
        }
        return uniqueDestination(in: directory, preferredName: name)
    }

    private static func copyTree(at source: String, to destination: String,
                                 total: Int, completed: inout Int,
                                 progress: ((Double) -> Void)?,
                                 shouldCancel: (() -> Bool)?) throws {
        if shouldCancel?() == true {
            throw FileOperationError.cancelled
        }

        let type = itemType(at: source)
        let manager = FileManager.default

        if type == mode_t(S_IFLNK) {
            do {
                let linkTarget = try manager.destinationOfSymbolicLink(atPath: source)
                try manager.createSymbolicLink(atPath: destination,
                                               withDestinationPath: linkTarget)
            } catch {
                throw FileOperationError.copyFailed(
                    "复制失败：符号链接 \(source)：\(error.localizedDescription)")
            }
        } else if type == mode_t(S_IFDIR) {
            do {
                try manager.createDirectory(atPath: destination,
                                            withIntermediateDirectories: false)
            } catch {
                throw FileOperationError.copyFailed(
                    "复制失败：无法创建目录 \(destination)：\(error.localizedDescription)")
            }
            let names: [String]
            do {
                names = try manager.contentsOfDirectory(atPath: source)
            } catch {
                throw FileOperationError.copyFailed(
                    "复制失败：无法读取目录 \(source)：\(error.localizedDescription)")
            }
            for name in names {
                if shouldCancel?() == true {
                    throw FileOperationError.cancelled
                }
                let childSource = (source as NSString).appendingPathComponent(name)
                let childDestination = (destination as NSString).appendingPathComponent(name)
                try copyTree(at: childSource, to: childDestination, total: total,
                             completed: &completed, progress: progress,
                             shouldCancel: shouldCancel)
            }
        } else if type == mode_t(S_IFREG) {
            do {
                try manager.copyItem(atPath: source, toPath: destination)
            } catch {
                throw FileOperationError.copyFailed(
                    "复制失败：\(source) → \(destination)：\(error.localizedDescription)")
            }
        } else {
            throw FileOperationError.copyFailed("复制失败：不支持的文件类型：\(source)")
        }

        completed += 1
        progress?(total > 0 ? Double(completed) / Double(total) : 1)
    }

    private static func countItems(at path: String) -> Int {
        let type = itemType(at: path)
        if type == 0 { return 0 }
        if type == mode_t(S_IFDIR) {
            var count = 1
            if let names = try? FileManager.default.contentsOfDirectory(atPath: path) {
                for name in names {
                    count += countItems(at: (path as NSString).appendingPathComponent(name))
                }
            }
            return count
        }
        return 1
    }

    private static func replaceDestinationByMoving(source: String, destination: String) throws {
        let backupPath = try stageBackup(of: destination) {
            FileOperationError.moveFailed($0)
        }
        if rename(source, destination) == 0 {
            try? FileManager.default.removeItem(atPath: backupPath)
            return
        }
        let failure = FileOperationError.moveFailed("移动失败：\(source) → \(destination)")
        removeIfExists(destination)
        do {
            try FileManager.default.moveItem(atPath: backupPath, toPath: destination)
        } catch let rollbackError {
            throw FileOperationError.moveFailed(
                "替换失败且回滚失败。原目标仍保存在：\(backupPath)。回滚错误：\(rollbackError.localizedDescription)")
        }
        throw failure
    }

    private static func stageBackup(of path: String,
                                    error makeError: (String) -> FileOperationError) throws -> String {
        let backupPath = path + ".old" + String(UUID().uuidString.prefix(8))
        do {
            try FileManager.default.moveItem(atPath: path, toPath: backupPath)
        } catch {
            throw makeError("无法暂存原目标：\(path)：\(error.localizedDescription)")
        }
        return backupPath
    }

    private static func removeIfExists(_ path: String) {
        guard itemExists(path) else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    private static func itemExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private static func itemType(at path: String) -> mode_t {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        return info.st_mode & mode_t(S_IFMT)
    }

    private static func isDirectory(at path: String) -> Bool {
        var isDirectoryFlag: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectoryFlag)
            && isDirectoryFlag.boolValue
    }

    private static func isValidItemName(_ name: String) -> Bool {
        if name.isEmpty || name == "/" || name == "." || name == ".." { return false }
        return !name.contains("/")
    }

    private static func isValidNewName(_ name: String) -> Bool {
        guard isValidItemName(name) else { return false }
        return !name.contains(":") && !name.contains("\0")
    }

    private static func normalizedPath(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        if standardized.count > 1 && standardized.hasSuffix("/") {
            return String(standardized.dropLast())
        }
        return standardized
    }
}
