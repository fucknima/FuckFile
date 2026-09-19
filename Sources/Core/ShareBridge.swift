import Foundation

/// 本地回环直传桥：常量与唤醒 URL。
enum ShareBridge {

    static let port: UInt16 = 47551
    static let wakeScheme = "fuckfile-import"

    /// 生成 `fuckfile-import://share-stream?token=<uuid>&count=<n>`。
    static func wakeURL(token: String, count: Int) -> URL {
        var components = URLComponents()
        components.scheme = wakeScheme
        components.host = "share-stream"
        components.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "count", value: String(count)),
        ]
        return components.url!
    }

    /// 解析唤醒 URL；scheme/host 大小写不敏感，缺少 token 返回 nil。
    static func parseWakeURL(_ url: URL) -> (token: String, count: Int)? {
        guard url.scheme?.lowercased() == wakeScheme,
              url.host?.lowercased() == "share-stream" else { return nil }
        var token: String?
        var count = 0
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            switch item.name {
            case "token":
                token = item.value
            case "count":
                count = item.value.flatMap(Int.init) ?? 0
            default:
                break
            }
        }
        guard let token, !token.isEmpty else { return nil }
        return (token: token, count: count)
    }
}

enum ShareBridgeError: LocalizedError {
    case invalidArguments
    case missingToken
    case listenerUnavailable(String)
    case waitTimeout
    case connectTimeout
    case connectionClosed
    case ioTimeout
    case streamEnded
    case invalidStream(String)
    case nothingToSend
    case payloadUnreadable(String)
    case payloadTruncated(String)
    case notAcknowledged(imported: UInt32, expected: Int)
    case importFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "本地分享桥接参数无效"
        case .missingToken:
            return "分享握手缺少 token"
        case .listenerUnavailable(let detail):
            return "无法创建本地导入监听：\(detail)"
        case .waitTimeout:
            return "等待分享扩展连接超时"
        case .connectTimeout:
            return "无法连接 FuckFile 本地导入服务"
        case .connectionClosed:
            return "本地分享连接已断开"
        case .ioTimeout:
            return "本地分享读写超时"
        case .streamEnded:
            return "共享数据流中断"
        case .invalidStream(let detail):
            return "共享数据流格式无效：\(detail)"
        case .nothingToSend:
            return "没有可直传的本次共享文件"
        case .payloadUnreadable(let name):
            return "无法读取共享文件内容：\(name)"
        case .payloadTruncated(let name):
            return "共享文件内容不完整：\(name)"
        case .notAcknowledged(let imported, let expected):
            return "本地分享直传未被完整确认（\(imported)/\(expected)）"
        case .importFailed(let name):
            return "导入共享文件失败：\(name)"
        }
    }
}

/// 大端线协议（两端都是 Swift）：
/// 客户端 `UInt32 itemCount`，逐条 `UInt32 nameLen + name`、
/// `UInt32 typeLen + type`、`UInt64 dataLen + data`；服务端回 `UInt32 importedCount`。
enum ShareBridgeWire {
    static let maxItemCount = 64
    static let maxNameLength = 4096
    static let maxTypeLength = 4096
    static let maxDataLength: UInt64 = 8 * 1024 * 1024 * 1024
    static let chunkSize = 64 * 1024

