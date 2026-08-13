# Architecture

采用模块化架构。

核心原则：

UI 不直接负责具体文件系统操作。

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
├── PreviewRouter
├── ImagePreview
├── VideoPreview
├── AudioPreview
├── TextPreview
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
