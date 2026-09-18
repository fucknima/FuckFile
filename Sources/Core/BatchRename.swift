import Foundation

/// 批量重命名名称引擎（纯 Foundation）：扩展名保留，主体名按规则改写。
/// 规则映射（对应 src/FFBatchRename.m 的能力子集）：
/// - useSequence 为真：`prefix` 作序号前缀，主体名 = prefix + 补零序号；
/// - 否则 find 非空：主体名 = 查找替换（大小写不敏感）；
/// - 否则：主体名 = prefix + 原名 + suffix。
enum BatchRename {

    struct Rule {
        var prefix: String
        var suffix: String
        var find: String
        var replace: String
        var useSequence: Bool
        var sequenceStart: Int
        var sequenceDigits: Int
    }

    struct BatchRenameItem {
        let path: String
        let oldName: String
        let newName: String
        let conflict: Bool
    }

    /// 生成新旧名；冲突（同批内重名、目标已存在、非法名）在这里标出，不抛错。
    static func plan(entries: [FileEntry], rule: Rule) -> [BatchRenameItem] {
        let digits = max(1, min(9, rule.sequenceDigits))
        let ownNames = Set(entries.map { $0.name.lowercased() })

        var candidates: [(entry: FileEntry, newName: String)] = []
        candidates.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            let (stem, fileExtension) = splitName(entry.name)
            let newStem: String
            if rule.useSequence {
                newStem = rule.prefix + padded(rule.sequenceStart + index, digits: digits)
            } else if !rule.find.isEmpty {
                newStem = stem.replacingOccurrences(of: rule.find, with: rule.replace,
                                                    options: .caseInsensitive)
            } else {
                newStem = rule.prefix + stem + rule.suffix
            }
            candidates.append((entry, newStem + fileExtension))
        }

        var counts: [String: Int] = [:]
        for candidate in candidates {
            counts[candidate.newName.lowercased(), default: 0] += 1
        }

        return candidates.map { candidate in
            let duplicate = (counts[candidate.newName.lowercased()] ?? 0) > 1
            let invalid = !isValidName(candidate.newName)
            let parent = (candidate.entry.path as NSString).deletingLastPathComponent
            let target = (parent as NSString).appendingPathComponent(candidate.newName)
            // 批内自己的旧名允许“让位”，不算目标已存在。
            let exists = !ownNames.contains(candidate.newName.lowercased())
                && FileManager.default.fileExists(atPath: target)
            return BatchRenameItem(path: candidate.entry.path,
                                   oldName: candidate.entry.name,
                                   newName: candidate.newName,
                                   conflict: duplicate || invalid || exists)
        }
    }

    /// 按 plan 逐个重命名；失败抛出底层错误，已完成的重命名保留。
    static func apply(plan: [BatchRenameItem]) throws {
        for item in plan where item.newName != item.oldName {
            _ = try FileOperations.renameItem(at: item.path, to: item.newName)
        }
    }

    // MARK: - 名称处理

    static func splitName(_ name: String) -> (stem: String, fileExtension: String) {
        // 以点开头的名字（如 .Trash）没有扩展名部分。
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            return (name, "")
        }
        return (String(name[..<dot]), String(name[dot...]))
    }

    static func isValidName(_ name: String) -> Bool {
        if name.isEmpty || name == "." || name == ".." { return false }
        if name.contains("/") || name.contains("\0") { return false }
        return name.lengthOfBytes(using: .utf8) <= 255
    }

    private static func padded(_ number: Int, digits: Int) -> String {
        String(format: "%0\(digits)ld", number)
    }
}
