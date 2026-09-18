import SwiftUI
import UIKit

/// UIActivityViewController 包装（阶段 3c 冻结接口）。
/// 由调用方用 `.sheet` 呈现；iPad 通过 popover 适配避免全屏。
struct ShareSheet: View {
    let items: [Any]

    init(items: [Any]) {
        self.items = items
    }

    var body: some View {
        if #available(iOS 16.4, *) {
            ActivityViewController(items: items)
                .presentationCompactAdaptation(.popover)
        } else {
            ActivityViewController(items: items)
        }
    }
}

private struct ActivityViewController: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
