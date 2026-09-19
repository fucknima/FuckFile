import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

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

/// 线协议（与老版 ObjC 完全一致）：
/// 客户端 `"FFSHARE1"` + `UInt32 tokenLen + token` + `UInt32 itemCount`，
/// 逐条 `UInt32 nameLen + name`、`UInt32 typeLen + type`、`UInt64 dataLen + data`；
/// 服务端回 `UInt32 importedCount`。全部大端。
enum ShareBridgeWire {
    static let magic: [UInt8] = Array("FFSHARE1".utf8)
    static let maxItemCount = 64
    static let maxNameLength = 4096
    static let maxTypeLength = 4096
    static let maxDataLength: UInt64 = 8 * 1024 * 1024 * 1024
    static let chunkSize = 64 * 1024
}

// MARK: - 超时与套接字参数（对齐老版 FFLocalShareBridge）

private let bridgeAcceptTimeoutMs: Int32 = 8000      // 老版 select 5s，冷启动放宽
private let bridgeIOTimeoutSeconds: Int = 10         // SO_RCVTIMEO / SO_SNDTIMEO
private let bridgeConnectAttempts = 120              // 老版 60 × 50ms，冷启动放宽到 6s
private let bridgeConnectIntervalMicros: UInt32 = 50_000

private let ffSockStream: Int32 = {
#if canImport(Darwin)
    return SOCK_STREAM
#else
    return Int32(SOCK_STREAM.rawValue)
#endif
}()

private func ffLoopbackAddress() -> sockaddr_in {
    var address = sockaddr_in()
#if canImport(Darwin)
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
#endif
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = ShareBridge.port.bigEndian
    address.sin_addr = in_addr(s_addr: UInt32(INADDR_LOOPBACK).bigEndian)
    return address
}

private func ffReadAll(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ length: Int) -> Bool {
    var offset = 0
    while offset < length {
        let got = read(fd, buffer.advanced(by: offset), length - offset)
        if got < 0 {
            if errno == EINTR { continue }
            return false
        }
        if got == 0 { return false }
        offset += got
    }
    return true
}

private func ffWriteAllRaw(_ fd: Int32, _ buffer: UnsafeRawPointer, _ length: Int) -> Bool {
    var offset = 0
    while offset < length {
        let written = write(fd, buffer.advanced(by: offset), length - offset)
        if written < 0 {
            if errno == EINTR { continue }
            return false
        }
        if written == 0 { return false }
        offset += written
    }
    return true
}

private func ffWriteAll(_ fd: Int32, _ data: Data) -> Bool {
    guard !data.isEmpty else { return true }
    return data.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return true }
        return ffWriteAllRaw(fd, base, data.count)
    }
}

