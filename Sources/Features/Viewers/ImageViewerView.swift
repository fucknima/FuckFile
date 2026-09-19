import SwiftUI
import UIKit

struct ImageViewerView: View {
    @StateObject private var model: ImageViewerModel

    init(entry: FileEntry, siblings: [FileEntry]) {
        _model = StateObject(wrappedValue: ImageViewerModel(entry: entry, siblings: siblings))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ZoomableImageView(image: model.image,
                              resetKey: model.currentEntry.path,
                              slideDirection: model.slideDirection,
                              onSwipeLeft: { model.showNext(animated: true) },
                              onSwipeRight: { model.showPrevious(animated: true) })
                .ignoresSafeArea()

            if model.image == nil && model.errorText == nil {
                ProgressView()
                    .tint(.white)
            }

            if let errorText = model.errorText {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                    Text(errorText)
                        .font(.headline)
                }
                .foregroundColor(.white)
                .padding(32)
                .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                topOverlay
                Spacer(minLength: 0)
                pageDots
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { model.start() }
    }

    // MARK: - Overlays

    private var topOverlay: some View {
        // 文件名放导航栏标题（ViewerHostView 统一设置），这里只留页码。
        Text("第 \(model.index + 1) / 共 \(model.count) 张")
            .font(.caption)
            .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.35))
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var pageDots: some View {
        if model.count > 1 && model.count <= 12 {
            HStack(spacing: 7) {
                ForEach(0..<model.count, id: \.self) { index in
                    Circle()
                        .fill(index == model.index ? Color.white : Color.white.opacity(0.35))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.black.opacity(0.35)))
            .padding(.bottom, 10)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Model

@MainActor
private final class ImageViewerModel: ObservableObject {
    let entries: [FileEntry]

    @Published private(set) var index: Int
    @Published private(set) var image: UIImage?
    @Published private(set) var errorText: String?
    /// 最近一次切图方向：1 = 新图从右侧滑入，-1 = 从左侧滑入。
    @Published private(set) var slideDirection = 0

    private var generation = 0
    private var hasStarted = false

    init(entry: FileEntry, siblings: [FileEntry]) {
        var list = siblings
        if !list.contains(where: { $0.path == entry.path }) {
            list.insert(entry, at: 0)
        }
        entries = list
        index = list.firstIndex(where: { $0.path == entry.path }) ?? 0
    }

    var currentEntry: FileEntry { entries[index] }
    var count: Int { entries.count }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        load(at: index)
    }

    func showNext(animated: Bool = false) {
        guard index + 1 < entries.count else { return }
        load(at: index + 1, direction: animated ? 1 : 0)
    }

    func showPrevious(animated: Bool = false) {
        guard index > 0 else { return }
        load(at: index - 1, direction: animated ? -1 : 0)
    }

    /// direction: 1 = 新图从右侧滑入（左划），-1 = 从左侧滑入（右划），0 = 直接切换。
    private func load(at newIndex: Int, direction: Int = 0) {
        index = newIndex
        generation += 1
        let generation = self.generation
        let path = entries[newIndex].path
        errorText = nil

        if let cached = ImageViewerCache.images.object(forKey: path as NSString) {
            image = cached
            slideDirection = direction
            prefetchNeighbours()
            return
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            let decoded = UIImage(contentsOfFile: path)
            let message: String?
            if decoded == nil {
                message = FileManager.default.fileExists(atPath: path) ? "无法加载图片" : "文件不存在"
            } else {
                message = nil
            }
            await self?.apply(decoded: decoded, errorText: message, path: path,
                              generation: generation, direction: direction)
        }
    }

    private func apply(decoded: UIImage?, errorText message: String?, path: String,
                       generation: Int, direction: Int) {
        guard generation == self.generation else { return }
        if let decoded = decoded {
            ImageViewerCache.images.setObject(decoded, forKey: path as NSString)
            image = decoded
            errorText = nil
            slideDirection = direction
        } else {
            image = nil
            errorText = message
            AppLog.tag("ImageViewer", "load FAIL path=\(path) error=\(message ?? "")")
        }
        prefetchNeighbours()
    }

    private func prefetchNeighbours() {
        var paths: [String] = []
        if index > 0 { paths.append(entries[index - 1].path) }
        if index + 1 < entries.count { paths.append(entries[index + 1].path) }
        guard !paths.isEmpty else { return }

        Task.detached(priority: .utility) {
            for path in paths where ImageViewerCache.images.object(forKey: path as NSString) == nil {
                if let decoded = UIImage(contentsOfFile: path) {
                    ImageViewerCache.images.setObject(decoded, forKey: path as NSString)
                }
            }
        }
    }
}

private enum ImageViewerCache {
    static let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 12
        return cache
    }()
}

// MARK: - Zoomable image (UIScrollView + UIImageView)

private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage?
    let resetKey: String
    let slideDirection: Int
    let onSwipeLeft: () -> Void
    let onSwipeRight: () -> Void

    func makeUIView(context: Context) -> ZoomView {
        ZoomView()
    }

    func updateUIView(_ view: ZoomView, context: Context) {
        view.onSwipeLeft = onSwipeLeft
        view.onSwipeRight = onSwipeRight
        view.setImage(image, resetKey: resetKey, slideDirection: slideDirection)
    }
}

