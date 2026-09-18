# Swift 重写 · 阶段 3b 并行约定（编辑类查看器 + 压缩包 + 网页）

范围：plist 编辑、SQLite 浏览、Hex 编辑、ZIP 压缩包（浏览/解压/压缩）、
网页（HTML）查看器、查看器选择/文件关联设置。
Office（docx/xlsx 等）本阶段用 QuickLook 兜底，保真渲染运行时留后续阶段。

## 文件归属

| 归属 | 文件 |
|---|---|
| A plist | `Sources/Core/PlistDocument.swift`、`Sources/Features/Viewers/PlistEditorView.swift` |
| B SQLite | `Sources/Core/SQLiteService.swift`、`Sources/Features/Viewers/SQLiteBrowserView.swift` |
| C Hex | `Sources/Features/Viewers/HexEditorView.swift` |
| D 压缩包 | `Sources/Core/ZipArchive.swift`、`Sources/Features/Viewers/ArchiveBrowserView.swift` |
| E 网页/选择器/关联设置 | `Sources/Features/Viewers/WebViewerView.swift`、`Sources/Features/Viewers/ViewerPickerView.swift`、`Sources/Features/Settings/FileAssociationsView.swift` |
| 集成方（主） | `ViewerHostView.swift`、`ViewerRegistry.swift`（isImplemented）、`FileActions.swift`（compress）、`FilesView.swift`（打开方式/压缩入口）、Makefile、docs |

禁止：改他人名下文件、改 `src/`、执行任何写 git 的命令。

## 可用基础设施

- 已建桥接头 `Sources/FuckFile-Bridging-Header.h`（`#import "unzip.h"`），
  Makefile 已把 `third_party/minizip/unzip.c`、`ioapi.c` 编进 App 并链接 `-lz`、`-lsqlite3`。
- `FileTaskManager.shared.enqueue(kind:displayName:operation:completion:)`：后台串行执行，
  操作里用 `task.cancelled` 判取消、`DispatchQueue.main.async { task.progress = ... }` 报进度。
- 操作完成后 `NotificationCenter.default.post(name: .fileActionsDidChange, object: nil)` 刷新浏览器。
- `AppLog.tag("Preview", "...")` 打日志。

## 冻结接口（集成方直接调用）

```swift
struct PlistEditorView: View { init(entry: FileEntry) }
struct SQLiteBrowserView: View { init(entry: FileEntry) }
struct HexEditorView: View { init(entry: FileEntry) }
struct ArchiveBrowserView: View { init(entry: FileEntry) }
struct WebViewerView: View { init(entry: FileEntry) }
struct ViewerPickerView: View { init(entry: FileEntry, onPick: @escaping (ViewerID) -> Void) }
struct FileAssociationsView: View { init() }
```

服务层（供 UI 用，命名可自定但需在交付说明里列出）：

- A：`PlistDocument`（加载/保存 xml+binary，值类型保留 bool/int/real/date/data/array/dict；
  保存前对比 baseline（mtime+size），外部已改要报冲突）。
- B：`SQLiteService`（只读打开、表/视图列表、列名、分页查询、schema、CSV 导出字符串）。
- D：`ZipArchive`（`entries(at:)`、`extract(at:entry:toDirectory:password:)`、
  `extractAll(at:toDirectory:password:)`、`createZip(from:to:)`）。
  安全要求（照抄 ObjC）：拒绝 `..`/绝对路径/符号链接条目；解压目标目录唯一化（`xxx (2)`）；
  写入用临时文件+rename；`createZip` 用 Apple `Compression`（`COMPRESSION_ZLIB` = 裸 DEFLATE）
  或 store，生成标准 zip。

## 行为参考（只读）

- plist：`src/FFPlistDocument.m`、`src/FFPlistEditorViewController.m`
- SQLite：`src/FFSQLiteService.m`、`src/FFSQLiteBrowserViewController.m`（只读浏览 + 行详情 + CSV）
- Hex：`src/FFHexEditorViewController.m`（分页 64KB、行编辑、原子保存、跳转、查找）
- 压缩包：`src/FFZipExtract.m`（安全校验/密码/唯一目录）、`src/FFArchiveBrowserViewController.m`
- 网页：`src/FFWebViewerViewController.m`（缩放 viewport 脚本 + 深色适配，ADR-035）
- 关联：`src/FFViewerPickerViewController.m`、`src/FFFileAssociationsViewController.m`

## 验收

- 只写自己名下文件；Swift 5 / iOS 16；不用 iOS 17+ API。
- 自查：`/opt/swift/usr/bin/swiftc -parse <你的文件>` 至少过语法；纯 Foundation 的
  （PlistDocument、SQLiteService 里的 Foundation 部分）尝试
  `/opt/swift/usr/bin/swiftc -typecheck -swift-version 5 <相关文件>`。
- 交付说明：文件、公开 API、假设、集成方接手点。
