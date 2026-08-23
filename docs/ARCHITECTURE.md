# Architecture

采用模块化架构。

核心原则：

UI 不直接负责具体文件系统操作。

## 当前实现映射（Objective-C）

文档规划使用 Swift 命名，当前工程为 Objective-C（见 DECISIONS ADR-006）：

| 文档概念 | 实现 |
|---|---|
| FileItem | `FFEntry`（src/FFBrowserViewController.h） |
| StorageProvider | Local 直连（`FFBrowserViewController.loadDirectoryContents`），Protocol 抽象延后 |
| FileOperationService | `FFCopyEngine`（复制引擎）+ NSFileManager 调用点（rename/delete 待收敛） |
| ArchiveService | `FFZipExtract`（解压）/ `FFZipCreate`（压缩）/ `FFArchiveService`（包内列表与单条目提取） |
| Logger | `FFLogger`（模块 tag：Browser/MCM/LSDiscovery/PlistEditor/Viewer/Preview/SQLite/Archive/HexEditor/Web/IPA 等） |
| Preview 路由 | `FFPreviewRouter`（文件关联 → Viewer Registry → 内容检测 fallback；Browser/Search/Favorites/Recents 共用同一入口） |
| Viewer 注册表 | `FFViewerRegistry`（viewer ID/显示名/图标/可用状态/open 分发的唯一来源） |
| 文件关联 | `FFFileAssociationService`（内置默认表在代码中 + NSUserDefaults 用户覆盖，最长后缀优先匹配） |
| 文件系统访问底座 | `MCMManager`（MHA 身份容器访问）+ `FFLSDiscovery`（LaunchServices 扫描） |

## 文件查看链路

所有预览入口收敛为：

```
文件 → FFPreviewRouter → FFFileAssociationService → FFViewerRegistry → 对应 Viewer
```

解析顺序：

1. 查用户覆盖关联（NSUserDefaults）
2. 查内置默认关联（代码内表）
3. 检查 Viewer 可用性并打开（不可用给出明确反馈）
4. 未命中时执行内容检测 fallback：plist 嗅探 → 文本嗅探 → Quick Look → Hex 编辑器

规则：

- 扩展名匹配为最长后缀优先（`backup.tar.gz` 先试 `.tar.gz` 再试 `.gz`），大小写不敏感、前导点规范化。
- 内置默认关联写在 `FFFileAssociationService.m` 的代码表中；用户修改只保存 override，
  升级新增默认格式不会覆盖用户选择，「恢复默认」即清空 override。
- 修改立即生效：查找始终读实时状态，无需重启。
- Browser 不再维护扩展名 if/else 预览逻辑，只负责浏览、选择与调用 Router；
  长按菜单的「安装 / 浏览压缩包 / 用其他查看器打开」通过 Router 显式指定 viewer ID。

## Viewers

统一由 `FFViewerRegistry` 管理：ID、显示名称、SF Symbol 图标、能力摘要（含
「暂不支持」的诚实标注）、可用性检查与 open 分发。当前注册：

