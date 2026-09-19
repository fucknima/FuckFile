import SwiftUI

/// 存储空间：设备容量 + App 数据 / 缓存 / 回收站 + 分类占用；可清缓存。
struct StorageAnalysisView: View {
    @StateObject private var model = StorageScanModel()

    var body: some View {
        List {
            Section("设备") {
                LabeledContent("总容量", value: format(model.deviceTotal))
                LabeledContent("可用空间", value: format(model.deviceAvailable))
                LabeledContent("已用空间", value: format(model.deviceUsed))
            }
            Section("FuckFile 数据") {
                LabeledContent("App 数据", value: scanning(model.documentsBytes))
                LabeledContent("缓存", value: scanning(model.cacheBytes))
                LabeledContent("回收站", value: scanning(model.trashBytes))
            }
            Section("分类占用") {
                ForEach(model.categories) { row in
                    LabeledContent(row.title, value: scanning(row.bytes))
                }
            }
            Section {
                Button("清缓存", role: .destructive) { model.clearCache() }
                    .disabled(model.isScanning || model.cacheBytes == 0)
            } footer: {
                Text("缓存只包含缩略图等可再生成的临时文件，不影响文件数据。")
            }
        }
        .navigationTitle("存储空间")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if model.isScanning && model.deviceTotal == 0 { ProgressView() }
        }
        .task { await model.scan() }
        .refreshable { await model.scan() }
    }

    private func scanning(_ bytes: Int64) -> String {
        model.isScanning && bytes == 0 ? "扫描中…" : format(bytes)
    }

    private func format(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

@MainActor
private final class StorageScanModel: ObservableObject {
    @Published private(set) var deviceTotal: Int64 = 0
    @Published private(set) var deviceAvailable: Int64 = 0
    @Published private(set) var deviceUsed: Int64 = 0
    @Published private(set) var documentsBytes: Int64 = 0
    @Published private(set) var cacheBytes: Int64 = 0
    @Published private(set) var trashBytes: Int64 = 0
    @Published private(set) var categories: [StorageScanner.CategoryRow] = []
    @Published private(set) var isScanning = false

    func scan() async {
        isScanning = true
        let result = await Task.detached(priority: .utility) { StorageScanner.collect() }.value
        deviceTotal = result.deviceTotal
        deviceAvailable = result.deviceAvailable
        deviceUsed = max(0, result.deviceTotal - result.deviceAvailable)
        documentsBytes = result.documentsBytes
        cacheBytes = result.cacheBytes
        trashBytes = result.trashBytes
        categories = result.categories
        isScanning = false
    }

    func clearCache() {
        ThumbnailService.clearCaches()
        StorageScanner.clearCachesDirectory()
        Task { await scan() }
    }
}

/// 纯计算：在后台线程扫描，不接触任何 UI 状态。
private enum StorageScanner {
    struct CategoryRow: Identifiable {
        let id: String
        let title: String
        let bytes: Int64
    }

    struct ScanResult {
        var deviceTotal: Int64 = 0
        var deviceAvailable: Int64 = 0
        var documentsBytes: Int64 = 0
        var cacheBytes: Int64 = 0
        var trashBytes: Int64 = 0
        var categories: [CategoryRow] = []
    }

    private static let categoryOrder: [FileFilterMode] = [
        .image, .video, .audio, .document, .archive, .code, .other,
    ]

    static func collect() -> ScanResult {
        var result = ScanResult()
        let manager = FileManager.default
        let documents = StorageEnvironment.documentsPath
        let documentsURL = URL(fileURLWithPath: documents, isDirectory: true)

        if let values = try? documentsURL.resourceValues(
            forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
            result.deviceTotal = Int64(values.volumeTotalCapacity ?? 0)
            result.deviceAvailable = Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        }

        var categoryBytes: [FileFilterMode: Int64] = [:]
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
        if let enumerator = manager.enumerator(at: documentsURL,
                                               includingPropertiesForKeys: Array(keys)) {
            for case let url as URL in enumerator {
                let top = relativePath(url.path, from: documents)
                    .split(separator: "/").first.map(String.init) ?? ""
                if top != ".Trash", StorageEnvironment.internalEntryNames.contains(top) {
                    enumerator.skipDescendants()
                    continue
                }
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true else { continue }
                let size = Int64(values.fileSize ?? 0)
                result.documentsBytes += size
                if top == ".Trash" {
                    result.trashBytes += size
                } else {
                    let category = FileFilterMode.category(
                        forExtension: (url.path as NSString).pathExtension)
                    categoryBytes[category, default: 0] += size
                }
            }
        }
        result.categories = categoryOrder.map { mode in
            CategoryRow(id: mode.rawValue, title: mode.title,
                        bytes: categoryBytes[mode] ?? 0)
        }

        result.cacheBytes = directoryBytes(cachesDirectory())
        return result
    }

    static func clearCachesDirectory() {
        guard let root = cachesDirectory() else { return }
        let manager = FileManager.default
        for name in (try? manager.contentsOfDirectory(atPath: root.path)) ?? [] {
            try? manager.removeItem(at: root.appendingPathComponent(name))
        }
    }

    private static func cachesDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }

    private static func directoryBytes(_ root: URL?) -> Int64 {
        guard let root else { return 0 }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root,
                                                              includingPropertiesForKeys: Array(keys))
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private static func relativePath(_ path: String, from root: String) -> String {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}
