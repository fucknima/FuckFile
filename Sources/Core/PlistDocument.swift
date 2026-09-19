import Foundation
import CoreFoundation

/// plist 路径组件：字典键或数组下标。
enum PlistPathComponent: Hashable {
    case key(String)
    case index(Int)
}

typealias PlistPath = [PlistPathComponent]

extension PlistPath {
    /// 与 ObjC 版 pathStringForKeyPath 一致：Root.foo[0]。
    var displayString: String {
        var result = "Root"
        for component in self {
            switch component {
            case .key(let key): result += ".\(key)"
            case .index(let index): result += "[\(index)]"
            }
        }
        return result
    }
}

/// plist 值树：显式区分布尔/整数/实数，避免 NSNumber 往返桥接丢失类型。
indirect enum PlistValue: Equatable {
    case string(String)
    case integer(Int64)
    case real(Double)
    case boolean(Bool)
    case date(Date)
    case data(Data)
    case array([PlistValue])
    case dictionary([String: PlistValue])

    var isContainer: Bool {
        switch self {
        case .array, .dictionary: return true
        default: return false
        }
    }

    var typeName: String {
        switch self {
        case .dictionary: return "字典"
        case .array: return "数组"
        case .string: return "字符串"
        case .data: return "数据"
        case .date: return "日期"
        case .boolean: return "布尔"
        case .integer: return "整数"
        case .real: return "实数"
        }
    }

    /// 与 ObjC 版 FFPlistValueSummary 一致的列表摘要。
    var summary: String {
        switch self {
        case .dictionary(let values): return "\(values.count) 项"
        case .array(let values): return "\(values.count) 项"
        case .boolean(let value): return value ? "YES" : "NO"
        case .string(let value):
            let oneLine = value.replacingOccurrences(of: "\n", with: " ↵ ")
            if oneLine.count > 120 {
                return String(oneLine.prefix(117)) + "…"
            }
            return oneLine.isEmpty ? "空字符串" : oneLine
        case .data(let value):
            return ByteCountFormatter.string(fromByteCount: Int64(value.count),
                                             countStyle: .memory)
        case .date(let value):
            return PlistFormatting.dateFormatter.string(from: value)
        case .integer(let value):
            return String(value)
        case .real(let value):
            return String(value)
        }
    }

    /// 转回 PropertyListSerialization 可接受的对象图。
    var propertyListObject: Any {
        switch self {
        case .string(let value): return value
        case .integer(let value): return NSNumber(value: value)
        case .real(let value): return NSNumber(value: value)
        case .boolean(let value): return NSNumber(value: value)
        case .date(let value): return value
        case .data(let value): return value
        case .array(let values): return values.map { $0.propertyListObject }
        case .dictionary(let values): return values.mapValues { $0.propertyListObject }
        }
    }

    /// 把 PropertyListSerialization 的结果转成显式值树；出现未知类型返回 nil。
    static func from(_ object: Any) -> PlistValue? {
        switch object {
        case let value as String:
            return .string(value)
        case let value as Date:
            return .date(value)
        case let value as Data:
            return .data(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .boolean(value.boolValue)
            }
            let numberType = String(cString: value.objCType)
            if numberType == "f" || numberType == "d" {
                return .real(value.doubleValue)
            }
            return .integer(value.int64Value)
        case let value as [Any]:
            var items: [PlistValue] = []
            items.reserveCapacity(value.count)
            for item in value {
                guard let converted = PlistValue.from(item) else { return nil }
                items.append(converted)
            }
            return .array(items)
        case let value as [String: Any]:
            var items: [String: PlistValue] = [:]
            items.reserveCapacity(value.count)
            for (key, item) in value {
                guard let converted = PlistValue.from(item) else { return nil }
                items[key] = converted
            }
            return .dictionary(items)
        default:
            // NSKeyedArchiver 的 CF$UID 等非标准 plist 对象：不让整份文档失败，
            // 以只读文本形式展示（用户至少能看到结构）。
            let description = String(describing: object)
            return description.isEmpty ? nil : .string(description)
        }
    }

    func value(at path: PlistPath) -> PlistValue? {
        guard let first = path.first else { return self }
        let rest = Array(path.dropFirst())
        switch (self, first) {
        case (.dictionary(let values), .key(let key)):
            return values[key]?.value(at: rest)
        case (.array(let values), .index(let index)):
            guard values.indices.contains(index) else { return nil }
            return values[index].value(at: rest)
        default:
            return nil
        }
    }

    mutating func setValue(_ newValue: PlistValue, at path: PlistPath) -> Bool {
        guard let first = path.first else {
            self = newValue
            return true
        }
        let rest = Array(path.dropFirst())
        switch (self, first) {
        case (.dictionary(var values), .key(let key)):
            guard var child = values[key], child.setValue(newValue, at: rest) else { return false }
            values[key] = child
            self = .dictionary(values)
            return true
        case (.array(var values), .index(let index)):
            guard values.indices.contains(index) else { return false }
            var child = values[index]
            guard child.setValue(newValue, at: rest) else { return false }
            values[index] = child
            self = .array(values)
            return true
        default:
            return false
        }
    }

    /// 不允许删除根节点。
    mutating func removeValue(at path: PlistPath) -> Bool {
        guard let first = path.first else { return false }
        let rest = Array(path.dropFirst())
        switch (self, first) {
        case (.dictionary(var values), .key(let key)):
            if rest.isEmpty {
                guard values.removeValue(forKey: key) != nil else { return false }
            } else {
                guard var child = values[key], child.removeValue(at: rest) else { return false }
                values[key] = child
            }
            self = .dictionary(values)
            return true
        case (.array(var values), .index(let index)):
            guard values.indices.contains(index) else { return false }
            if rest.isEmpty {
                values.remove(at: index)
            } else {
                var child = values[index]
                guard child.removeValue(at: rest) else { return false }
                values[index] = child
            }
            self = .array(values)
            return true
        default:
            return false
        }
    }

    /// 字典要求非空且不重名的 key；数组追加到末尾。
    mutating func addValue(_ newValue: PlistValue, toContainerAt path: PlistPath, key: String?) -> Bool {
        guard let container = value(at: path) else { return false }
        switch container {
        case .dictionary(let values):
            guard let key, !key.isEmpty, values[key] == nil else { return false }
            var updated = values
            updated[key] = newValue
            return setValue(.dictionary(updated), at: path)
        case .array(var values):
            values.append(newValue)
            return setValue(.array(values), at: path)
        default:
            return false
        }
    }
}