| viewer ID | 名称 | 实现 |
|---|---|---|
| image | 图片浏览器 | Registry 内联 UIImageView + 分享 |
| quicklook | 快速查看 | `FFQuickLookViewController`（系统 QLPreviewController，fallback 预览） |
| web | Web Viewer | `FFWebViewerViewController`（WKWebView；本地 HTML read-access 根限定在文件所在目录；解析 .url/.webloc） |
| plist | 属性表编辑器 | `FFPlistEditorViewController`（复用） |
| text | 文本编辑器 | `FFTextEditorViewController`（复用；脚本仅按文本打开，不执行） |
| sqlite | SQLite3 编辑器 | `FFSQLiteService` + `FFSQLiteBrowserViewController`（系统 sqlite3 只读：库信息/表/视图/索引/schema/分页浏览/SQL 查询） |
| installer | IPA 安装器 | `FFIPaInstallerViewController`（解析 Payload/*.app Info.plist 与图标；安装受运行环境限制并如实反馈） |
| archive | ZIP 浏览器 | `FFArchiveBrowserViewController` + minizip 后端（包内目录树/单文件预览/选中提取/全部解压）；TAR/GZ/7z/RAR/XZ/BZ2 无后端时明确提示暂不支持 |
| hex | 十六进制编辑器 | `FFHexEditorViewController`（open/pread 分页 64KB，OFFSET/HEX/ASCII，偏移跳转，字节修改与保存/取消，CRC32/SHA-256 校验和） |
| media | 媒体播放器 | Registry 内联 AVPlayerViewController |
| pdf | PDF 阅读器 | `FFPdfPreviewViewController`（复用；图片浏览器为 UIScrollView 缩放 + 双击，PhotoScroller 模式） |

明确排除：终端（无任何脚本执行能力）、DEB 专用逻辑（`.deb` 不注册关联、
不进 ZIP 浏览器、不交安装器）。

## 第三方组件

- minizip（third_party/minizip，zlib License）：ZIP 列表/提取/全量解压的解析后端
  （ADR-011）；条目数/体积上限、文件名消毒、符号链接拒绝在库之上实现。
- SQLite 编辑器支持 CSV 导出；IPA 安装器含 TrollStore 检测（applestore://）
  与 LSApplicationWorkspace 私有通道探测。

## Core Models

统一文件模型：

FileItem

字段示例：

- id
- name
- url/path
- type
- size
- creationDate
- modificationDate
- isDirectory
- fileExtension
- providerID

## Storage Provider

定义统一 StorageProvider。

例如：

StorageProvider
├── LocalStorageProvider
├── SMBStorageProvider
├── WebDAVStorageProvider
└── SFTPStorageProvider

统一提供：

- list
- stat
- createDirectory
- rename
- copy
- move
- delete
- read
- write

上层 UI 不应该关心文件来自本地还是 SMB。

## Services

### FileOperationService

负责：

- copy
- move
- delete
- rename
- duplicate

### FileTaskManager

负责长时间任务。

维护：

- queued
- running
- paused
- completed
- failed
- cancelled

### SearchService

负责：

- 文件搜索
- 搜索过滤
- 搜索历史

### PreviewService

负责识别文件应使用哪种 Preview。

### ThumbnailService

负责：

- 请求缩略图
- 生成缩略图
- 内存缓存
- 磁盘缓存

### ArchiveService

负责：

- compress
- extract

### FavoritesService

负责：

- 收藏
- 取消收藏
- 收藏列表

### RecentService

负责最近访问记录。

## Features

建议目录：

Features/
├── Browser/
├── Search/
├── Favorites/
├── Recent/
├── Preview/
├── Settings/
├── Tasks/
├── Archive/
└── Network/

## Browser

Browser/
├── FileBrowserView
├── FileBrowserViewModel
├── FileListView
├── FileGridView
├── FileRow
├── FileContextMenu
└── BrowserToolbar

## Preview

Preview/
├── PreviewRouter（FFPreviewRouter：关联→Registry→fallback）
├── ViewerRegistry（FFViewerRegistry）
├── FileAssociationService（FFFileAssociationService）
├── ImagePreview
├── VideoPreview / AudioPreview（media）
├── QuickLookPreview
├── WebPreview
├── TextEditor
├── PlistEditor
├── SQLiteBrowser + SQLiteService
├── ArchiveBrowser + ArchiveService
├── HexEditor
├── IPaInstaller
└── PDFPreview

## State

复杂异步状态使用明确状态枚举。

例如：

idle
loading
loaded
failed

禁止大量：

isLoading
isError
isFinished
isRefreshing
isEmpty

互相组合形成不可预测状态。

## Concurrency

文件扫描、复制、搜索、缩略图生成等任务不得阻塞 MainActor。

UI 更新回到 MainActor。

优先使用 Swift Concurrency。

## Database

前期尽量保持简单。

需要持久化：

- Favorites
- Recent
- SearchHistory
- NetworkServers
- Settings

具体持久化方案根据项目发展选择。

## Logging

建立统一 Logger。

模块：

- Browser
- FileOperation
- Network
- Archive
- Preview
- Thumbnail
- Database

Debug 时保留详细日志。

Release 避免泄漏敏感路径及账户信息。
