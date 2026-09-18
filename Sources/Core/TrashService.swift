import Foundation

struct TrashEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let originalPath: String
    let trashedAt: Date
    let isDirectory: Bool
    let size: UInt64
}

enum TrashServiceError: LocalizedError {
    case invalidPath(String)
    case sourceMissing(String)
    case createFailed(String)
    case metadataFailed(String)
    case moveFailed(String)
    case entryMissing(String)
    case restoreFailed(String)
    case removeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidPath(let message),
             .sourceMissing(let message),
             .createFailed(let message),
             .metadataFailed(let message),
             .moveFailed(let message),
             .entryMissing(let message),
             .restoreFailed(let message),
             .removeFailed(let message):
            return message
        }
    }
}

enum TrashService {
    static var trashRoot: String = (StorageEnvironment.documentsPath as NSString)
        .appendingPathComponent(".Trash")

    private static let metadataName = "item.plist"
    private static let payloadName = "payload"

    private struct ItemMetadata: Codable {
        let name: String
        let originalPath: String
        let trashedAt: Date
        let isDirectory: Bool
        let size: UInt64?
    }

    static func moveToTrash(_ path: String) throws -> TrashEntry {
        guard !path.isEmpty else {
            throw TrashServiceError.invalidPath("路径为空，无法移入回收站。")
        }
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw TrashServiceError.sourceMissing("文件不存在：\(path)")
        }
        guard !pathIsInsideTrash(path), !containsTrashRoot(path) else {
            throw TrashServiceError.invalidPath("不能把回收站或 Documents 根目录移入回收站。")
        }

        let name = (path as NSString).lastPathComponent
        let isDir = isDirectory.boolValue
        let size = itemSize(at: path, isDirectory: isDir)

        try ensureTrashRoot()

        let identifier = UUID().uuidString
        let itemDirectory = (trashRoot as NSString).appendingPathComponent(identifier)
        let payloadDirectory = (itemDirectory as NSString).appendingPathComponent(payloadName)
        let payloadPath = (payloadDirectory as NSString).appendingPathComponent(name)

        do {
            try manager.createDirectory(atPath: itemDirectory,
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        } catch {
            throw TrashServiceError.createFailed("无法创建回收站条目：\(error.localizedDescription)")
        }

        let entry = TrashEntry(id: identifier,
                               name: name,
                               originalPath: path,
                               trashedAt: Date(),
                               isDirectory: isDir,
                               size: size)
        do {
            try writeMetadata(entry, to: itemDirectory)
        } catch {
            returnPayloadIfNeeded(payloadPath: payloadPath, originalPath: path)
            try? manager.removeItem(atPath: itemDirectory)
            throw TrashServiceError.metadataFailed("无法写入回收站元数据：\(error.localizedDescription)")
        }

        do {
            try manager.createDirectory(atPath: payloadDirectory,
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.moveItem(atPath: path, toPath: payloadPath)
        } catch {
            try? manager.removeItem(atPath: itemDirectory)
            throw TrashServiceError.moveFailed("无法移入回收站：\(error.localizedDescription)")
        }

        AppLog.tag("Trash", "moved name=\(name) id=\(identifier)")
        return entry
    }

    static func entries() throws -> [TrashEntry] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: trashRoot) else { return [] }
        let children = (try? manager.contentsOfDirectory(atPath: trashRoot)) ?? []

        var result: [TrashEntry] = []
        result.reserveCapacity(children.count)
        for identifier in children where !identifier.hasPrefix(".") {
            let itemDirectory = (trashRoot as NSString).appendingPathComponent(identifier)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: itemDirectory, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let metadata = readMetadata(from: itemDirectory),
                  !metadata.name.isEmpty,
                  !metadata.name.contains("/") else { continue }

            let payloadDirectory = (itemDirectory as NSString).appendingPathComponent(payloadName)
            let payloadPath = (payloadDirectory as NSString).appendingPathComponent(metadata.name)
            guard manager.fileExists(atPath: payloadPath) else { continue }

            let size = metadata.size ?? itemSize(at: payloadPath, isDirectory: metadata.isDirectory)
            result.append(TrashEntry(id: identifier,
                                     name: metadata.name,
                                     originalPath: metadata.originalPath,
                                     trashedAt: metadata.trashedAt,
                                     isDirectory: metadata.isDirectory,
                                     size: size))
        }

