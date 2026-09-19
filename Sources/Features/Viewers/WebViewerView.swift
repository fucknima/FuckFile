import Combine
import SwiftUI
import UIKit
import WebKit

/// 网页查看器：本地 html/htm 用 WKWebView 加载（读权限限定文件所在目录），
/// .url/.webloc 解析出远端地址后加载。行为对齐 FFWebViewerViewController
/// （ADR-035：viewport 缩放修正 + 无配色页面深色适配）。
struct WebViewerView: View {
    let entry: FileEntry

    @StateObject private var store = WebViewStore()

    init(entry: FileEntry) {
        self.entry = entry
    }

    var body: some View {
        ZStack {
            // 与旧版一致：web view 铺满，自己按安全区加内容 inset；
            // 交给 SwiftUI 再缩一次会在顶栏下多出空白。
            WebViewRepresentable(entry: entry, store: store)
                .ignoresSafeArea()
            if store.isLoading {
                ProgressView("正在载入…")
            }
            if let message = store.errorMessage {
                errorState(message)
            }
        }
        .navigationTitle(store.pageTitle.isEmpty ? entry.name : store.pageTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("加载失败")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("重试") { store.reload() }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}

private final class WebViewStore: ObservableObject {
    @Published var isLoading = true
    @Published var errorMessage: String?
    @Published var pageTitle = ""

    weak var coordinator: WebViewCoordinator?

    func reload() {
        coordinator?.reload()
    }
}

private struct WebViewRepresentable: UIViewRepresentable {
    let entry: FileEntry
    @ObservedObject var store: WebViewStore

    func makeCoordinator() -> WebViewCoordinator {
        WebViewCoordinator(entry: entry, store: store)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WebScripts.zoom)
        configuration.userContentController.addUserScript(WebScripts.darkMode)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.scrollView.minimumZoomScale = 1.0
        webView.scrollView.maximumZoomScale = 5.0
        webView.scrollView.backgroundColor = .systemBackground
        webView.underPageBackgroundColor = .systemBackground
        webView.backgroundColor = .systemBackground
        context.coordinator.attach(webView)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// 本地 HTML 常带 user-scalable=no / maximum-scale=1，WebKit 会因此禁用双指
/// 缩放；文档开始与解析完成时改写已有 viewport meta，把缩放权限改回来。
/// 深色适配只对「没有自带配色」的页面生效（html/body 背景透明且 body 文字
/// 是默认黑），自带配色的页面完全不碰（ADR-035）。
private enum WebScripts {
    static let zoom = WKUserScript(source: zoomSource,
                                   injectionTime: .atDocumentStart,
                                   forMainFrameOnly: true)

    static let darkMode = WKUserScript(source: darkModeSource,
                                       injectionTime: .atDocumentEnd,
                                       forMainFrameOnly: true)

    private static let zoomSource = #"""
    (function () {
      function fix() {
        var metas = document.querySelectorAll('meta[name="viewport"]');
        for (var i = 0; i < metas.length; i++) {
          var content = metas[i].getAttribute('content') || '';
          content = content.replace(/user-scalable\s*=\s*no/ig, 'user-scalable=yes')
                           .replace(/maximum-scale\s*=\s*[^,\s]+/ig, 'maximum-scale=5');
          if (!/user-scalable/i.test(content)) content += ', user-scalable=yes';
          if (!/maximum-scale/i.test(content)) content += ', maximum-scale=5';
          metas[i].setAttribute('content', content);
        }
      }
      fix();
      document.addEventListener('DOMContentLoaded', fix);
      window.addEventListener('load', fix);
    })();
    """#

    private static let darkModeSource = #"""
    (function () {
      var body = document.body;
      if (!body) return;
      function isTransparent(value) {
        return !value || value === 'transparent' ||
            /rgba\(\s*0\s*,\s*0\s*,\s*0\s*,\s*0\s*\)/.test(value);
      }
      var bodyStyle = window.getComputedStyle(body);
      var rootStyle = window.getComputedStyle(document.documentElement);
      if (!isTransparent(bodyStyle.backgroundColor)) return;
      if (!isTransparent(rootStyle.backgroundColor)) return;
      if (!/^rgb\(\s*0\s*,\s*0\s*,\s*0\s*\)$/.test(bodyStyle.color || '')) return;
      var style = document.createElement('style');
      style.textContent = '@media (prefers-color-scheme: dark) {'
          + ':root { color-scheme: dark; }'
          + 'html, body { background-color: transparent !important; }'
          + '}';
      (document.head || document.documentElement).appendChild(style);
    })();
    """#
}

private final class WebViewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let entry: FileEntry
    private let store: WebViewStore
    private weak var webView: WKWebView?

    init(entry: FileEntry, store: WebViewStore) {
        self.entry = entry
        self.store = store
        super.init()
        store.coordinator = self
    }

    func attach(_ webView: WKWebView) {
        self.webView = webView
        loadPage()
    }

    func reload() {
        loadPage()
    }

    private func loadPage() {
        guard let webView = webView else { return }
        store.errorMessage = nil

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            store.isLoading = false
            store.errorMessage = "文件不存在或已被移动。"
            return
        }

        let fileExtension = (entry.name as NSString).pathExtension.lowercased()
        if fileExtension == "url" || fileExtension == "webloc" {
            guard let url = Self.remoteURL(path: entry.path, fileExtension: fileExtension) else {
                store.isLoading = false
                store.errorMessage = "无法解析该网页文件中的网址。"
                AppLog.tag("Web", "shortcut has no URL path=\(entry.path)")
                return
            }
            store.isLoading = true
            AppLog.tag("Web", "load remote path=\(entry.path) url=\(url.absoluteString)")
            webView.load(URLRequest(url: url))
        } else {
            let fileURL = URL(fileURLWithPath: entry.path)
            store.isLoading = true
            AppLog.tag("Web", "load file path=\(entry.path)")
            webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
        }
    }

    private func handleFailure(_ error: Error) {
        store.isLoading = false
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        store.errorMessage = "无法加载页面：\(error.localizedDescription)"
        AppLog.tag("Web", "navigation FAIL path=\(entry.path) error=\(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        store.isLoading = true
        store.errorMessage = nil
        AppLog.tag("Web", "navigation start path=\(entry.path) url=\(webView.url?.absoluteString ?? "-")")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        store.isLoading = false
        store.errorMessage = nil
        store.pageTitle = webView.title ?? ""
        AppLog.tag("Web", "navigation finish path=\(entry.path) url=\(webView.url?.absoluteString ?? "-")")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        store.isLoading = false
        store.errorMessage = "网页渲染进程已终止，请重试。"
        AppLog.tag("Web", "WebContent terminated path=\(entry.path)")
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, navigationAction.request.url != nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        if !present(alert, from: webView) { completionHandler() }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        if !present(alert, from: webView) { completionHandler(false) }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { field in field.text = defaultText }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in
            completionHandler(alert.textFields?.first?.text)
        })
        if !present(alert, from: webView) { completionHandler(nil) }
    }

    private func present(_ alert: UIAlertController, from webView: WKWebView) -> Bool {
        guard let host = topViewController(from: webView) else { return false }
        host.present(alert, animated: true)
        return true
    }

    private func topViewController(from webView: WKWebView) -> UIViewController? {
        guard var controller = webView.window?.rootViewController else { return nil }
        while let presented = controller.presentedViewController {
            controller = presented
        }
        return controller
    }
}

private extension WebViewCoordinator {
    static func remoteURL(path: String, fileExtension: String) -> URL? {
        switch fileExtension {
        case "webloc":
            let plist = NSDictionary(contentsOfFile: path)
            return normalizedRemoteURL(plist?["URL"] as? String)
        case "url":
            return normalizedRemoteURL(urlString(fromInternetLocationFile: path))
        default:
            return nil
        }
    }

    static func urlString(fromInternetLocationFile path: String) -> String? {
        let content = (try? String(contentsOfFile: path, encoding: .utf8))
            ?? (try? String(contentsOfFile: path, encoding: .isoLatin1))
        guard let content = content else { return nil }
        let pattern = "(?i)^\\s*URL\\s*=\\s*(\\S+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return nil
        }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        guard let match = regex.firstMatch(in: content, options: [], range: range),
              match.numberOfRanges > 1,
              let urlRange = Range(match.range(at: 1), in: content) else {
            return nil
        }
        return String(content[urlRange])
    }

    /// 快捷方式常省略 scheme，此时按 https 处理；about: 等带 scheme 的原样使用。
    static func normalizedRemoteURL(_ string: String?) -> URL? {
        guard let string = string else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty {
            return url
        }
        return URL(string: "https://\(trimmed)")
    }
}