    static func encodeUInt32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    static func encodeUInt64(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    static func decodeUInt32(_ data: Data) -> UInt32 {
        data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    static func decodeUInt64(_ data: Data) -> UInt64 {
        data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}

#if canImport(Network)
import Network

private let bridgeAcceptTimeout: TimeInterval = 10
private let bridgeReadWriteTimeout: TimeInterval = 10
/// 客户端连接等待：覆盖 App 冷启动后开始监听的时间。
private let bridgeConnectTimeout: TimeInterval = 1
private let bridgeClientRetryWindow: TimeInterval = 12

/// NWConnection 的 async 读写封装；所有回调都在同一个串行 queue 上。
private final class BridgeSocket {

    private let connection: NWConnection
    private let queue: DispatchQueue

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            let resume: (Result<Void, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resume(.success(()))
                case .failed(let error):
                    resume(.failure(error))
                case .cancelled:
                    resume(.failure(ShareBridgeError.connectionClosed))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                resume(.failure(ShareBridgeError.connectTimeout))
            }
        }
    }

    func cancel() {
        connection.cancel()
    }

    func readUInt32(timeout: TimeInterval) async throws -> UInt32 {
        ShareBridgeWire.decodeUInt32(try await readExactly(4, timeout: timeout))
    }

    func readUInt64(timeout: TimeInterval) async throws -> UInt64 {
        ShareBridgeWire.decodeUInt64(try await readExactly(8, timeout: timeout))
    }

    func readString(length: Int, timeout: TimeInterval) async throws -> String {
        guard length > 0 else { return "" }
        let data = try await readExactly(length, timeout: timeout)
        return String(data: data, encoding: .utf8) ?? ""
    }

    func readExactly(_ count: Int, timeout: TimeInterval) async throws -> Data {
        guard count > 0 else { return Data() }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            var buffer = Data()
            var resumed = false
            let resume: (Result<Data, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }
            func receiveNext() {
                connection.receive(minimumIncompleteLength: 1,
                                   maximumLength: count - buffer.count) { data, _, isComplete, error in
                    if let data, !data.isEmpty { buffer.append(data) }
                    if let error {
                        resume(.failure(error))
                    } else if buffer.count >= count {
                        resume(.success(buffer))
                    } else if isComplete {
                        resume(.failure(ShareBridgeError.streamEnded))
                    } else {
                        receiveNext()
                    }
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                resume(.failure(ShareBridgeError.ioTimeout))
            }
            receiveNext()
        }
    }

    func readToFile(at path: String, length: UInt64, timeout: TimeInterval) async throws {
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else {
            throw ShareBridgeError.invalidStream("无法创建临时文件")
        }
        defer { try? handle.close() }
        var remaining = length
        while remaining > 0 {
            let chunk = Int(min(remaining, UInt64(ShareBridgeWire.chunkSize)))
            let data = try await readExactly(chunk, timeout: timeout)
            do {
                try handle.write(contentsOf: data)
            } catch {
                throw ShareBridgeError.invalidStream("无法写入临时文件")
            }
            remaining -= UInt64(data.count)
        }
    }

    func write(_ data: Data, timeout: TimeInterval) async throws {
        guard !data.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            let resume: (Result<Void, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                resume(.failure(ShareBridgeError.ioTimeout))
            }
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    resume(.failure(error))
                } else {
                    resume(.success(()))
                }
            })
        }
    }
}

/// 串行闸门：同一时刻只允许一个 prepareForToken 在跑，后来的排队。
private actor ShareBridgeGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// 主机端：App 收到 wake URL 后启动，等待扩展把本次分享直传过来。
final class ShareBridgeServer {

    static let shared = ShareBridgeServer()

    private static let queue = DispatchQueue(label: "ff.local-share-server")
    private static let gate = ShareBridgeGate()

    private init() {}

    func prepareForToken(_ token: String, expectedCount: Int) async -> SharedImportOutcome {
        var outcome = SharedImportOutcome()
        guard !token.isEmpty else {
            outcome.errors.append(ShareBridgeError.missingToken)
            return outcome
        }
        await Self.gate.acquire()
        outcome = await serve(token: token, expectedCount: expectedCount)
        await Self.gate.release()
        return outcome
    }

    private func serve(token: String, expectedCount: Int) async -> SharedImportOutcome {
        var outcome = SharedImportOutcome()

        let socket: BridgeSocket
        do {
            socket = try await acceptSocket()
        } catch let error as ShareBridgeError {
            AppLog.tag("ShareBridge", "accept FAIL token=\(token) error=\(error.localizedDescription)")
            outcome.errors.append(error)
            return outcome
        } catch {
            AppLog.tag("ShareBridge", "accept FAIL token=\(token) error=\(error.localizedDescription)")
            outcome.errors.append(ShareBridgeError.connectionClosed)
            return outcome
        }

        do {
            outcome = try await receiveItems(from: socket, token: token, expectedCount: expectedCount)
        } catch let error as ShareBridgeError {
            outcome.errors.append(error)
        } catch {
            outcome.errors.append(ShareBridgeError.connectionClosed)
        }

        // 即使失败也要回 ack（0），对齐 ObjC 的收尾行为。
        try? await socket.write(ShareBridgeWire.encodeUInt32(UInt32(outcome.imported)),
                                timeout: bridgeReadWriteTimeout)
        socket.cancel()
        AppLog.tag("ShareBridge",
                   "loopback receive token=\(token) imported=\(outcome.imported) errors=\(outcome.errors.count)")
        return outcome
    }

    private func acceptSocket() async throws -> BridgeSocket {
        let connection = try await acceptConnection()
        let socket = BridgeSocket(connection: connection, queue: Self.queue)
        do {
            try await socket.start(timeout: bridgeAcceptTimeout)
        } catch {
            socket.cancel()
            throw (error as? ShareBridgeError) ?? ShareBridgeError.connectionClosed
        }
        return socket
    }

