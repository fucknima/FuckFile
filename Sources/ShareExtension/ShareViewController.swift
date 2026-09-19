import UIKit
import UniformTypeIdentifiers

/// 分享扩展主控制器：接收系统分享的 `NSItemProvider`，写入共享收件箱
/// （App Group 优先，否则本扩展容器），并尽力唤醒宿主 App 或回环直传。
///
/// 行为对齐 `ShareExtension/FFShareViewController.m`；唤醒 URL 与回环直传
/// 复用 `Sources/Core/ShareBridge.swift` 的冻结接口。
@objc(FFShareViewController)
final class ShareViewController: UIViewController {

    // MARK: - 常量

    private static let appGroupIdentifier = "group.com.fucknima.fuckfile"
    private static let inboxDirectoryName = "FuckFileShareInbox"
    private static let itemSuffix = ".ffshare"
    private static let defaultTypeIdentifier = "public.data"
    private static let failureDisplayDuration: TimeInterval = 1.5

    private enum ShareExtensionError: LocalizedError {
        case inboxUnavailable
        case noRepresentation
        case emptyContent

        var errorDescription: String? {
            switch self {
            case .inboxUnavailable: return "无法创建共享收件箱"
            case .noRepresentation: return "没有可读取的文件内容"
            case .emptyContent: return "没有拿到文件内容"
            }
        }
    }

    // MARK: - UI

    private let spinner = UIActivityIndicatorView(style: .medium)
    private let statusLabel = UILabel()

    // MARK: - 状态