        result.sort { left, right in
            if left.trashedAt != right.trashedAt { return left.trashedAt > right.trashedAt }
            return left.id > right.id
        }
        return result
    }

    static func restore(_ entry: TrashEntry) throws -> String {
        let manager = FileManager.default
        let itemDirectory = (trashRoot as NSString).appendingPathComponent(entry.id)
        let payloadDirectory = (itemDirectory as NSString).appendingPathComponent(payloadName)
        let payloadPath = (payloadDirectory as NSString).appendingPathComponent(entry.name)

        guard manager.fileExists(atPath: payloadPath) else {
            throw TrashServiceError.entryMissing("回收站条目已不存在：\(entry.name)")
        }

        let originalDirectory = (entry.originalPath as NSString).deletingLastPathComponent
        let directory: String
        if originalDirectory.isEmpty || !manager.fileExists(atPath: originalDirectory) {
            directory = (trashRoot as NSString).deletingLastPathComponent
        } else {
            directory = originalDirectory
        }

        let destination = uniqueDestination(in: directory, preferredName: entry.name)
        do {
            try manager.moveItem(atPath: payloadPath, toPath: destination)
        } catch {
            throw TrashServiceError.restoreFailed("无法恢复「\(entry.name)」：\(error.localizedDescription)")
        }

        try? manager.removeItem(atPath: itemDirectory)
        AppLog.tag("Trash", "restored name=\(entry.name) to=\(destination)")
        return destination
    }

    static func removePermanently(_ entry: TrashEntry) throws {
        let itemDirectory = (trashRoot as NSString).appendingPathComponent(entry.id)
        do {
            try FileManager.default.removeItem(atPath: itemDirectory)
        } catch {
            throw TrashServiceError.removeFailed("无法永久删除「\(entry.name)」：\(error.localizedDescription)")
        }
        AppLog.tag("Trash", "removed name=\(entry.name) id=\(entry.id)")
    }

    static func emptyTrash() throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: trashRoot) else { return }
        let children = (try? manager.contentsOfDirectory(atPath: trashRoot)) ?? []

        var firstError: Error?
        for name in children where !name.hasPrefix(".") {
            let path = (trashRoot as NSString).appendingPathComponent(name)
            do {
                try manager.removeItem(atPath: path)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let error = firstError {
            throw TrashServiceError.removeFailed("清空回收站时部分条目删除失败：\(error.localizedDescription)")
        }
        AppLog.tag("Trash", "emptied")
    }

    @discardableResult
    static func purgeExpired(olderThanDays days: Int) throws -> Int {
        guard days > 0 else { return 0 }
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 60 * 60)
        let candidates = try entries()

        var removed = 0
        var firstError: Error?
        for entry in candidates where entry.trashedAt < cutoff {
            do {
                try removePermanently(entry)
                removed += 1
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let error = firstError { throw error }
        AppLog.tag("Trash", "purged count=\(removed) days=\(days)")
        return removed
    }

    private static func ensureTrashRoot() throws {
        do {
            try FileManager.default.createDirectory(atPath: trashRoot,
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw TrashServiceError.createFailed("无法创建回收站目录：\(error.localizedDescription)")
        }
    }

    private static func writeMetadata(_ entry: TrashEntry, to itemDirectory: String) throws {
        let metadata = ItemMetadata(name: entry.name,
                                    originalPath: entry.originalPath,
                                    trashedAt: entry.trashedAt,
                                    isDirectory: entry.isDirectory,
                                    size: entry.size)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(metadata)
        let url = URL(fileURLWithPath: (itemDirectory as NSString).appendingPathComponent(metadataName))
        try data.write(to: url, options: .atomic)
    }

    private static func readMetadata(from itemDirectory: String) -> ItemMetadata? {
        let path = (itemDirectory as NSString).appendingPathComponent(metadataName)
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? PropertyListDecoder().decode(ItemMetadata.self, from: data)
    }

    private static func itemSize(at path: String, isDirectory: Bool) -> UInt64 {
        let manager = FileManager.default
        guard isDirectory else {
            let attributes = try? manager.attributesOfItem(atPath: path)
            return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        }

        var total: UInt64 = 0
        guard let enumerator = manager.enumerator(atPath: path) else { return 0 }
        for case let child as String in enumerator {
            let childPath = (path as NSString).appendingPathComponent(child)
            guard let attributes = try? manager.attributesOfItem(atPath: childPath) else { continue }
            if (attributes[.type] as? FileAttributeType) == .typeDirectory { continue }
            total += (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        }
        return total
    }

    private static func uniqueDestination(in directory: String, preferredName: String) -> String {
        let manager = FileManager.default
        let preferred = (directory as NSString).appendingPathComponent(preferredName)
        if !manager.fileExists(atPath: preferred) { return preferred }

        let name = preferredName as NSString
        let stem = name.deletingPathExtension
        let ext = name.pathExtension
        for index in 2..<10000 {
            var candidate = "\(stem) \(index)"
            if !ext.isEmpty { candidate += ".\(ext)" }
            let path = (directory as NSString).appendingPathComponent(candidate)
            if !manager.fileExists(atPath: path) { return path }
        }
        return (directory as NSString).appendingPathComponent("\(stem) \(UUID().uuidString)")
    }

    private static func pathIsInsideTrash(_ path: String) -> Bool {
        let candidate = (path as NSString).standardizingPath
        let root = (trashRoot as NSString).standardizingPath
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    private static func containsTrashRoot(_ path: String) -> Bool {
        let candidate = (path as NSString).standardizingPath
        let root = (trashRoot as NSString).standardizingPath
        return candidate == "/" || root.hasPrefix(candidate + "/")
    }

    private static func returnPayloadIfNeeded(payloadPath: String, originalPath: String) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: payloadPath) else { return }
        try? manager.moveItem(atPath: payloadPath, toPath: originalPath)
    }
}
