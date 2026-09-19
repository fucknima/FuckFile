import SwiftUI
import UIKit

/// 行锚点登记：把 SwiftUI 行映射到真实 UIView，供 UIKit 弹窗定位。
/// 行重建时由 RowAnchorReader 刷新；取用前校验仍在窗口上，失效的自动忽略。
enum RowAnchors {
    private final class WeakView {
        weak var view: UIView?
        init(_ view: UIView) { self.view = view }
    }

    private static let lock = NSLock()
    private static var views: [String: WeakView] = [:]

    static func register(_ view: UIView?, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let view else {
            views[key] = nil
            return
        }
        if views.count > 512 { views = views.filter { $0.value.view != nil } }
        views[key] = WeakView(view)
    }

    static func view(for key: String?) -> UIView? {
        guard let key else { return nil }
        lock.lock()
        let candidate = views[key]?.view
        lock.unlock()
        guard let candidate, candidate.window != nil else { return nil }
        return candidate
    }
}

/// 贴在行内容背后的小视图，把所在行的 UIView 登记到 RowAnchors。
struct RowAnchorReader: UIViewRepresentable {
    let key: String

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        RowAnchors.register(uiView, for: key)
    }
}

/// 锚定到某个 UIView 的操作表：有锚点时以 popover 出现（iPhone 同样是
/// 条目旁的小弹窗），没有锚点时退回系统默认位置。
enum ActionSheetPresenter {
    @MainActor
    static func present(title: String,
                        message: String?,
                        actions: [(title: String, destructive: Bool, handler: () -> Void)],
                        cancelTitle: String = "取消",
                        onCancel: (() -> Void)? = nil,
                        anchor: UIView?,
                        delay: TimeInterval = 0) {
        let alert = UIAlertController(title: title, message: message,
                                      preferredStyle: .actionSheet)
        for action in actions {
            alert.addAction(UIAlertAction(title: action.title,
                                          style: action.destructive ? .destructive : .default) { _ in
                action.handler()
            })
        }
        alert.addAction(UIAlertAction(title: cancelTitle, style: .cancel) { _ in
            onCancel?()
        })
        alert.modalPresentationStyle = .popover
        if let popover = alert.popoverPresentationController {
            if let anchor {
                popover.sourceView = anchor
                popover.sourceRect = CGRect(x: anchor.bounds.midX, y: anchor.bounds.midY,
                                            width: 1, height: 1)
                popover.permittedArrowDirections = [.up, .down]
            } else if let host = topViewController()?.view {
                popover.sourceView = host
                popover.sourceRect = CGRect(x: host.bounds.midX, y: host.bounds.midY,
                                            width: 1, height: 1)
            }
        }
        let show = { topViewController()?.present(alert, animated: true) }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: show)
        } else {
            DispatchQueue.main.async(execute: show)
        }
    }

    @MainActor
    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var controller = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        if let navigation = controller as? UINavigationController {
            controller = navigation.visibleViewController
        }
        return controller
    }
}