private func ffConfigureTimeouts(_ fd: Int32) {
    var timeout = timeval(tv_sec: bridgeIOTimeoutSeconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
}

// MARK: - 主机端

/// 主机端：App 收到 wake URL 后监听 127.0.0.1:47551，等扩展把本次分享直传过来。
/// 实现与老版 `FFLocalShareBridgeServer` 一致（POSIX socket + select/accept + 固定超时），
/// 每次分享独立 bind/listen/close，避免 Network.framework 的连接状态差异。
final class ShareBridgeServer {

    static let shared = ShareBridgeServer()

    private let queue = DispatchQueue(label: "ff.local-share-server")

    private init() {}

    func prepareForToken(_ token: String, expectedCount: Int) async -> SharedImportOutcome {
        guard !token.isEmpty else {
            var outcome = SharedImportOutcome()
            outcome.errors.append(ShareBridgeError.missingToken)
            return outcome
        }
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.serve(token: token,
                                                          expectedCount: expectedCount))
            }
        }
    }

    private func serve(token: String, expectedCount: Int) -> SharedImportOutcome {
        var outcome = SharedImportOutcome()

        let listener = socket(AF_INET, ffSockStream, 0)
        guard listener >= 0 else {
            outcome.errors.append(ShareBridgeError.listenerUnavailable("无法创建套接字"))
            return outcome
        }
        var reuse: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse,
                   socklen_t(MemoryLayout<Int32>.size))

        var address = ffLoopbackAddress()
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(listener, 1) == 0 else {
            let code = errno
            close(listener)
            AppLog.tag("ShareBridge", "listen FAIL token=\(token) errno=\(code)")
            outcome.errors.append(ShareBridgeError.listenerUnavailable("端口被占用（errno \(code)）"))
            return outcome
        }
        defer { close(listener) }
        AppLog.tag("ShareBridge", "listener ready port=\(ShareBridge.port) token=\(token)")

        var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, bridgeAcceptTimeoutMs)
        guard ready > 0 else {
            AppLog.tag("ShareBridge", "accept timeout token=\(token)")
            outcome.errors.append(ShareBridgeError.waitTimeout)
            return outcome
        }

        let client = accept(listener, nil, nil)
        guard client >= 0 else {
            outcome.errors.append(ShareBridgeError.listenerUnavailable("接受连接失败"))
            return outcome
        }
        defer { close(client) }
        ffConfigureTimeouts(client)
        AppLog.tag("ShareBridge", "accepted token=\(token) expected=\(expectedCount)")

        guard let count = readHandshake(client: client, token: token) else {
            outcome.errors.append(ShareBridgeError.invalidStream("握手失败或 token 不匹配"))
            _ = writeAck(client: client, imported: 0)
            return outcome
        }
        AppLog.tag("ShareBridge", "items count=\(count) wake=\(expectedCount)")

        let importedDirectory = (StorageEnvironment.documentsPath as NSString)
            .appendingPathComponent("Imported")
        do {
            try FileManager.default.createDirectory(atPath: importedDirectory,
                                                    withIntermediateDirectories: true)
        } catch {
            outcome.errors.append(ShareBridgeError.invalidStream(
                "无法创建导入目录：\(error.localizedDescription)"))
            _ = writeAck(client: client, imported: 0)
            return outcome
        }

        var ok = true
        var buffer = [UInt8](repeating: 0, count: ShareBridgeWire.chunkSize)
        for _ in 0..<count {
            var nameLengthNetwork: UInt32 = 0
            var typeLengthNetwork: UInt32 = 0
            var dataLengthNetwork: UInt64 = 0
            guard ffReadAll(client, &nameLengthNetwork, 4),
                  ffReadAll(client, &typeLengthNetwork, 4),
                  ffReadAll(client, &dataLengthNetwork, 8) else { ok = false; break }
            let nameLength = Int(UInt32(bigEndian: nameLengthNetwork))
            let typeLength = Int(UInt32(bigEndian: typeLengthNetwork))
            let dataLength = UInt64(bigEndian: dataLengthNetwork)
            guard nameLength > 0, nameLength <= ShareBridgeWire.maxNameLength,
                  typeLength <= ShareBridgeWire.maxTypeLength,
                  dataLength <= ShareBridgeWire.maxDataLength else { ok = false; break }

            var nameBytes = [UInt8](repeating: 0, count: nameLength)
            guard ffReadAll(client, &nameBytes, nameLength) else { ok = false; break }
            if typeLength > 0 {
                var typeBytes = [UInt8](repeating: 0, count: typeLength)
                guard ffReadAll(client, &typeBytes, typeLength) else { ok = false; break }
            }
            let rawName = String(bytes: nameBytes, encoding: .utf8) ?? ""
            let name = (rawName as NSString).lastPathComponent
            let displayName = name.isEmpty ? "imported" : name

            // 直接流式写入 Imported 的唯一目标（1 倍磁盘占用）：大文件不再
            // 先写 tmp 再复制一遍，避免设备空间不足导致「数据流中断」。
            let destinationPath = FileOperations.uniqueDestination(in: importedDirectory,
                                                                   preferredName: displayName)
            let output = open(destinationPath,
                              O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard output >= 0 else {
                let code = errno
                outcome.errors.append(ShareBridgeError.invalidStream(
                    "无法创建目标文件（errno \(code)）：\(displayName)"))
                ok = false
                break
            }

            var failure: String?
            var remaining = dataLength
            var writtenBytes: UInt64 = 0
            while remaining > 0 {
                let wanted = Int(min(UInt64(buffer.count), remaining))
                guard ffReadAll(client, &buffer, wanted) else {
                    failure = "读取数据流失败（已收 \(writtenBytes)/\(dataLength) 字节）"
                    break
                }
                guard ffWriteAllRaw(output, buffer, wanted) else {
                    let code = errno
                    failure = code == ENOSPC
                        ? "磁盘空间不足，无法保存 \(displayName)"
                        : "写入文件失败（errno \(code)）：\(displayName)"
                    break
                }
                remaining -= UInt64(wanted)
                writtenBytes += UInt64(wanted)
            }
            close(output)
            guard failure == nil else {
                try? FileManager.default.removeItem(atPath: destinationPath)
                outcome.errors.append(ShareBridgeError.invalidStream(failure ?? "写入失败"))
                ok = false
                break
            }
            outcome.destinations.append(destinationPath)
            AppLog.tag("ShareBridge",
                       "import OK name=\(displayName) bytes=\(writtenBytes) dest=\(destinationPath)")
        }
        outcome.imported = outcome.destinations.count
        _ = writeAck(client: client, imported: UInt32(outcome.imported))
        if !ok && outcome.errors.isEmpty {
            outcome.errors.append(ShareBridgeError.invalidStream("共享数据流中断或格式无效"))
        }
        AppLog.tag("ShareBridge",
                   "loopback receive token=\(token) imported=\(outcome.imported) errors=\(outcome.errors.count)")
        return outcome
    }

    /// 读握手（magic + token + count），校验 token；失败返回 nil。
    private func readHandshake(client: Int32, token: String) -> Int? {
        var magic = [UInt8](repeating: 0, count: ShareBridgeWire.magic.count)
        var tokenLengthNetwork: UInt32 = 0
        var countNetwork: UInt32 = 0
        guard ffReadAll(client, &magic, magic.count),
              magic == ShareBridgeWire.magic,
              ffReadAll(client, &tokenLengthNetwork, 4),
              ffReadAll(client, &countNetwork, 4) else { return nil }

        let tokenLength = Int(UInt32(bigEndian: tokenLengthNetwork))
        let count = Int(UInt32(bigEndian: countNetwork))
        guard tokenLength > 0, tokenLength <= ShareBridgeWire.maxNameLength,
              count > 0, count <= ShareBridgeWire.maxItemCount else { return nil }

        var tokenBytes = [UInt8](repeating: 0, count: tokenLength)
        guard ffReadAll(client, &tokenBytes, tokenLength),
              let received = String(bytes: tokenBytes, encoding: .utf8),
              received == token else { return nil }
        return count
    }

    private func writeAck(client: Int32, imported: UInt32) -> Bool {
        var ack = imported.bigEndian
        return ffWriteAllRaw(client, &ack, 4)
    }
}

