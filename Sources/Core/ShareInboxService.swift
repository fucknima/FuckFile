import Foundation

struct SharedImportOutcome {
    var imported: Int = 0
    var destinations: [String] = []
    var errors: [Error] = []
}

enum ShareInboxError: LocalizedError {
    case invalidPayload(String)

    var errorDescription: String? {
        switch self {
        case .invalidPayload(let name):
            return "共享收件箱缺少有效 payload：\(name)"
        }
    }
}

/// 共享收件箱消费：扫描 App Group（+ App 自身 Documents 兜底），
/// 每个完整条目经 ImportService 导入 Documents/Imported，成功删条目、失败保留。
enum ShareInboxService {

    static let appGroupIdentifier = "group.com.fucknima.fuckfile"
    static let inboxDirectoryName = "FuckFileShareInbox"
    static let itemSuffix = ".ffshare"

    /// 扩展直传进行中条目的宽限期：此窗口内不抢非 App Group 路径的条目。
    private static let recoveryDelay: TimeInterval = 180
    private static let queue = DispatchQueue(label: "ff.shared-inbox")

    private struct InboxItem {
        let root: String
        let name: String
        let directory: String
        let payloadPath: String
        let metadata: [String: Any]
        let created: Date?
    }

    /// App Group 收件箱路径；无 group 权限返回 nil。
    static var appGroupInboxPath: String? {
        #if canImport(Darwin)
        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier),
            !groupURL.path.isEmpty else { return nil }
        return (groupURL.path as NSString).appendingPathComponent(inboxDirectoryName)
        #else
        return nil
        #endif
    }

    static func processPending() async -> SharedImportOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<SharedImportOutcome, Never>) in
            queue.async {
                continuation.resume(returning: processPendingSync())
            }
        }
    }

    private static func processPendingSync() -> SharedImportOutcome {
        var outcome = SharedImportOutcome()
        let destinationDirectory = importedDirectoryPath()
        do {
            try FileManager.default.createDirectory(atPath: destinationDirectory,
                                                    withIntermediateDirectories: true)
        } catch {
            outcome.errors.append(error)
        }

        let groupInboxPath = appGroupInboxPath
        for item in pendingItems() {
            if shouldDeferExtensionRecovery(metadata: item.metadata,
                                            root: item.root,
                                            groupInboxPath: groupInboxPath) {
                AppLog.tag("ShareInbox", "defer active stream item=\(item.name) session=\(item.metadata["session"] ?? "?")")
                continue
            }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: item.payloadPath, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                outcome.errors.append(ShareInboxError.invalidPayload(item.name))
                AppLog.tag("ShareInbox", "invalid item=\(item.directory)")
                continue
            }

            let originalName = (item.metadata["name"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 } ?? "imported"
            AppLog.tag("ShareInbox", "consume item=\(item.name) name=\(originalName)")

            let result = ImportService.importURL(URL(fileURLWithPath: item.payloadPath),
                                                 displayName: originalName,
                                                 toDirectory: destinationDirectory)
            if result.success {
                if let destination = result.destinationPath {
                    outcome.destinations.append(destination)
                }
                do {
                    try FileManager.default.removeItem(atPath: item.directory)
                    AppLog.tag("ShareInbox", "cleanup OK item=\(item.directory)")
                } catch {
                    outcome.errors.append(error)
                    AppLog.tag("ShareInbox", "cleanup FAIL item=\(item.directory) error=\(error)")
                }
            } else if let error = result.error {
                outcome.errors.append(error)
                AppLog.tag("ShareInbox", "import FAIL item=\(item.directory) error=\(error)")
            }
        }

        outcome.imported = outcome.destinations.count
        return outcome
    }

    private static func candidateInboxRoots() -> [String] {
        var roots: [String] = []
        if let groupInbox = appGroupInboxPath {
            roots.append(groupInbox)
            AppLog.tag("ShareInbox", "bridge app-group=\(groupInbox)")
        } else {
            AppLog.tag("ShareInbox", "app-group unavailable")
        }
        let fallback = (StorageEnvironment.documentsPath as NSString)
            .appendingPathComponent(inboxDirectoryName)
        if !roots.contains(fallback) { roots.append(fallback) }
        return roots
    }

    private static func pendingItems() -> [InboxItem] {
        var items: [InboxItem] = []
        for root in candidateInboxRoots() {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else {
                continue
            }
            for name in names {
                guard name.hasSuffix(itemSuffix), !name.hasPrefix(".partial-") else { continue }
                let directory = (root as NSString).appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }

                let metadataPath = (directory as NSString).appendingPathComponent("metadata.plist")
                let metadata = readMetadata(atPath: metadataPath)
                items.append(InboxItem(
                    root: root,
                    name: name,
                    directory: directory,
                    payloadPath: (directory as NSString).appendingPathComponent("payload"),
                    metadata: metadata,
                    created: metadata["created"] as? Date
                ))
            }
        }
        items.sort { left, right in
            let leftDate = left.created ?? .distantPast
            let rightDate = right.created ?? .distantPast
            if leftDate != rightDate { return leftDate < rightDate }
            return left.name < right.name
        }
        return items
    }

    /// 非 App Group 路径、session 非空且 created 在 180s 内 → 跳过，
    /// 让分享扩展的直传先完成，避免抢文件（对齐 ObjC）。
    private static func shouldDeferExtensionRecovery(metadata: [String: Any],
                                                     root: String,
                                                     groupInboxPath: String?) -> Bool {
        if let groupInboxPath,
           (root as NSString).standardizingPath == (groupInboxPath as NSString).standardizingPath {
            return false
        }
        guard let session = metadata["session"] as? String, !session.isEmpty,
              let created = metadata["created"] as? Date else { return false }
        let age = Date().timeIntervalSince(created)
        return age >= 0 && age < recoveryDelay
    }

    private static func readMetadata(atPath path: String) -> [String: Any] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let plist = try? PropertyListSerialization.propertyList(from: data,
                                                                      options: [],
                                                                      format: nil),
              let metadata = plist as? [String: Any] else { return [:] }
        return metadata
    }

    private static func importedDirectoryPath() -> String {
        (StorageEnvironment.documentsPath as NSString).appendingPathComponent("Imported")
    }
}
