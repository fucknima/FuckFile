import Foundation
#if canImport(Combine)
import Combine
#endif

/// 导入总协调：Open in / 文档打开、分享扩展唤醒（回环直传）、启动/回前台收件箱回收。
/// 对齐 ObjC 版 FFAppDelegate 的行为：静默回收 + 显式导入/唤醒时提示结果。
@MainActor
final class ImportCoordinator: ObservableObject {
    static let shared = ImportCoordinator()

    struct Outcome: Identifiable {
        let id = UUID()
        let imported: Int
        let destinations: [String]
        let errors: [String]

        var revealPath: String? {
            guard let first = destinations.first else { return nil }
            return (first as NSString).deletingLastPathComponent
        }

        var message: String {
            if imported > 0 && errors.isEmpty {
                return "已导入 \(imported) 个文件。"
            }
            if imported > 0 {
                return "已导入 \(imported) 个文件，\(errors.count) 个失败：\(errors.first ?? "未知错误")"
            }
            return "导入失败：\(errors.first ?? "未知错误")"
        }
    }

    @Published var outcome: Outcome?
    /// 浏览器根页观察它并跳转到导入目录（「前往查看」）。
    @Published var pendingRevealPath: String?

    private var handledTokens: [String: Date] = [:]
    private var streamInProgress = false
    /// 扩展端直传失败原因（send-failed 唤醒回传），与服务端结果一起呈现。
    private var extensionFailure: String?
    /// 与旧版一致：同一文件 URL 5 秒内只导入一次（AppDelegate 与 .onOpenURL
    /// 可能对同一次打开各投递一遍）。
    private var recentImports: [String: Date] = [:]
    private var inFlightImports: Set<String> = []
    private static let importDedupTTL: TimeInterval = 5

    private init() {}

    // MARK: - 入口

    /// SwiftUI `.onOpenURL`：文件 URL 导入；分享唤醒 URL 走回环直传。
    func handle(_ url: URL) {
        if url.scheme?.lowercased() == ShareBridge.wakeScheme {
            if url.host?.lowercased() == "send-failed" {
                // 分享扩展直传失败：把客户端侧的真实原因显示/记录出来。
                var message = "分享扩展直传失败"
                for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                where item.name == "message" {
                    message = item.value ?? message
                }
                AppLog.tag("ShareBridge", "extension send failed: \(message)")
                extensionFailure = message
                outcome = Outcome(imported: 0, destinations: [], errors: [message])
                return
            }
            if let wake = ShareBridge.parseWakeURL(url) {
                acceptWake(token: wake.token, count: wake.count)
            } else {
                // shared-inbox 等普通唤醒：去 App Group 收件箱取文件并提示结果。
                drainInbox(showResult: true)
            }
            return
        }
        guard url.isFileURL else {
            AppLog.tag("Import", "reject non-file url=\(url.absoluteString)")
            return
        }
        let key = url.absoluteString
        pruneRecentImports()
        guard !inFlightImports.contains(key) else {
            AppLog.tag("Import", "skip in-flight=\(key)")
            return
        }
        if let recent = recentImports[key],
           Date().timeIntervalSince(recent) < Self.importDedupTTL {
            AppLog.tag("Import", "skip recent success=\(key)")
            return
        }
        inFlightImports.insert(key)
        AppLog.tag("Import", "openURL file=\(url.path)")
        let destination = Self.importedDirectory()
        Task.detached { [weak self] in
            let result = ImportService.importURL(url, displayName: nil,
                                                 toDirectory: destination)
            await self?.finish(result, key: key)
        }
    }

    /// 启动 / 回前台：静默回收 App Group 收件箱；分享唤醒时 showResult = true。
    func drainInbox(showResult: Bool = false) {
        guard !streamInProgress else { return }
        Task { [weak self] in
            let outcome = await ShareInboxService.processPending()
            guard let self else { return }
            guard outcome.imported > 0 || !outcome.errors.isEmpty else { return }
            AppLog.tag("ShareInbox", "drain imported=\(outcome.imported) errors=\(outcome.errors.count)")
            if outcome.imported > 0 {
                self.pendingRevealPath = Self.importedDirectory()
            }
            if showResult {
                self.outcome = Outcome(imported: outcome.imported,
                                       destinations: outcome.destinations,
                                       errors: outcome.errors.map(\.localizedDescription))
            }
        }
    }

    func revealImportedDirectory() {
        pendingRevealPath = Self.importedDirectory()
    }

    // MARK: - 内部

    private func acceptWake(token: String, count: Int) {
        let now = Date()
        handledTokens = handledTokens.filter { now.timeIntervalSince($0.value) < 60 }
        guard handledTokens[token] == nil else {
            AppLog.tag("ShareBridge", "ignore duplicate wake token=\(token)")
            return
        }
        handledTokens[token] = now
        streamInProgress = true
        extensionFailure = nil
        AppLog.tag("ShareBridge", "prepare loopback token=\(token) count=\(count)")
        Task { [weak self] in
            let outcome = await ShareBridgeServer.shared.prepareForToken(token,
                                                                        expectedCount: count)
            guard let self else { return }
            self.streamInProgress = false
            guard outcome.imported > 0 || !outcome.errors.isEmpty else { return }
            var errors = outcome.errors.map(\.localizedDescription)
            if let extensionFailure = self.extensionFailure {
                errors.append(extensionFailure)
                self.extensionFailure = nil
            }
            self.outcome = Outcome(imported: outcome.imported,
                                   destinations: outcome.destinations,
                                   errors: errors)
        }
    }

    private func finish(_ result: ImportResult, key: String) {
        inFlightImports.remove(key)
        if result.success, let destination = result.destinationPath {
            recentImports[key] = Date()
            outcome = Outcome(imported: 1, destinations: [destination], errors: [])
        } else {
            outcome = Outcome(imported: 0,
                              destinations: [],
                              errors: [result.error?.localizedDescription ?? "未知错误"])
        }
    }

    private func pruneRecentImports() {
        let now = Date()
        recentImports = recentImports.filter { now.timeIntervalSince($0.value) < Self.importDedupTTL }
    }

    private static func importedDirectory() -> String {
        let path = (StorageEnvironment.documentsPath as NSString)
            .appendingPathComponent("Imported")
        try? FileManager.default.createDirectory(atPath: path,
                                                 withIntermediateDirectories: true)
        return path
    }
}
