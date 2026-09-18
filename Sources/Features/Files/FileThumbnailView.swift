import SwiftUI
import UIKit

/// 列表/网格通用缩略图：有缩略图显示缩略图（圆角、aspectFill），否则回退 SF Symbol 图标。
/// entry 变化（path 或 mtime/size）时 `.task(id:)` 取消旧任务，回调落地前再校验路径，
/// 避免 cell 复用显示到上一个条目的缩略图。
struct FileThumbnailView: View {
    let entry: FileEntry
    let size: CGSize
    let fallbackIcon: String
    let fallbackTint: Color

    @State private var image: UIImage?
    @State private var requestedPath: String?

    init(entry: FileEntry, size: CGSize, fallbackIcon: String, fallbackTint: Color) {
        self.entry = entry
        self.size = size
        self.fallbackIcon = fallbackIcon
        self.fallbackTint = fallbackTint
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: fallbackIcon)
                    .font(.system(size: max(10, min(size.width, size.height) * 0.5)))
                    .foregroundColor(fallbackTint)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: entry) { await load() }
    }

    @MainActor
    private func load() async {
        let path = entry.path
        requestedPath = path
        if let cached = ThumbnailService.cachedThumbnail(forPath: path, size: size) {
            image = cached
            return
        }
        image = nil
        let thumbnail = await withCheckedContinuation { continuation in
            ThumbnailService.thumbnail(forPath: path, size: size) { thumbnail in
                continuation.resume(returning: thumbnail)
            }
        }
        guard !Task.isCancelled, requestedPath == path else { return }
        image = thumbnail
    }
}
