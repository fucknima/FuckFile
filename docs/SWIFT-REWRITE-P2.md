# Swift 重写 · 阶段 2 并行约定

阶段 2：文件浏览器 + 文件操作。多人（多智能体）并行时**严格按文件归属**写，
接口按本文冻结；需要改别人文件的地方只写进自己的交付说明，由集成方统一改。

## 文件归属

| 归属 | 文件 | 说明 |
|---|---|---|
| A 文件操作引擎 | `Sources/Core/FileConflictPolicy.swift`、`Sources/Core/FileOperations.swift` | 纯 Foundation，无 UI |
| B 回收站 | `Sources/Core/TrashService.swift` | 纯 Foundation，无 UI |
| C 浏览器 UI | `Sources/Features/Files/FilesView.swift`（重写）、`Sources/Features/Files/BrowserViewModel.swift`、`Sources/Features/Files/FileSortFilter.swift` | SwiftUI，只依赖阶段 1 的 `FileEntry`/`DirectoryLister`/`StorageEnvironment`/`AppLog` 与本文接口 |
| 集成方（主） | `Sources/Core/FileActions.swift`、`Sources/Features/Files/ConflictDialog.swift`、`Sources/Core/FileTaskManager.swift`（补执行体） | 串起 A/B/C 并接任务系统 |

禁止：改 `Sources/Core/` 下阶段 1 的文件（`AppLog`/`FileEntry`/`DirectoryLister`/
`StorageEnvironment`/`FileTask`）、改 `RootView.swift`、改 `src/`（ObjC 参考）、
执行任何写 git 的命令（不 add/commit/checkout/push）。

## 冻结接口

### A：文件操作

```swift
enum FileConflictPolicy: String, CaseIterable, Identifiable {
    case ask, replace, keepBoth, skip
    var id: String { rawValue }
    var title: String { get }        // 询问/替换/保留两者/跳过
}

enum FileOperationError: LocalizedError {
    case invalidPath(String)
    case sourceMissing(String)
    case nameConflict(String)
    case copyFailed(String)
    case moveFailed(String)
    case removeFailed(String)
    case renameFailed(String)
    case cancelled
    var errorDescription: String? { get }
}

enum FileOperations {
    /// 目标目录里不冲突的名字：name.ext → "name 2.ext" → "name 3.ext"…
    static func uniqueDestination(in directory: String, preferredName: String) -> String
    static func destinationExists(in directory: String, name: String) -> Bool

    /// 复制文件/目录到目标目录；progress 可能从后台线程回调；shouldCancel 返回 true 时抛 .cancelled。
    /// 返回落盘后的完整路径。
    @discardableResult
    static func copyItem(at source: String, toDirectory directory: String,
                         conflict: FileConflictPolicy,
                         progress: ((Double) -> Void)?,
                         shouldCancel: (() -> Bool)?) throws -> String

    @discardableResult
    static func moveItem(at source: String, toDirectory directory: String,
                         conflict: FileConflictPolicy,
                         progress: ((Double) -> Void)?,
                         shouldCancel: (() -> Bool)?) throws -> String

    static func removeItem(at path: String) throws

    /// 同目录改名；重名时抛 .nameConflict。
    @discardableResult
    static func renameItem(at path: String, to newName: String) throws -> String

    @discardableResult
    static func createFolder(named name: String, in directory: String) throws -> String
    @discardableResult
    static func createFile(named name: String, in directory: String) throws -> String
}
```

规则：`.ask` 只由 UI 使用，引擎收到 `.ask` 时按 `.keepBoth` 处理。`.replace` 不许先删后写——
先把旧目标改名为备份，成功后再删备份，失败回滚（沿用 ObjC 版 `replaceExistingDestination`
的语义）。`.skip` 返回原目标路径（不覆盖）。跨卷移动失败（EXDEV）要退化为复制+删除源。
符号链接按链接本身处理，不跟随。

### B：回收站

```swift
struct TrashEntry: Identifiable, Hashable {
    let id: String            // 条目目录名（UUID）
    let name: String          // 原始文件名
    let originalPath: String  // 原绝对路径
    let trashedAt: Date
    let isDirectory: Bool
    let size: UInt64
}

enum TrashService {
    static var trashRoot: String                       // Documents/.Trash
    static func moveToTrash(_ path: String) throws -> TrashEntry
    static func entries() throws -> [TrashEntry]       // 按 trashedAt 倒序
    static func restore(_ entry: TrashEntry) throws -> String  // 原目录不在时落到 Documents 根
    static func removePermanently(_ entry: TrashEntry) throws
    static func emptyTrash() throws
    @discardableResult
    static func purgeExpired(olderThanDays days: Int) throws -> Int
}
```

存储布局：`Documents/.Trash/<uuid>/item.plist`（键 `name`/`originalPath`/`trashedAt`/
`isDirectory`）+ `Documents/.Trash/<uuid>/payload/<name>`。restore 目标重名要唯一化
（"name 2"…）；条目元数据读不出来要跳过而不是崩。

### C：浏览器 UI

```swift
enum FileSortMode: String, CaseIterable, Identifiable { case name, size, date, kind }
enum FileFilterMode: String, CaseIterable, Identifiable { case all, folder, image, video, audio, document, archive, code, other }

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
    var visibleEntries: [FileEntry] { get }     // 过滤 + 排序
    init(directory: String)
    func load() async
    func toggleSelection(_ entry: FileEntry)
    func selectAll()
    func clearSelection()
}
```

`FilesView` 要求：列表/网格切换；排序（名称/大小/日期/类型，升降序）、筛选、
显示隐藏文件（菜单）；进入子目录用 `NavigationStack` + `navigationDestination`；
多选模式与批量操作栏（复制/移动/删除/重命名）调用集成方的 `FileActions.shared`
（方法签名见下，C 只调用，不实现）；行内 context menu 与左滑（删除/重命名/复制/
移动）；空/加载/错误状态；下拉刷新。所有文件操作后调用 `viewModel.load()` 刷新。

```swift
// 集成方提供；C 只调用
@MainActor
final class FileActions {
    static let shared: FileActions
    func copy(_ entries: [FileEntry], toDirectory: String)
    func move(_ entries: [FileEntry], toDirectory: String)
    func trash(_ entries: [FileEntry])
    func rename(_ entry: FileEntry, to newName: String)
    func createFolder(named: String, inDirectory: String)
    func createFile(named: String, inDirectory: String)
}
```

## 参考实现（ObjC，只读）

- 复制/移动/冲突：`src/FFCopyEngine.m`、`src/FFFileOperationService.m`、
  `src/FFFileTaskManager.m`（`replaceExistingDestination`、`uniqueDestinationForName`）
- 回收站：`src/FFTrashService.m/.h`
- 浏览器：`src/FFBrowserViewController.m`（排序/筛选/多选/批量栏）
- 冲突 UI 文案：`src/FFConflictPolicy.h`

## 验收

- 只写自己名下的文件；Swift 5 / iOS 16 可用 API；不用 iOS 17+ 特性。
- 交付说明：列出新增/修改文件、假设、需要集成方接手的地方。