    private let sessionID = UUID().uuidString
    private var started = false
    private var usesAppGroup = false
    private var inboxPath: String?

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        view.addSubview(spinner)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "正在导入到 FuckFile…"
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.isAccessibilityElement = true
        statusLabel.accessibilityLabel = "正在导入到 FuckFile"
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),
            statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 14),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        processInputItems()
    }

    // MARK: - 输入处理

    private func processInputItems() {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty else {
            finish(imported: 0, firstError: nil)
            return
        }
        guard let inbox = prepareInbox() else {
            finish(imported: 0, firstError: ShareExtensionError.inboxUnavailable)
            return
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var imported = 0
        var firstError: Error?

        for provider in providers {
            group.enter()
            load(provider, inbox: inbox) { error in
                lock.lock()
                if let error {
                    if firstError == nil { firstError = error }
                } else {
                    imported += 1
                }
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.finish(imported: imported, firstError: firstError)
        }
    }

    // MARK: - Provider 读取

    private func load(_ provider: NSItemProvider, inbox: String, completion: @escaping (Error?) -> Void) {
        if let representationType = fileRepresentationType(for: provider) {
            // 大文件优先 in-place：直接流式读原文件，扩展不再复制一份（省磁盘与时间）。
            provider.loadInPlaceFileRepresentation(forTypeIdentifier: representationType) { url, _, _ in
                guard let url else {
                    self.loadCopiedRepresentation(provider: provider,
                                                  representationType: representationType,
                                                  inbox: inbox,
                                                  completion: completion)
                    return
                }
                completion(self.storeInPlace(url: url,
                                             name: provider.suggestedName ?? "",
                                             typeIdentifier: representationType,
                                             inbox: inbox))
            }
            return
        }

        let fileURLType = UTType.fileURL.identifier
        if provider.hasItemConformingToTypeIdentifier(fileURLType) {
            provider.loadItem(forTypeIdentifier: fileURLType, options: nil) { item, error in
                guard let url = item as? URL, url.isFileURL, error == nil else {
                    completion(error ?? ShareExtensionError.emptyContent)
                    return
                }
                let name = url.lastPathComponent.isEmpty ? (provider.suggestedName ?? "") : url.lastPathComponent
                completion(self.storeSource(url: url, name: name, typeIdentifier: fileURLType,
                                            inbox: inbox, mayMove: false))
            }
            return
        }

        guard let fallbackType = provider.registeredTypeIdentifiers.first else {
            completion(ShareExtensionError.noRepresentation)
            return
        }
        provider.loadDataRepresentation(forTypeIdentifier: fallbackType) { data, error in
            guard let data, error == nil else {
                completion(error ?? ShareExtensionError.emptyContent)
                return
            }
            completion(self.storeData(data,
                                     name: provider.suggestedName ?? "",
                                     typeIdentifier: fallbackType,
                                     inbox: inbox))
        }
    }

    private func loadCopiedRepresentation(provider: NSItemProvider,
                                          representationType: String,
                                          inbox: String,
                                          completion: @escaping (Error?) -> Void) {
        provider.loadFileRepresentation(forTypeIdentifier: representationType) { url, error in
            guard let url, error == nil else {
                completion(error ?? ShareExtensionError.emptyContent)
                return
            }
            completion(self.storeSource(url: url,
                                       name: provider.suggestedName ?? "",
                                       typeIdentifier: representationType,
                                       inbox: inbox,
                                       mayMove: true))
        }
    }

    /// 遍历注册类型，跳过 URL 表示，优先 data/content。
    private func fileRepresentationType(for provider: NSItemProvider) -> String? {
        for identifier in provider.registeredTypeIdentifiers {
            guard let type = UTType(identifier) else { continue }
            if type.conforms(to: .url) { continue }
            if type.conforms(to: .data) || type.conforms(to: .content) { return identifier }
        }
        return nil
    }

    // MARK: - 收件箱

    /// App Group 收件箱优先；无 group 权限时退回本扩展容器 Documents。
    private func prepareInbox() -> String? {
        let manager = FileManager.default
        let root: URL?
        if let group = manager.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier) {
            root = group
            usesAppGroup = true
        } else {
            root = manager.urls(for: .documentDirectory, in: .userDomainMask).first
            usesAppGroup = false
        }
        guard let root else { return nil }

        let inbox = root.appendingPathComponent(Self.inboxDirectoryName, isDirectory: true)
        do {
            try manager.createDirectory(at: inbox, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        inboxPath = inbox.path
        return inbox.path
    }

    private func storeSource(url sourceURL: URL, name: String, typeIdentifier: String,
                             inbox: String, mayMove: Bool) -> Error? {
        let resolvedName = name.isEmpty ? sourceURL.lastPathComponent : name
        return storeItem(inbox: inbox, name: resolvedName, typeIdentifier: typeIdentifier) { payloadURL in
            let scoped = sourceURL.startAccessingSecurityScopedResource()
            defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
            if mayMove {
                // 系统给的临时副本与扩展同卷：move 是瞬时的，省掉 200MB+ 复制，
                // 把扩展的时间预算留给直传（大文件就是在这里被系统回收的）。
                do {
                    try FileManager.default.moveItem(at: sourceURL, to: payloadURL)
                } catch {
                    try FileManager.default.copyItem(at: sourceURL, to: payloadURL)
                }
            } else {
                try FileManager.default.copyItem(at: sourceURL, to: payloadURL)
            }
            return (try? payloadURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
    }

    private func storeData(_ data: Data, name: String, typeIdentifier: String, inbox: String) -> Error? {
        storeItem(inbox: inbox, name: name.isEmpty ? "imported" : name, typeIdentifier: typeIdentifier) { payloadURL in
            try data.write(to: payloadURL, options: .atomic)
            return data.count
        }
    }

    /// in-place：只写 metadata（sourcePath 指向原文件），不复制 payload。
    private func storeInPlace(url sourceURL: URL, name: String,
                              typeIdentifier: String, inbox: String) -> Error? {
        let resolvedName = name.isEmpty ? sourceURL.lastPathComponent : name
        return storeItem(inbox: inbox, name: resolvedName,
                         typeIdentifier: typeIdentifier,
                         sourcePath: sourceURL.path) { _ in
            (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
    }

    /// staging `.partial-<uuid>` → 写 payload + metadata.plist → move 到 `<uuid>.ffshare`。
    private func storeItem(inbox: String,
                           name: String,
                           typeIdentifier: String,
                           sourcePath: String? = nil,
                           payloadWriter: (URL) throws -> Int) -> Error? {
        let manager = FileManager.default
        let uuid = UUID().uuidString
        let inboxURL = URL(fileURLWithPath: inbox, isDirectory: true)
        let partialURL = inboxURL.appendingPathComponent(".partial-\(uuid)", isDirectory: true)
        let finalURL = inboxURL.appendingPathComponent("\(uuid)\(Self.itemSuffix)", isDirectory: true)
        let payloadURL = partialURL.appendingPathComponent("payload")
        let metadataURL = partialURL.appendingPathComponent("metadata.plist")

        do {
            try manager.createDirectory(at: partialURL, withIntermediateDirectories: true)
            var metadata: [String: Any] = [
                "name": safeName(name),
                "type": typeIdentifier.isEmpty ? Self.defaultTypeIdentifier : typeIdentifier,
                "created": Date(),
                "size": 0,
                "session": sessionID,
            ]
            if let sourcePath {
                metadata["sourcePath"] = sourcePath
                metadata["size"] = try payloadWriter(payloadURL)
            } else {
                metadata["size"] = try payloadWriter(payloadURL)
            }
            let metadataData = try PropertyListSerialization.data(fromPropertyList: metadata,
                                                                  format: .binary,
                                                                  options: 0)
            try metadataData.write(to: metadataURL, options: .atomic)
            try manager.moveItem(at: partialURL, to: finalURL)
            return nil
        } catch {
            try? manager.removeItem(at: partialURL)
            return error
        }
    }

    /// 只取最后一段路径，拒绝 `.`/`..`，防路径穿越。
    private func safeName(_ name: String) -> String {
        let last = (name as NSString).lastPathComponent
        guard !last.isEmpty, last != ".", last != ".." else { return "imported" }
        return last
    }

    // MARK: - 结束与交接

    private func finish(imported: Int, firstError: Error?) {
        spinner.stopAnimating()

        guard imported > 0 else {
            if let firstError {
                showFailure(firstError)
            } else {
                statusLabel.text = "没有收到可导入的文件"
                complete()
            }
            return
        }

        if usesAppGroup {
            // App Group 路径：文件已在共享收件箱，只需唤醒 App 去取，
            // 绝不能发 share-stream（那会让 App 空等回环连接直到超时）。
            if let firstError {
                showFailure(firstError)
                return
            }
            let inboxURL = URL(string: "\(ShareBridge.wakeScheme)://shared-inbox")!
            let opened = openWakeURL(inboxURL)
            statusLabel.text = "已接收 \(imported) 个文件，正在打开 FuckFile…"
            close(after: opened ? 0.20 : 0.80)
            return
        }

        // 无 App Group：唤醒 App 起回环服务，再把本次条目直传过去。
        let token = UUID().uuidString
        _ = openWakeURL(ShareBridge.wakeURL(token: token, count: imported))
        statusLabel.text = "正在将文件传给 FuckFile…"
        sendInbox(token: token, firstError: firstError)
    }

    private func sendInbox(token: String, firstError: Error?) {
        guard let inboxPath else {
            showFailure(firstError ?? ShareExtensionError.inboxUnavailable)
            return
        }
        let session = sessionID
        Task { @MainActor in
            do {
                let sent = try await ShareBridgeClient.sendInbox(at: inboxPath,
                                                                 sessionID: session,
                                                                 token: token)
                if let firstError {
                    self.showFailure(firstError)
                } else {
                    self.statusLabel.text = "已导入 \(sent) 个文件"
                    self.close(after: 0.15)
                }
            } catch {
                self.statusLabel.text = "直传失败：请先打开 FuckFile，然后重新分享一次"
                self.close(after: 1.2)
            }
        }
    }

    private func showFailure(_ error: Error) {
        statusLabel.text = "导入失败：\(error.localizedDescription)"
        close(after: Self.failureDisplayDuration)
    }

    private func close(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.complete()
        }
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    // MARK: - 唤醒宿主 App

    /// 分享扩展没有公开 API 打开宿主：依次尝试 responder 链、sharedApplication、
    /// extensionContext.open（公开调用在 share-services 扩展点通常被系统忽略）。
    @discardableResult
    private func openWakeURL(_ url: URL) -> Bool {
        if openViaResponderChain(url) { return true }
        if openViaSharedApplication(url) { return true }
        extensionContext?.open(url, completionHandler: nil)
        return false
    }

    private func openViaResponderChain(_ url: URL) -> Bool {
        var responder: UIResponder? = self
        while let current = responder {
            if current is UIApplication, invokeOpenURL(on: current, url: url) {
                return true
            }
            responder = current.next
        }
        return false
    }

    private func openViaSharedApplication(_ url: URL) -> Bool {
        guard let applicationClass = NSClassFromString("UIApplication") else { return false }
        let classObject = applicationClass as AnyObject
        let selector = NSSelectorFromString("sharedApplication")
        guard classObject.responds(to: selector),
              let application = classObject.perform(selector)?.takeUnretainedValue() as? UIResponder else {
            return false
        }
        return invokeOpenURL(on: application, url: url)
    }

    private func invokeOpenURL(on target: UIResponder, url: URL) -> Bool {
        let optionsSelector = NSSelectorFromString("openURL:options:completionHandler:")
        if target.responds(to: optionsSelector) {
            typealias OpenURLFunction = @convention(c) (AnyObject, Selector, AnyObject, AnyObject, AnyObject?) -> Void
            let implementation = target.method(for: optionsSelector)!
            let openURL = unsafeBitCast(implementation, to: OpenURLFunction.self)
            openURL(target, optionsSelector, url as AnyObject, [:] as NSDictionary, nil)
            return true
        }
        let simpleSelector = NSSelectorFromString("openURL:")
        if target.responds(to: simpleSelector) {
            _ = target.perform(simpleSelector, with: url)
            return true
        }
        return false
    }
}