/// plist 文档：加载/保存 xml 与 binary，保留原始格式；
/// 保存前用 baseline（mtime+size）检测外部修改，冲突必须显式覆盖。
struct PlistDocument {
    enum Format: Equatable {
        case xml
        case binary
    }

    enum DocumentError: LocalizedError {
        case unreadable(String)
        case invalidPropertyList(String)
        case unsupportedRoot
        case serialization(String)
        case externalModification
        case writeFailed(String)
        case verificationFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let message): return message
            case .invalidPropertyList(let message): return "不是有效的属性表：\(message)"
            case .unsupportedRoot: return "属性表根节点必须是字典或数组。"
            case .serialization(let message): return "无法序列化属性表：\(message)"
            case .externalModification: return "文件已被其他进程修改。"
            case .writeFailed(let message): return message
            case .verificationFailed(let message): return message
            }
        }
    }

    struct Baseline: Equatable {
        var modificationDate: Date?
        var size: UInt64
    }

    /// 超过该大小的文件仍可浏览，但禁用编辑与保存（对齐阶段 3b 约定）。
    static let editableByteLimit: UInt64 = 2 * 1024 * 1024

    let filePath: String
    private(set) var format: Format = .xml
    private(set) var root: PlistValue = .dictionary([:])
    private(set) var isDirty = false
    private(set) var fileSize: UInt64 = 0
    private(set) var baseline = Baseline(modificationDate: nil, size: 0)

    var isEditable: Bool { fileSize <= Self.editableByteLimit }

    init(path: String) {
        self.filePath = path
    }

    static func load(path: String) throws -> PlistDocument {
        var document = PlistDocument(path: path)
        try document.reload()
        return document
    }

    mutating func reload() throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: filePath)
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: filePath), options: .mappedIfSafe)
        } catch {
            throw DocumentError.unreadable("无法读取文件：\(error.localizedDescription)")
        }

        var parsedFormat = PropertyListSerialization.PropertyListFormat.xml
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data,
                                                                options: [],
                                                                format: &parsedFormat)
        } catch {
            throw DocumentError.invalidPropertyList(error.localizedDescription)
        }
        guard let converted = PlistValue.from(object), converted.isContainer else {
            throw DocumentError.unsupportedRoot
        }

        root = converted
        format = parsedFormat == .binary ? .binary : .xml
        fileSize = UInt64(data.count)
        baseline = Baseline(modificationDate: attributes?[.modificationDate] as? Date,
                            size: UInt64(data.count))
        isDirty = false
        AppLog.tag("PlistDocument", "loaded \(filePath) bytes=\(data.count) format=\(format)")
    }

    /// 磁盘上的文件与打开/上次保存时不一致（含文件已不存在）即视为冲突。
    /// 按阶段 3b 约定只比对 mtime+size；需要更严格时可改为同时比对 baseline 字节。
    func hasExternalModification() -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: filePath) else {
            return true
        }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modificationDate = attributes[.modificationDate] as? Date
        return size != baseline.size || modificationDate != baseline.modificationDate
    }

    func serializedData() throws -> Data {
        let object = root.propertyListObject
        let targetFormat: PropertyListSerialization.PropertyListFormat =
            format == .binary ? .binary : .xml
        do {
            return try PropertyListSerialization.data(fromPropertyList: object,
                                                      format: targetFormat,
                                                      options: 0)
        } catch {
            throw DocumentError.serialization(error.localizedDescription)
        }
    }

    mutating func save(force: Bool = false) throws {
        if !force && hasExternalModification() {
            throw DocumentError.externalModification
        }
        let data = try serializedData()
        do {
            try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
        } catch {
            throw DocumentError.writeFailed("保存失败：\(error.localizedDescription)")
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: filePath),
              let writtenSize = (attributes[.size] as? NSNumber)?.uint64Value,
              writtenSize == UInt64(data.count) else {
            throw DocumentError.verificationFailed("写入后的文件校验失败。")
        }
        baseline = Baseline(modificationDate: attributes[.modificationDate] as? Date,
                            size: writtenSize)
        fileSize = writtenSize
        isDirty = false
        AppLog.tag("PlistDocument", "saved \(filePath) bytes=\(writtenSize)")
    }

    /// 保存副本，不改变 filePath，也不清除 dirty 状态。
    func saveCopy(to path: String) throws {
        let data = try serializedData()
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw DocumentError.writeFailed("副本写入失败：\(error.localizedDescription)")
        }
        AppLog.tag("PlistDocument", "saved copy \(path) bytes=\(data.count)")
    }

    mutating func setValue(_ value: PlistValue, at path: PlistPath) {
        if root.setValue(value, at: path) {
            isDirty = true
        }
    }

    mutating func removeValue(at path: PlistPath) {
        if root.removeValue(at: path) {
            isDirty = true
        }
    }

    mutating func addValue(_ value: PlistValue, toContainerAt path: PlistPath, key: String?) {
        if root.addValue(value, toContainerAt: path, key: key) {
            isDirty = true
        }
    }

    /// 副本落点与 ObjC 版一致：Documents/Edited Copies/<name>-edited-<时间>.<ext>。
    static func editedCopyPath(for filePath: String, date: Date = Date()) -> String {
        let documents = NSSearchPathForDirectoriesInDomains(.documentDirectory,
                                                            .userDomainMask, true).first
            ?? NSHomeDirectory().appending("/Documents")
        let folder = (documents as NSString).appendingPathComponent("Edited Copies")
        let name = (filePath as NSString).lastPathComponent
        let fileExtension = (name as NSString).pathExtension
        let stem = fileExtension.isEmpty ? name : (name as NSString).deletingPathExtension
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let suffix = formatter.string(from: date)
        let copyName = fileExtension.isEmpty
            ? "\(stem)-edited-\(suffix)"
            : "\(stem)-edited-\(suffix).\(fileExtension)"
        return (folder as NSString).appendingPathComponent(copyName)
    }
}

private enum PlistFormatting {
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}