    private func acceptConnection() async throws -> NWConnection {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: ShareBridge.port)!)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw ShareBridgeError.listenerUnavailable(error.localizedDescription)
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWConnection, Error>) in
            var resumed = false
            let resume: (Result<NWConnection, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                listener.cancel()
                continuation.resume(with: result)
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    resume(.failure(ShareBridgeError.listenerUnavailable(error.localizedDescription)))
                }
            }
            listener.newConnectionHandler = { connection in
                resume(.success(connection))
            }
            listener.start(queue: Self.queue)
            Self.queue.asyncAfter(deadline: .now() + bridgeAcceptTimeout) {
                resume(.failure(ShareBridgeError.waitTimeout))
            }
        }
    }

    private func receiveItems(from socket: BridgeSocket,
                              token: String,
                              expectedCount: Int) async throws -> SharedImportOutcome {
        var outcome = SharedImportOutcome()

        let count = Int(try await socket.readUInt32(timeout: bridgeReadWriteTimeout))
        guard count > 0, count <= ShareBridgeWire.maxItemCount else {
            throw ShareBridgeError.invalidStream("条目数量无效")
        }
        if expectedCount > 0 && count != expectedCount {
            AppLog.tag("ShareBridge", "count differs wake=\(expectedCount) stream=\(count)")
        }

        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FFShareBridge-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        } catch {
            throw ShareBridgeError.invalidStream("无法准备导入暂存目录")
        }
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        let destinationDirectory = (StorageEnvironment.documentsPath as NSString)
            .appendingPathComponent("Imported")
        do {
            try FileManager.default.createDirectory(atPath: destinationDirectory,
                                                    withIntermediateDirectories: true)
        } catch {
            throw ShareBridgeError.invalidStream("无法准备导入目录")
        }

        for index in 0..<count {
            let nameLength = Int(try await socket.readUInt32(timeout: bridgeReadWriteTimeout))
            guard nameLength > 0, nameLength <= ShareBridgeWire.maxNameLength else {
                throw ShareBridgeError.invalidStream("文件名长度无效")
            }
            let typeLength = Int(try await socket.readUInt32(timeout: bridgeReadWriteTimeout))
            guard typeLength <= ShareBridgeWire.maxTypeLength else {
                throw ShareBridgeError.invalidStream("文件类型长度无效")
            }
            let dataLength = try await socket.readUInt64(timeout: bridgeReadWriteTimeout)
            guard dataLength <= ShareBridgeWire.maxDataLength else {
                throw ShareBridgeError.invalidStream("文件过大")
            }

            let rawName = try await socket.readString(length: nameLength, timeout: bridgeReadWriteTimeout)
            _ = try await socket.readString(length: typeLength, timeout: bridgeReadWriteTimeout)
            let lastComponent = (rawName as NSString).lastPathComponent
            let name = lastComponent.isEmpty ? "imported" : lastComponent

            let stagingPath = stagingRoot.appendingPathComponent("\(index)-\(name)").path
            try await socket.readToFile(at: stagingPath, length: dataLength, timeout: bridgeReadWriteTimeout)

            let result = ImportService.importURL(URL(fileURLWithPath: stagingPath),
                                                 displayName: name,
                                                 toDirectory: destinationDirectory)
            if result.success {
                if let destination = result.destinationPath {
                    outcome.destinations.append(destination)
                }
                AppLog.tag("ShareBridge", "import OK name=\(name) dest=\(result.destinationPath ?? "?")")
            } else {
                let error = result.error ?? ShareBridgeError.importFailed(name)
                outcome.errors.append(error)
                AppLog.tag("ShareBridge", "import FAIL name=\(name) error=\(error.localizedDescription)")
            }
        }

        outcome.imported = outcome.destinations.count
        return outcome
    }
}

/// 扩展端：把本次 session 的收件箱条目直传给主机。
enum ShareBridgeClient {

    private struct Item {
        let directory: String
        let payloadPath: String
        let name: String
        let type: String
        let size: UInt64
    }