private final class ZoomView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var onSwipeLeft: (() -> Void)?
    var onSwipeRight: (() -> Void)?

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private var lastResetKey: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black

        scrollView.backgroundColor = .black
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 8
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        addSubview(scrollView)

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        imageView.addGestureRecognizer(doubleTap)

        let swipeLeft = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
        swipeLeft.direction = .left
        swipeLeft.delegate = self
        addGestureRecognizer(swipeLeft)

        let swipeRight = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
        swipeRight.direction = .right
        swipeRight.delegate = self
        addGestureRecognizer(swipeRight)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setImage(_ image: UIImage?, resetKey: String, slideDirection: Int) {
        let isNewKey = resetKey != lastResetKey
        let isFirstImage = imageView.image == nil && image != nil
        lastResetKey = resetKey
        guard isNewKey || isFirstImage || image !== imageView.image else { return }

        // 与旧版 FFImageViewerViewController 一致：方向非 0 时用快照做滑入/滑出，
        // 方向 0（首次进入/删除后落到相邻图）用交叉淡入。
        let animated = !isFirstImage && window != nil && !bounds.isEmpty
        if animated && slideDirection != 0 {
            slide(to: image, direction: slideDirection)
            return
        }
        if animated {
            UIView.transition(with: self, duration: 0.2,
                              options: .transitionCrossDissolve) {
                self.apply(image, resetZoom: isNewKey || isFirstImage)
            }
            return
        }
        apply(image, resetZoom: isNewKey || isFirstImage)
    }

    private func apply(_ image: UIImage?, resetZoom: Bool) {
        if resetZoom {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
        }
        imageView.image = image
        if let image = image {
            imageView.frame = CGRect(origin: .zero, size: image.size)
        } else {
            imageView.frame = .zero
            scrollView.contentSize = .zero
        }
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// direction: 1 = 新图从右侧进入，-1 = 从左侧进入。
    private func slide(to image: UIImage?, direction: Int) {
        let width = bounds.width
        guard width > 0 else {
            apply(image, resetZoom: true)
            return
        }

        let outgoing = snapshotView(afterScreenUpdates: false)
        outgoing?.frame = frame
        outgoing?.isUserInteractionEnabled = false
        if let outgoing { superview?.addSubview(outgoing) }

        let incomingView = ZoomView(frame: frame.offsetBy(dx: CGFloat(direction) * width, dy: 0))
        incomingView.apply(image, resetZoom: true)
        incomingView.isUserInteractionEnabled = false
        superview?.addSubview(incomingView)

        apply(image, resetZoom: true)
        isHidden = true

        UIView.animate(withDuration: 0.26, delay: 0,
                       options: [.curveEaseInOut]) {
            outgoing?.frame = outgoing?.frame.offsetBy(dx: -CGFloat(direction) * width, dy: 0)
                ?? .zero
            incomingView.frame = incomingView.frame.offsetBy(dx: -CGFloat(direction) * width,
                                                             dy: 0)
        } completion: { _ in
            outgoing?.removeFromSuperview()
            incomingView.removeFromSuperview()
            self.isHidden = false
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        guard scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01,
              let image = imageView.image else { return }

        let viewSize = scrollView.bounds.size
        let imageSize = image.size
        guard viewSize.width > 0, viewSize.height > 0,
              imageSize.width > 0, imageSize.height > 0 else { return }

        let scale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let fitted = CGSize(width: floor(imageSize.width * scale),
                            height: floor(imageSize.height * scale))
        imageView.frame = CGRect(x: (viewSize.width - fitted.width) / 2,
                                 y: (viewSize.height - fitted.height) / 2,
                                 width: fitted.width,
                                 height: fitted.height)
        scrollView.contentSize = fitted
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // 与旧版一致：滑动与滚动并行识别（未放大时滚动没有内容，不产生视觉冲突）。
        true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        // 屏幕左缘留给系统「返回」手势：从中间右划才是上一张。
        guard let swipe = gestureRecognizer as? UISwipeGestureRecognizer,
              swipe.direction == .right else { return true }
        return touch.location(in: self).x > Self.systemEdgeWidth
    }

    private static let systemEdgeWidth: CGFloat = 24

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard isZoomedOut else {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            return
        }
        let targetScale = min(scrollView.maximumZoomScale, 3)
        let center = gesture.location(in: imageView)
        let rect = CGRect(x: center.x - scrollView.bounds.width / targetScale / 2,
                          y: center.y - scrollView.bounds.height / targetScale / 2,
                          width: scrollView.bounds.width / targetScale,
                          height: scrollView.bounds.height / targetScale)
        scrollView.zoom(to: rect, animated: true)
    }

    @objc private func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
        guard isZoomedOut else { return }
        switch gesture.direction {
        case .left:
            onSwipeLeft?()
        case .right:
            onSwipeRight?()
        default:
            break
        }
    }

    private var isZoomedOut: Bool {
        scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01
    }
}
