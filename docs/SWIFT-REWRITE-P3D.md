# Swift 重写 · 阶段 3d 并行约定（导入复刻）

目标：把原项目的「从别处导入」完整复刻到 Swift 版——分享扩展、App Group 收件箱、
回环直传桥、Open in / 文档打开、启动/回前台自动收件。行为对齐 ObjC 版。

## 文件归属

| 归属 | 文件 |
|---|---|
| A 导入核心 | `Sources/Core/ImportService.swift`、`Sources/Core/ShareInboxService.swift` |
| B 桥与扩展 | `Sources/Core/ShareBridge.swift`、`Sources/ShareExtension/ShareViewController.swift` |
| 集成方（主） | `Sources/App/FuckFileApp.swift`、`Sources/App/RootView.swift`、Makefile、`.github/workflows/build.yml`、`ShareExtension/Info.plist`、docs |

禁止：改他人名下文件、改 `src/`、执行任何写 git 的命令。

## 关键常量（与 ObjC 一致）

- App Group：`group.com.fucknima.fuckfile`
- 收件箱目录名：`FuckFileShareInbox`
- 条目后缀：`.ffshare`（条目结构：`<uuid>.ffshare/payload` + `metadata.plist`，
  键 `name`/`type`/`created`/`size`/`session`）
- 回环端口：`47551`（仅 127.0.0.1）
- 唤醒 URL：`fuckfile-import://share-stream?token=<uuid>&count=<n>`

## 冻结接口

### A

```swift
struct ImportResult {
    let success: Bool
    let sourcePath: String
    let destinationPath: String?
    let error: Error?
}

enum ImportService {
    /// 导入外部 URL（可能带 security scope、需 NSFileCoordinator）到 directory：
    /// 先 staging 复制，成功后原子 move；重名唯一化（"name 2"…）；目录源也可。
    /// 同步阻塞，调用方放后台。
    static func importURL(_ url: URL, displayName: String?, toDirectory directory: String) -> ImportResult
}

struct SharedImportOutcome {
    var imported: Int = 0
    var destinations: [String] = []
    var errors: [Error] = []
}

enum ShareInboxService {
    static let appGroupIdentifier = "group.com.fucknima.fuckfile"
    static let inboxDirectoryName = "FuckFileShareInbox"
    static let itemSuffix = ".ffshare"
    /// App Group 收件箱路径；无 group 权限返回 nil。
    static var appGroupInboxPath: String? { get }
    /// 扫描收件箱（App Group + App 自身 Documents 兜底），把每个条目导入
    /// Documents/Imported；成功后删除条目，失败保留（不丢数据）。
    /// 忽略 `.partial-*` 临时目录；`created` 在 180s 内且 session 非空且
    /// 不是 App Group 路径的条目跳过（避免与扩展直传抢文件，对齐 ObjC）。
    static func processPending() async -> SharedImportOutcome
}
```

### B

```swift
enum ShareBridge {
    static let port: UInt16 = 47551
    static let wakeScheme = "fuckfile-import"
    static func wakeURL(token: String, count: Int) -> URL
    static func parseWakeURL(_ url: URL) -> (token: String, count: Int)?
}

/// 主机端：App 收到 wake URL 后启动，等待扩展直传。
final class ShareBridgeServer {
    static let shared: ShareBridgeServer
    /// 监听 127.0.0.1:47551；5s 等连接、10s 读写超时；把收到的条目写入
    /// Documents/Imported 并返回结果。同一时刻只允许一个实例。
    func prepareForToken(_ token: String, expectedCount: Int) async -> SharedImportOutcome
}

/// 扩展端：把本次 session 的条目直传给主机。
enum ShareBridgeClient {
    /// 成功返回发送条目数；连不上/超时/对端错误抛中文 LocalizedError。
    static func sendInbox(at inboxPath: String, sessionID: String, token: String) async throws -> Int
}
```

线协议（两端都是 Swift，自定义即可）：客户端先发 `UInt32 itemCount`（大端），
逐条发 `UInt32 nameLen + name`、`UInt32 typeLen + type`、`UInt64 dataLen + data`；
服务端导入后回 `UInt32 importedCount`。

### 分享扩展（appex）

`Sources/ShareExtension/ShareViewController.swift`，类名 `ShareViewController`
（Info.plist 的 `NSExtensionPrincipalClass` 由集成方改为 `FuckFileShare.ShareViewController`）。
行为照抄 `ShareExtension/FFShareViewController.m`：

1. 展示「正在导入到 FuckFile…」状态页。
2. 遍历 `extensionContext.inputItems` 的 `NSItemProvider`：
   - 优先 `loadFileRepresentation(forTypeIdentifier:)`（跳过 URL 类型表示）；
   - 其次 `loadItem(forTypeIdentifier: UTType.fileURL)`（file URL）；
   - 兜底 `loadDataRepresentation`（`registeredTypeIdentifiers.first`）。
3. 每个条目：staging 目录 `.partial-<uuid>` → 写 `payload` + `metadata.plist` →
   `moveItem` 到 `<uuid>.ffshare`；文件名取 `provider.suggestedName`/URL 名，
   走 `lastPathComponent` 防路径穿越。
4. 有 App Group → 直接落 App Group 收件箱，然后打开 wake URL 唤醒主机
   （先沿 responder 链找 UIApplication 调 `openURL:options:completionHandler:`，
   再 `UIApplication.shared`，最后 `extensionContext.openURL`）；
   无 App Group → 落自己的容器，先打开 wake URL，再 `ShareBridgeClient` 直传。
5. 全部完成/失败后 `extensionContext.completeRequestReturningItems:@[]`；
   失败显示「导入失败」文案。

## 行为参考（只读）

`ShareExtension/FFShareViewController.m`、`src/FFLocalShareBridge.m`、
`src/FFLocalShareBridgeServer.m`、`src/FFLocalShareBridgeClient.m`、
`src/FFSharedInboxService.m`、`src/FFImportService.m`、`src/FFAppDelegate.m`（openURL/唤醒/去重）。

## 验收

- 只写自己名下文件；Swift 5 / iOS 16；不用 iOS 17+ API。
- 纯 Foundation 部分（ImportService/ShareInboxService/ShareBridge 协议解析）
  尝试 `/opt/swift/usr/bin/swiftc -typecheck -swift-version 5`；其余 `-parse`。
- 交付说明：文件、公开 API、假设、集成方接手点。
