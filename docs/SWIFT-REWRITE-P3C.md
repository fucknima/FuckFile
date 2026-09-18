# Swift 重写 · 阶段 3c 并行约定（交互补齐）

修审查发现的能力与交互缺口：搜索、缩略图、分享/信息、剪贴板复制粘贴、面包屑、
收藏/最近、批量重命名。排序持久化/菜单语义/取消全选/任务 tab 由集成方直接改。

## 文件归属

| 归属 | 文件 |
|---|---|
| A 搜索 | `Sources/Core/SearchService.swift`、`Sources/Features/Files/SearchView.swift` |
| B 缩略图 | `Sources/Core/ThumbnailService.swift`、`Sources/Features/Files/FileThumbnailView.swift` |
| C 分享/信息/查看器操作 | `Sources/Core/FileMetadataService.swift`、`Sources/Features/Viewers/FileInfoView.swift`、`Sources/Features/Viewers/ShareSheet.swift`、`Sources/Features/Viewers/ViewerActions.swift` |
| D 剪贴板 + 面包屑 | `Sources/Core/ClipboardService.swift`、`Sources/Features/Files/BreadcrumbView.swift` |
| E 收藏/最近 + 批量重命名 | `Sources/Core/BookmarksService.swift`、`Sources/Features/Files/BookmarksView.swift`、`Sources/Core/BatchRename.swift`、`Sources/Features/Files/BatchRenameView.swift` |
| 集成方（主） | `FilesView.swift`、`BrowserViewModel.swift`、`RootView.swift`、`ViewerHostView.swift`、docs、Makefile |

禁止：改他人名下文件、改 `src/`、执行任何写 git 的命令。

## 冻结接口

### A 搜索

```swift
struct SearchHit: Identifiable, Hashable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: UInt64
}

/// 递归搜索（后台线程、可取消、分批回调）。回调都在主线程。
final class SearchSession {
    func cancel()
    var isCancelled: Bool { get }
}

enum SearchService {
    /// 在 root 下递归查找名字包含 query 的条目（大小写/全半角不敏感）。
    /// batch 分批回传（主线程），completion 结束时回调（主线程，cancelled 表示被取消）。
    static func search(query: String, under root: String,
                       batch: @escaping ([SearchHit]) -> Void,
                       completion: @escaping (Bool) -> Void) -> SearchSession
}

/// 独立搜索页：输入框 + 结果列表（点击目录进入、点击文件进 ViewerHostView），
/// 带「正在搜索 / 无结果 / 已取消」状态与取消按钮。
struct SearchView: View {
    init(rootDirectory: String)
}
```

安全：不跟随符号链接（lstat），跳过 `.Trash` 与内部条目（用
`StorageEnvironment.isInternalEntry`），限制结果上限（如 5000）与最大深度。

### B 缩略图

```swift
enum ThumbnailService {
    /// 主线程回调；不支持的类型回 nil。内存 NSCache + 磁盘缓存（Caches/Thumbnails）。
    static func thumbnail(forPath path: String, size: CGSize,
                          completion: @escaping (UIImage?) -> Void)
    static func cachedThumbnail(forPath path: String, size: CGSize) -> UIImage?
}

/// 列表/网格通用：有缩略图显示缩略图（圆角），否则回退 SF Symbol 图标。
struct FileThumbnailView: View {
    init(entry: FileEntry, size: CGSize, fallbackIcon: String, fallbackTint: Color)
}
```
支持类型：png/jpg/jpeg/gif/heic/webp/tiff/bmp、mp4/mov/m4v（首帧，用
`AVAssetImageGenerator`）；回调统一主线程；同一 key 并发请求合并。

### C 分享 / 信息 / 查看器操作

```swift
struct FileMetadata {
    let name: String
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool
    let linkTarget: String?
    let size: UInt64
    let modificationDate: Date?
    let creationDate: Date?
    let modeText: String       // 例如 "-rw-r--r--"
    let uid: uid_t
    let gid: gid_t
    let itemCount: Int?        // 目录内条目数
}

enum FileMetadataService {
    static func metadata(forPath path: String) -> FileMetadata?
}

struct FileInfoView: View { init(entry: FileEntry) }

/// UIActivityViewController 包装（iPad 需 popover 锚点）。
struct ShareSheet: View { init(items: [Any]) }

/// 查看器统一工具栏动作：分享 / 信息 / 删除（移到回收站后自动 pop 返回）。
struct ViewerActionsModifier: ViewModifier { init(entry: FileEntry) }
extension View {
    func viewerActions(for entry: FileEntry) -> some View
}
```
删除用 `FileActions.shared.trash([entry])`，删除后 `dismiss()`。

### D 剪贴板 + 面包屑

```swift
final class ClipboardService: ObservableObject {
    static let shared: ClipboardService
    enum Mode { case copy, cut }
    @Published private(set) var paths: [String]
    @Published private(set) var mode: Mode?
    var isEmpty: Bool { get }
    var count: Int { get }
    func copy(_ paths: [String])
    func cut(_ paths: [String])
    func clear()
}

struct BreadcrumbView: View {
    init(path: String, onSelect: @escaping (String) -> Void)
}
```
面包屑：横向可滚动，从 Documents 根到当前目录逐段可点（点击回调该段路径），
当前段高亮；不显示 App 内部目录名以外的内容（路径段用真实名）。

### E 收藏/最近 + 批量重命名

```swift
final class BookmarksService: ObservableObject {
    static let shared: BookmarksService
    enum Mode { case favorites, recent }
    @Published private(set) var favorites: [BookmarkItem]
    @Published private(set) var recents: [BookmarkItem]
    func addFavorite(path: String, name: String)
    func removeFavorite(path: String)
    func isFavorite(path: String) -> Bool
    func recordRecent(path: String, name: String, isDirectory: Bool)
}

struct BookmarkItem: Identifiable, Hashable { let path: String; let name: String; let date: Date }

struct BookmarksView: View { init(mode: BookmarksService.Mode) }

enum BatchRename {
    /// 规则：前缀/后缀/替换/序号（照抄 src/FFBatchRename.h 的能力子集）
    struct Rule { var prefix: String; var suffix: String; var find: String; var replace: String; var useSequence: Bool; var sequenceStart: Int; var sequenceDigits: Int }
    /// 返回 (原路径, 新文件名) 列表；冲突/非法名在这里标出。
    static func plan(entries: [FileEntry], rule: Rule) -> [BatchRenameItem]
    struct BatchRenameItem { let path: String; let oldName: String; let newName: String; let conflict: Bool }
    /// 应用；失败返回错误（保持已改的）。
    static func apply(plan: [BatchRenameItem]) throws
}

struct BatchRenameView: View { init(entries: [FileEntry], onDone: @escaping () -> Void) }
```
存储：`UserDefaults`（收藏 `FFBookmarks.plist` 风格键 `FFBookmarks`、最近 `FFRecents`，
各限 50 条；最近按时间倒序去重）。

## 验收

- 只写自己名下文件；Swift 5 / iOS 16；不用 iOS 17+ API。
- 自查：`/opt/swift/usr/bin/swiftc -parse <你的文件>`；纯 Foundation 文件尝试
  `-typecheck -swift-version 5`（可加 `/tmp/opencode/combine_shim.swift`）。
- 交付说明：文件、公开 API、假设、集成方接手点。
