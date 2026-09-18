import Foundation
import SwiftUI
import QuickLook

/// QuickLook 查看器：QLPreviewController 单文件预览。
struct QuickLookView: View {
    let entry: FileEntry

    init(entry: FileEntry) {
        self.entry = entry
    }

    var body: some View {
        if let message = fileError {
            QuickLookErrorState(message: message)
        } else {
            QuickLookRepresentable(url: URL(fileURLWithPath: entry.path))
        }
    }

    private var fileError: String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory) else {
            return "文件不存在或已被移动。"
        }
        return isDirectory.boolValue ? "无法预览文件夹。" : nil
    }
}

private struct QuickLookErrorState: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text(message)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct QuickLookRepresentable: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        controller.reloadData()
        controller.refreshCurrentPreviewItem()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    @MainActor
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