// MARK: - 扩展端

/// 扩展端：把本次 session 的收件箱条目直传给主机（POSIX socket，与老版一致）。
enum ShareBridgeClient {

    private struct Item {
        let directory: String
        let payloadPath: String
        let name: String
        let type: String
        let size: UInt64
        let needsSecurityScope: Bool
    }

    static func sendInbox(at inboxPath: String, sessionID: String, token: String) async throws -> Int {
        guard !inboxPath.isEmpty, !sessionID.isEmpty, !token.isEmpty else {
            throw ShareBridgeError.invalidArguments
        }
        let items = collectItems(inboxPath: inboxPath, sessionID: sessionID)
        guard !items.isEmpty else { throw ShareBridgeError.nothingToSend }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try send(items: items, token: token,
                                                            sessionID: sessionID))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func send(items: [Item], token: String, sessionID: String) throws -> Int {
        let fd = connectLoopback()
        guard fd >= 0 else { throw ShareBridgeError.connectTimeout }
        defer { close(fd) }
        ffConfigureTimeouts(fd)

        let tokenData = Data(token.utf8)
        var tokenLength = UInt32(tokenData.count).bigEndian
        var count = UInt32(items.count).bigEndian
        var ok = ffWriteAllRaw(fd, ShareBridgeWire.magic, ShareBridgeWire.magic.count)
        ok = ok && ffWriteAllRaw(fd, &tokenLength, 4)
        ok = ok && ffWriteAllRaw(fd, &count, 4)
        ok = ok && ffWriteAll(fd, tokenData)

        let buffer = [UInt8](repeating: 0, count: ShareBridgeWire.chunkSize)
        if ok {
            for item in items {
                let nameData = Data(item.name.utf8)
                let typeData = Data(item.type.utf8)
                var nameLength = UInt32(nameData.count).bigEndian
                var typeLength = UInt32(typeData.count).bigEndian
                var fileLength = item.size.bigEndian
                ok = ffWriteAllRaw(fd, &nameLength, 4)
                    && ffWriteAllRaw(fd, &typeLength, 4)
                    && ffWriteAllRaw(fd, &fileLength, 8)
                    && ffWriteAll(fd, nameData)
                    && ffWriteAll(fd, typeData)
                if !ok { break }

                // in-place 条目直接读原文件：需要 security scope 包裹整段读取。
#if canImport(Darwin)
                let scopedURL = URL(fileURLWithPath: item.payloadPath)
                let scoped = item.needsSecurityScope && scopedURL.startAccessingSecurityScopedResource()
                defer { if scoped { scopedURL.stopAccessingSecurityScopedResource() } }
#endif
                guard let handle = FileHandle(forReadingAtPath: item.payloadPath) else {
                    throw ShareBridgeError.payloadUnreadable(item.name)
                }
                defer { try? handle.close() }
                var remaining = item.size
                while remaining > 0 {
                    let chunk = (try? handle.read(upToCount: Int(min(remaining,
                                                                     UInt64(buffer.count))))) ?? nil
                    guard let chunk, !chunk.isEmpty else {
                        throw ShareBridgeError.payloadTruncated(item.name)
                    }
                    guard ffWriteAll(fd, chunk) else { ok = false; break }
                    remaining -= UInt64(chunk.count)
                }
                if !ok { break }
            }
        }

        var acknowledged: UInt32 = 0
        guard ok, ffReadAll(fd, &acknowledged, 4) else {
            throw ShareBridgeError.notAcknowledged(imported: 0, expected: items.count)
        }
        let ack = UInt32(bigEndian: acknowledged)
        guard Int(ack) == items.count else {
            throw ShareBridgeError.notAcknowledged(imported: ack, expected: items.count)
        }

        for item in items {
            try? FileManager.default.removeItem(atPath: item.directory)
        }
        AppLog.tag("ShareBridge", "loopback send session=\(sessionID) sent=\(items.count)")
        return items.count
    }

