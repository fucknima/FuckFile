import AVFoundation
import CommonCrypto
import ImageIO
import UIKit

/// 缩略图生成与缓存（阶段 3c 冻结接口）。
/// 内存 NSCache（200 项）+ 磁盘缓存（Caches/Thumbnails，SHA1(key).jpg，上限 200MB，超限删最旧）。
/// 同一 key 的并发请求合并为一次生成；completion 统一主线程回调。
enum ThumbnailService {
    static func thumbnail(forPath path: String, size: CGSize,
                          completion: @escaping (UIImage?) -> Void) {
        ThumbnailEngine.shared.thumbnail(forPath: path, size: size, completion: completion)
    }

    static func cachedThumbnail(forPath path: String, size: CGSize) -> UIImage? {
        ThumbnailEngine.shared.cachedThumbnail(forPath: path, size: size)
    }
}

private final class ThumbnailEngine {
    static let shared = ThumbnailEngine()

    private static let diskLimit: UInt64 = 200 * 1024 * 1024
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp",
    ]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    private let memoryCache = NSCache<NSString, UIImage>()
    private let workQueue = DispatchQueue(label: "ff.thumbnails", qos: .utility)
    private let lock = NSLock()
    private var inFlight: [String: [(UIImage?) -> Void]] = [:]

    private init() {
        memoryCache.countLimit = 200
        workQueue.async { [weak self] in self?.trimDiskCacheIfNeeded() }
    }

    /// 同步读内存缓存（磁盘不回读，避免列表滚动时在主线程解文件）。
    func cachedThumbnail(forPath path: String, size: CGSize) -> UIImage? {
        guard !path.isEmpty else { return nil }
        return memoryCache.object(forKey: Self.cacheKey(path: path, size: size) as NSString)
    }

    func thumbnail(forPath path: String, size: CGSize,
                   completion: @escaping (UIImage?) -> Void) {
        guard !path.isEmpty else {
            Self.callOnMain(completion, nil)
            return
        }
        let key = Self.cacheKey(path: path, size: size)
        if let cached = memoryCache.object(forKey: key as NSString) {
            Self.callOnMain(completion, cached)
            return
        }
        guard let kind = Self.kind(forPath: path) else {
            Self.callOnMain(completion, nil)
            return
        }

        lock.lock()
        if var waiters = inFlight[key] {
            waiters.append(completion)
            inFlight[key] = waiters
            lock.unlock()
            return
        }
        inFlight[key] = [completion]
        lock.unlock()

        workQueue.async { [weak self] in
            guard let self else { return }
            let image = self.loadOrGenerate(path: path, key: key, kind: kind, size: size)
            if let image {
                self.memoryCache.setObject(image, forKey: key as NSString)
            }
            self.lock.lock()
            let waiters = self.inFlight.removeValue(forKey: key) ?? []
            self.lock.unlock()
            DispatchQueue.main.async {
                for waiter in waiters { waiter(image) }
            }
        }
    }

    // MARK: - 生成

    private enum Kind { case image, video }

    private static func kind(forPath path: String) -> Kind? {
        let ext = (path as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        return nil
    }

    private func loadOrGenerate(path: String, key: String, kind: Kind, size: CGSize) -> UIImage? {
        let diskURL = Self.diskURL(for: key)
        if let data = try? Data(contentsOf: diskURL), let image = UIImage(data: data) {
            try? FileManager.default.setAttributes([.modificationDate: Date()],
                                                   ofItemAtPath: diskURL.path)
            return image
        }

        let pixels = max(1, Int(max(size.width, size.height) * max(UIScreen.main.scale, 2)))
        guard let image = generate(path: path, kind: kind, pixels: pixels) else {
            AppLog.tag("Thumbnail", "generate FAIL path=\(path)")
            return nil
        }

        if let data = image.jpegData(compressionQuality: 0.8) {
            try? FileManager.default.createDirectory(at: diskURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: diskURL, options: .atomic)
            trimDiskCacheIfNeeded()
        }
        return image
    }

    private func generate(path: String, kind: Kind, pixels: Int) -> UIImage? {
        switch kind {
        case .image: return imageThumbnail(path: path, pixels: pixels)
        case .video: return videoThumbnail(path: path, pixels: pixels)
        }
    }

    /// 只解码缩略图，不整图解码（kCGImageSourceCreateThumbnailFromImageAlways）。
    private func imageThumbnail(path: String, pixels: Int) -> UIImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0,
                                                                  options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: thumbnail)
    }

    private func videoThumbnail(path: String, pixels: Int) -> UIImage? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: pixels, height: pixels)
        // 短于 0.5s 的视频回退首帧。
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        if let frame = try? generator.copyCGImage(at: time, actualTime: nil) {
            return UIImage(cgImage: frame)
        }
        guard let frame = try? generator.copyCGImage(at: .zero, actualTime: nil) else {
            AppLog.tag("Thumbnail", "video frame FAIL path=\(path)")
            return nil
        }
        return UIImage(cgImage: frame)
    }

    // MARK: - 缓存键与磁盘

    /// path + 点尺寸 + 文件 mtime/size 指纹：文件被替换后自动失效。
    private static func cacheKey(path: String, size: CGSize) -> String {
        var fingerprint = "?"
        if let attributes = try? FileManager.default.attributesOfItem(atPath: path) {
            let mtime = (attributes[.modificationDate] as? Date)
                .map { String(Int64($0.timeIntervalSince1970)) } ?? "-"
            let fileSize = (attributes[.size] as? NSNumber)?.stringValue ?? "-"
            fingerprint = "\(mtime)-\(fileSize)"
        }
        return "\(path)#\(Int(size.width.rounded()))x\(Int(size.height.rounded()))#\(fingerprint)"
    }

    private static var diskRoot: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("Thumbnails", isDirectory: true)
    }

    private static func diskURL(for key: String) -> URL {
        diskRoot.appendingPathComponent(sha1(key)).appendingPathExtension("jpg")
    }

    private static func sha1(_ value: String) -> String {
        let data = Data(value.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { bytes in
            _ = CC_SHA1(bytes.baseAddress, CC_LONG(bytes.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 超过 200MB 时按修改时间从旧到新删到上限以内。
    private func trimDiskCacheIfNeeded() {
        let manager = FileManager.default
        let root = Self.diskRoot
        guard let names = try? manager.contentsOfDirectory(atPath: root.path) else { return }

        var entries: [(url: URL, size: UInt64, date: Date)] = []
        var total: UInt64 = 0
        for name in names {
            let url = root.appendingPathComponent(name)
            guard let attributes = try? manager.attributesOfItem(atPath: url.path) else { continue }
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let date = (attributes[.modificationDate] as? Date)
                ?? (attributes[.creationDate] as? Date) ?? .distantPast
            total += size
            entries.append((url, size, date))
        }
        guard total > Self.diskLimit else { return }

        entries.sort { $0.date < $1.date }
        var removed = 0
        for entry in entries {
            if total <= Self.diskLimit { break }
            do {
                try manager.removeItem(at: entry.url)
                total -= min(total, entry.size)
                removed += 1
            } catch {
                AppLog.tag("Thumbnail", "disk trim FAIL path=\(entry.url.path) error=\(error.localizedDescription)")
            }
        }
        AppLog.tag("Thumbnail", "disk trim removed=\(removed) remaining=\(total)")
    }

    private static func callOnMain(_ completion: @escaping (UIImage?) -> Void, _ image: UIImage?) {
        DispatchQueue.main.async { completion(image) }
    }
}
