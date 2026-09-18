import Foundation
#if canImport(Combine)
import Combine
#endif
import SwiftUI
import PDFKit

/// PDF 查看器：PDFKit 渲染，页码/总页数、上一页/下一页、单页/连续切换；捏合缩放由 PDFView 自带。
struct PdfViewerView: View {
    let entry: FileEntry
    @StateObject private var store = PDFViewStore()

    init(entry: FileEntry) {
        self.entry = entry
    }

    var body: some View {
        if let message = fileError {
            PdfErrorState(message: message)
        } else {
            VStack(spacing: 0) {
                toolbar
                ZStack {
                    PDFViewRepresentable(store: store)
                    if store.state == .loading {
                        ProgressView()
                    } else if store.state == .failed {
                        Text(store.failureMessage ?? "无法打开 PDF。")
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                }
            }
            .task(id: entry.path) {
                await loadDocument()
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                store.goToPrevious()
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(!store.canGoPrevious)
            .accessibilityLabel("上一页")

            Text(store.pageText)
                .font(.footnote.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(minWidth: 56)

            Button {
                store.goToNext()
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(!store.canGoNext)
            .accessibilityLabel("下一页")

            Spacer()

            Picker("阅读模式", selection: continuousBinding) {
                Text("单页").tag(false)
                Text("连续").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 160)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var continuousBinding: Binding<Bool> {
        Binding(
            get: { store.isContinuous },
            set: { store.setContinuous($0) }
        )
    }

    private var fileError: String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory) else {
            return "文件不存在或已被移动。"
        }
        return isDirectory.boolValue ? "无法预览文件夹。" : nil
    }

    @MainActor
    private func loadDocument() async {
        let path = entry.path
        store.beginLoading()
        let document = await Task.detached(priority: .userInitiated) {
            PDFDocument(url: URL(fileURLWithPath: path))
        }.value
        store.apply(document, path: path)
    }
}

private struct PdfErrorState: View {
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

private final class PDFViewStore: ObservableObject {
    enum LoadState: Equatable {
        case loading
        case loaded
        case failed
    }

    @Published private(set) var state: LoadState = .loading
    @Published private(set) var failureMessage: String?
    @Published private(set) var document: PDFDocument?
    @Published private(set) var pageIndex = 0
    @Published private(set) var pageCount = 0
    @Published private(set) var canGoPrevious = false
    @Published private(set) var canGoNext = false
    @Published private(set) var isContinuous = true

    weak var pdfView: PDFView?

    var pageText: String {
        pageCount > 0 ? "\(pageIndex + 1) / \(pageCount)" : "– / –"
    }

    func beginLoading() {
        state = .loading
        failureMessage = nil
        document = nil
        pageIndex = 0
        pageCount = 0
        canGoPrevious = false
        canGoNext = false
    }

    func apply(_ document: PDFDocument?, path: String) {
        if let document = document, !document.isLocked {
            self.document = document
            failureMessage = nil
            state = .loaded
            AppLog.tag("Preview", "pdf opened path=\(path) pages=\(document.pageCount)")
        } else {
            self.document = nil
            failureMessage = document == nil
                ? "无法打开 PDF：文件已损坏或不可读。"
                : "PDF 已加密，暂不支持解锁。"
            state = .failed
            AppLog.tag("Preview", "pdf load FAIL path=\(path) locked=\(document?.isLocked ?? false)")
        }
    }

    func refresh(from view: PDFView) {
        let document = view.document
        pageCount = document?.pageCount ?? 0
        if let page = view.currentPage, let document = document {
            let index = document.index(for: page)
            pageIndex = (index >= 0 && index < document.pageCount) ? index : 0
        } else {
            pageIndex = 0
        }
        canGoPrevious = view.canGoToPreviousPage
        canGoNext = view.canGoToNextPage
    }

    func goToPrevious() {
        guard let view = pdfView, view.canGoToPreviousPage else { return }
        view.goToPreviousPage(nil)
        refresh(from: view)
    }

    func goToNext() {
        guard let view = pdfView, view.canGoToNextPage else { return }
        view.goToNextPage(nil)
        refresh(from: view)
    }

    func setContinuous(_ continuous: Bool) {
        isContinuous = continuous
        guard let view = pdfView else { return }
        view.displayMode = continuous ? .singlePageContinuous : .singlePage
        refresh(from: view)
    }
}

private struct PDFViewRepresentable: UIViewRepresentable {
    @ObservedObject var store: PDFViewStore

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        store.pdfView = view
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: view
        )
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        guard view.document !== store.document else { return }
        view.document = store.document
        if store.document != nil {
            view.autoScales = true
            Task { @MainActor in
                store.refresh(from: view)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store)
    }

    final class Coordinator: NSObject {
        private let store: PDFViewStore

        init(store: PDFViewStore) {
            self.store = store
        }

        @objc func pageChanged(_ notification: Notification) {
            guard let view = notification.object as? PDFView else { return }
            Task { @MainActor in
                store.refresh(from: view)
            }
        }
    }
}
