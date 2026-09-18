# Swift 重写 · 阶段 3a 并行约定（查看器基础）

范围：查看器路由 + 图片/PDF/QuickLook/文本/媒体 五个查看器。
编辑类（plist/SQLite/Hex/压缩包/Office）放阶段 3b。

## 文件归属

| 归属 | 文件 | 说明 |
|---|---|---|
| A 注册表/关联 | `Sources/Core/ViewerRegistry.swift`、`Sources/Core/FileAssociationService.swift` | 纯 Foundation，可本地类型检查 |
| B 图片查看器 | `Sources/Features/Viewers/ImageViewerView.swift` | SwiftUI |
| C PDF/QuickLook | `Sources/Features/Viewers/PdfViewerView.swift`、`Sources/Features/Viewers/QuickLookView.swift` | SwiftUI + UIKit 包装 |
| D 文本编解码 + 文本查看/编辑 | `Sources/Core/TextCodec.swift`（Foundation，可本地类型检查）、`Sources/Features/Viewers/TextEditorView.swift` | |
| E 媒体播放 | `Sources/Features/Viewers/MediaPlayerView.swift` | AVKit |
| 集成方（主） | `Sources/Features/Viewers/ViewerHostView.swift`、`Sources/Features/Files/FilesView.swift`（只改打开入口）、`docs` | 路由与接线 |

禁止：改阶段 1/2 已有文件（除 C 名下的 `FilesView.swift` 由集成方改）、改 `src/`、
执行任何写 git 的命令。

## 冻结接口

### A：查看器注册表与文件关联

```swift
enum ViewerID: String, CaseIterable, Identifiable {
    case quickLook, image, media, pdf, text, web, sqlite, hex, archive, plist, office, spreadsheet, macho
    var id: String { rawValue }
    var title: String { get }        // 中文名，如 "图片"、"文本编辑器"
    var icon: String { get }         // SF Symbol
    /// 阶段 3a 已实现：quickLook/image/media/pdf/text；其余 false（路由会回退 quickLook）
    var isImplemented: Bool { get }
}

enum FileAssociationService {
    /// 扩展名（小写、不带点）→ 默认查看器；未知返回 .quickLook
    static func defaultViewerID(forExtension ext: String) -> ViewerID
    /// 用户覆盖优先，其次默认
    static func viewerID(forPath path: String) -> ViewerID
    static func override(forExtension ext: String) -> ViewerID?
    static func setOverride(_ viewer: ViewerID?, forExtension ext: String)
    /// 该扩展名可选的查看器（默认 + 已实现的候补）
    static func supportedViewers(forExtension ext: String) -> [ViewerID]
}
```

扩展名映射照抄 `src/FFViewerRegistry.m` + `src/FFFileAssociationService.m`
（含 pdf 默认 quickLook、文本类、图片、音视频、office 等；.ipa → archive、
.deb 除外等既有规则）。用户覆盖存 `UserDefaults`（键前缀 `FFViewerOverride.`）。

### B：图片查看器

```swift
struct ImageViewerView: View {
    init(entry: FileEntry, siblings: [FileEntry])   // siblings 为同目录图片，按当前排序
}
```
要求：黑底；双指缩放 + 拖动（用 `UIViewRepresentable` 包 UIScrollView 最稳）、双击
放大/还原；左右滑切换上一张/下一张（到边界停住）；顶部标题为文件名；加载失败显示
错误文案而不是空白；大图解码放后台（`Task.detached`），切换要防竞态（代次）。

### C：PDF 与 QuickLook

```swift
struct PdfViewerView: View { init(entry: FileEntry) }
struct QuickLookView: View { init(entry: FileEntry) }
```
PDF 用 PDFKit（`PDFView` 包装）：自动缩放、页码/总页数显示、上下页按钮、捏合缩放。
QuickLook 用 `QLPreviewController` 包装（`UIViewControllerRepresentable`），文件不存在
时显示错误文案。两者都要 `import PDFKit` / `import QuickLook`。

### D：文本编解码与编辑器

```swift
enum TextEncodingKind: String, CaseIterable, Identifiable { case utf8, utf8BOM, utf16LE, utf16BE, latin1 }
enum LineEnding: String, CaseIterable, Identifiable { case lf, crlf, cr }

struct DecodedText {
    let text: String
    let encoding: TextEncodingKind
    let bom: Bool
    let lineEnding: LineEnding
}

enum TextCodec {
    /// BOM/启发式探测；解不出来返回 nil
    static func decode(_ data: Data) -> DecodedText?
    static func encode(_ text: String, encoding: TextEncodingKind, bom: Bool, lineEnding: LineEnding) -> Data?
}

struct TextEditorView: View {
    init(entry: FileEntry)
}
```
规则照抄 `src/FFTextCodec.m` 与 `src/FFTextEditorViewController.m` 的大文件策略：
> 8MB 只读预览（只显示前 1MB，禁止保存）、2–8MB 可编辑但不做高亮、≤ 2MB 正常；
保存用原子写（`Data.write(options: .atomic)`）；换行符/编码可切换（菜单）；
未保存返回要提示。文本视图用 `UITextView` 包装（等宽字体、可选中）。

### E：媒体播放

```swift
struct MediaPlayerView: View {
    init(entry: FileEntry, siblings: [FileEntry])
}
```
`AVPlayerViewController` 包装（`import AVKit`）：播放/暂停/进度用系统控件；上一集/
下一集按钮（siblings）；音频会话 `playback`；离开页面暂停；后台/来电由系统处理。
断点续播、字幕、横屏全屏放阶段 3b/后续，不要求。

## 验收

- 只写自己名下文件；Swift 5 / iOS 16；不用 iOS 17+ API。
- 纯 Foundation 文件（A、D 的 TextCodec）用本机 `/opt/swift/usr/bin/swiftc -typecheck
  -swift-version 5 <相关文件>` 自查；SwiftUI 文件用 `swiftc -parse` 自查语法。
- 交付说明：文件、假设、需要集成方接手处。
