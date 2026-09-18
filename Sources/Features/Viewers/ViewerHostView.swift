import SwiftUI

/// 查看器路由：按文件关联选查看器；未实现或未知类型回退 QuickLook。
struct ViewerHostView: View {
    let entry: FileEntry
    let siblings: [FileEntry]
    var forcedViewer: ViewerID? = nil

    var body: some View {
        Group {
            viewerContent
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .viewerActions(for: entry)
    }

    @ViewBuilder
    private var viewerContent: some View {
        switch resolvedViewerID {
        case .image:
            ImageViewerView(entry: entry, siblings: filteredSiblings(for: .image))
        case .media:
            MediaPlayerView(entry: entry, siblings: filteredSiblings(for: .media))
        case .pdf:
            PdfViewerView(entry: entry)
        case .text:
            TextEditorView(entry: entry)
        case .web:
            WebViewerView(entry: entry)
        case .plist:
            PlistEditorView(entry: entry)
        case .sqlite:
            SQLiteBrowserView(entry: entry)
        case .hex:
            HexEditorView(entry: entry)
        case .archive:
            ArchiveBrowserView(entry: entry)
        default:
            QuickLookView(entry: entry)
        }
    }

    private var resolvedViewerID: ViewerID {
        let viewer = forcedViewer ?? FileAssociationService.viewerID(forPath: entry.path)
        return viewer.isImplemented ? viewer : .quickLook
    }

    /// 同目录、同一默认查看器的兄弟条目（图片/媒体翻页用）。
    private func filteredSiblings(for viewer: ViewerID) -> [FileEntry] {
        siblings.filter { candidate in
            let ext = (candidate.name as NSString).pathExtension.lowercased()
            return FileAssociationService.defaultViewerID(forExtension: ext) == viewer
        }
    }
}