    /// 对齐老版 FFConnectLoopback：50ms 一次、最多 120 次（6s）。
    private static func connectLoopback() -> Int32 {
        for _ in 0..<bridgeConnectAttempts {
            let fd = socket(AF_INET, ffSockStream, 0)
            if fd < 0 { return -1 }
            var address = ffLoopbackAddress()
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if result == 0 { return fd }
            close(fd)
            usleep(bridgeConnectIntervalMicros)
        }
        return -1
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

            // in-place 共享：元数据里的 sourcePath 指向原文件（未复制到收件箱）。
            let sourcePath = (metadata["sourcePath"] as? String) ?? ""
            var effectivePath = payloadPath
            var needsScope = false
            if !sourcePath.isEmpty, manager.fileExists(atPath: sourcePath) {
                effectivePath = sourcePath
                needsScope = true
            }

            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: effectivePath, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  let attributes = try? manager.attributesOfItem(atPath: effectivePath),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value else { continue }

            let rawName = metadata["name"] as? String ?? ""
            let lastComponent = (rawName as NSString).lastPathComponent
            let displayName = lastComponent.isEmpty ? "imported" : lastComponent
            let rawType = metadata["type"] as? String ?? ""
            let type = rawType.isEmpty ? "public.data" : rawType
            items.append(Item(directory: directory,
                              payloadPath: effectivePath,
                              name: displayName,
                              type: type,
                              size: size,
                              needsSecurityScope: needsScope))
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