    static func sendInbox(at inboxPath: String, sessionID: String, token: String) async throws -> Int {
        guard !inboxPath.isEmpty, !sessionID.isEmpty, !token.isEmpty else {
            throw ShareBridgeError.invalidArguments
        }
        let items = collectItems(inboxPath: inboxPath, sessionID: sessionID)
        guard !items.isEmpty else {
            throw ShareBridgeError.nothingToSend
        }

        // 对齐 ObjC 版 FFConnectLoopback：App 冷启动期间要反复重试连接，
        // 单次连接失败（connection refused / waiting）不能直接放弃。
        let queue = DispatchQueue(label: "ff.local-share-client")
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback),
                                           port: NWEndpoint.Port(rawValue: ShareBridge.port)!)
        var socket: BridgeSocket?
        var lastError: Error?
        let deadline = Date().addingTimeInterval(bridgeClientRetryWindow)
        while Date() < deadline {
            let connection = NWConnection(to: endpoint, using: .tcp)
            let candidate = BridgeSocket(connection: connection, queue: queue)
            do {
                try await candidate.start(timeout: bridgeConnectTimeout)
                socket = candidate
                break
            } catch {
                lastError = error
                candidate.cancel()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        guard let socket else {
            throw (lastError as? ShareBridgeError) ?? ShareBridgeError.connectTimeout
        }

        do {
            try await send(items: items, over: socket)
            let acknowledged = try await socket.readUInt32(timeout: bridgeReadWriteTimeout)
            guard Int(acknowledged) == items.count else {
                throw ShareBridgeError.notAcknowledged(imported: acknowledged, expected: items.count)
            }
        } catch let error as ShareBridgeError {
            socket.cancel()
            throw error
        } catch {
            socket.cancel()
            throw ShareBridgeError.connectionClosed
        }
        socket.cancel()

        for item in items {
            try? FileManager.default.removeItem(atPath: item.directory)
        }
        AppLog.tag("ShareBridge", "loopback send session=\(sessionID) sent=\(items.count)")
        return items.count
    }

    private static func send(items: [Item], over socket: BridgeSocket) async throws {
        try await socket.write(ShareBridgeWire.encodeUInt32(UInt32(items.count)),
                               timeout: bridgeReadWriteTimeout)
        for item in items {
            let nameData = Data(item.name.utf8)
            let typeData = Data(item.type.utf8)
            var header = Data()
            header.append(ShareBridgeWire.encodeUInt32(UInt32(nameData.count)))
            header.append(ShareBridgeWire.encodeUInt32(UInt32(typeData.count)))
            header.append(ShareBridgeWire.encodeUInt64(item.size))
            try await socket.write(header, timeout: bridgeReadWriteTimeout)
            try await socket.write(nameData, timeout: bridgeReadWriteTimeout)
            try await socket.write(typeData, timeout: bridgeReadWriteTimeout)

            guard let handle = FileHandle(forReadingAtPath: item.payloadPath) else {
                throw ShareBridgeError.payloadUnreadable(item.name)
            }
            defer { try? handle.close() }
            var remaining = item.size
            while remaining > 0 {
                let chunk: Data
                do {
                    chunk = try handle.read(upToCount: Int(min(remaining,
                                                             UInt64(ShareBridgeWire.chunkSize)))) ?? Data()
                } catch {
                    throw ShareBridgeError.payloadUnreadable(item.name)
                }
                guard !chunk.isEmpty else {
                    throw ShareBridgeError.payloadTruncated(item.name)
                }
                try await socket.write(chunk, timeout: bridgeReadWriteTimeout)
                remaining -= UInt64(chunk.count)
            }
        }
    }

    private static func collectItems(inboxPath: String, sessionID: String) -> [Item] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: inboxPath) else { return [] }
        var items: [Item] = []
        for name in names {
            guard name.hasSuffix(ShareInboxService.itemSuffix), !name.hasPrefix(".partial-") else {
                continue
            }
            let directory = (inboxPath as NSString).appendingPathComponent(name)
            let payloadPath = (directory as NSString).appendingPathComponent("payload")
            let metadataPath = (directory as NSString).appendingPathComponent("metadata.plist")
            let metadata = readMetadata(atPath: metadataPath)
            guard let session = metadata["session"] as? String, session == sessionID else { continue }

            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: payloadPath, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  let attributes = try? manager.attributesOfItem(atPath: payloadPath),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value else { continue }

            let rawName = metadata["name"] as? String ?? ""
            let lastComponent = (rawName as NSString).lastPathComponent
            let displayName = lastComponent.isEmpty ? "imported" : lastComponent
            let rawType = metadata["type"] as? String ?? ""
            let type = rawType.isEmpty ? "public.data" : rawType
            items.append(Item(directory: directory,
                              payloadPath: payloadPath,
                              name: displayName,
                              type: type,
                              size: size))
        }
        items.sort { $0.name < $1.name }
        return items
    }

    private static func readMetadata(atPath path: String) -> [String: Any] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let plist = try? PropertyListSerialization.propertyList(from: data,
                                                                      options: [],
                                                                      format: nil),
              let metadata = plist as? [String: Any] else { return [:] }
        return metadata
    }
}
#endif
