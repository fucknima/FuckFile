import Foundation
#if canImport(Combine)
import Combine
#endif

/// 目录浏览器状态（阶段 2 冻结接口）。筛选/排序规则见 FileSortFilter.swift。
@MainActor
final class BrowserViewModel: ObservableObject {
    let directory: String

    @Published var entries: [FileEntry] = []
    @Published var isLoading = false
    @Published var loadError: String?
    @Published var sortMode: FileSortMode = .name
    @Published var sortAscending = true
    @Published var filterMode: FileFilterMode = .all
    @Published var showHidden = false
    @Published var isSelecting = false
    @Published var selectedPaths: Set<String> = []

    /// 加载代次：切换显示隐藏文件等触发的并发加载只有最后一次能落盘。
    private var loadGeneration = 0

    init(directory: String) {
        self.directory = directory
    }

    var visibleEntries: [FileEntry] {
        sortMode.sort(entries.filter { filterMode.matches($0) },
                      ascending: sortAscending)
    }

    /// 当前选中的条目（按 entries 顺序），供批量操作使用。
    var selectedEntries: [FileEntry] {
        entries.filter { selectedPaths.contains($0.path) }
    }

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer {
            if generation == loadGeneration { isLoading = false }
        }
        do {
            let listed = try await DirectoryLister.list(directory, includeHidden: showHidden)
            guard generation == loadGeneration else { return }
            entries = listed
            loadError = nil
            selectedPaths.formIntersection(Set(listed.map(\.path)))
            AppLog.tag("Files", "list path=\(directory) count=\(listed.count)")
        } catch {
            guard generation == loadGeneration else { return }
            entries = []
            loadError = "无法读取目录：\(error.localizedDescription)"
            AppLog.tag("Files", "list FAIL path=\(directory) error=\(error.localizedDescription)")
        }
    }

    func toggleSelection(_ entry: FileEntry) {
        if selectedPaths.contains(entry.path) {
            selectedPaths.remove(entry.path)
        } else {
            selectedPaths.insert(entry.path)
        }
    }

    func selectAll() {
        selectedPaths = Set(visibleEntries.map(\.path))
    }

    func clearSelection() {
        selectedPaths.removeAll()
    }
}
