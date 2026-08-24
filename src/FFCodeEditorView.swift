// FFCodeEditorView — Objective-C / Swift 桥接层（隔离 Runestone + Tree-sitter）。
//
// 设计约束：
// - ObjC（FFTextEditorViewController）只通过本类方法操作编辑器；
//   第三方 API 不散落到项目其余部分。
// - 语言支持只在此文件注册（扩展名 → tree-sitter grammar + query）。
// - 大文件由 ObjC 侧决定是否开启高亮（setLanguageEnabled:）。
// - Bundle.module shim：theos 无 SPM 资源包，vendored Runestone 的
//   Theme.xcassets 经 actool 编译进主 bundle（见 .github/workflows）。
import UIKit
import Foundation

extension Bundle {
    static var module: Bundle { .main }
}

final class FFSimpleCharacterPair: CharacterPair {
    let leading: String
    let trailing: String
    init(_ leading: String, _ trailing: String) {
        self.leading = leading
        self.trailing = trailing
    }
}

final class FFLanguageSpec {
    let language: UnsafePointer<TSLanguage>
    let queryResource: String?
    init(_ language: UnsafePointer<TSLanguage>, queryResource: String? = nil) {
        self.language = language
        self.queryResource = queryResource
    }
}

private let ffLanguages: [String: FFLanguageSpec] = {
    var specs: [String: FFLanguageSpec] = [:]
    func add(_ extensions: [String], _ pointer: UnsafePointer<TSLanguage>, query: String? = nil) {
        for ext in extensions where specs[ext] == nil {
            specs[ext] = FFLanguageSpec(pointer, queryResource: query)
        }
    }
    add(["c", "h"], tree_sitter_c(), query: "c")
    add(["cpp", "cc", "cxx", "hpp", "inl"], tree_sitter_cpp(), query: "cpp")
    add(["m", "objc"], tree_sitter_objc(), query: "objc")
    add(["mm"], tree_sitter_cpp(), query: "cpp")
    add(["swift"], tree_sitter_swift(), query: "swift")
    add(["py", "python"], tree_sitter_python(), query: "python")
    add(["js", "mjs", "cjs"], tree_sitter_javascript(), query: "javascript")
    add(["ts", "mts"], tree_sitter_typescript(), query: "typescript")
    add(["tsx"], tree_sitter_tsx(), query: "typescript")
    add(["json"], tree_sitter_json(), query: "json")
    add(["html", "htm"], tree_sitter_html(), query: "html")
    add(["css"], tree_sitter_css(), query: "css")
    add(["sh", "bash", "zsh"], tree_sitter_bash(), query: "bash")
    add(["sql"], tree_sitter_sql(), query: "sql")
    add(["yaml", "yml"], tree_sitter_yaml(), query: "yaml")
    add(["xml"], tree_sitter_xml(), query: "xml")
    add(["md", "markdown"], tree_sitter_markdown(), query: "markdown")
    return specs
}()

@objc(FFCodeEditorView)
final class FFCodeEditorView: UIView {

    @objc public var onTextChanged: (() -> Void)?
    @objc public var onDidBeginEditing: (() -> Void)?
    @objc public var onDidEndEditing: (() -> Void)?

    private let textView = TextView()
    private var characterPairList: [CharacterPair] = []
    private var currentLanguageSpec: FFLanguageSpec?

    // 搜索定位不能使用“屏幕高度 - 键盘高度”猜 viewport，也不能把
    // firstRect(for:) 当文档绝对坐标直接写 contentOffset。保存系统给出的
    // 键盘 screen frame，定位时统一转换到 window 坐标并与编辑器/附件求交。
    private var keyboardEndFrameInScreen: CGRect = .null

    // Previous/Next 连续快速点击时，旧一次定位的 async 校正必须失效。
    // 否则旧 match 的延迟 layout 回调会在新 match 已选中后再次改 contentOffset。
    private var searchNavigationGeneration: UInt64 = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setup() {
        textView.frame = bounds
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textView.theme = DefaultTheme()
        textView.backgroundColor = UIColor.systemBackground
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.spellCheckingType = .no
        textView.keyboardDismissMode = .interactive
        textView.isLineWrappingEnabled = true
        textView.showLineNumbers = true
        textView.lineSelectionDisplayType = .line
        textView.lineEndings = .lf
        textView.indentStrategy = .space(length: 4)
        textView.characterPairTrailingComponentDeletionMode = .immediatelyFollowingLeadingComponent
        textView.inputAccessoryView = nil
        addSubview(textView)

        characterPairList = [
            FFSimpleCharacterPair("(", ")"),
            FFSimpleCharacterPair("[", "]"),
            FFSimpleCharacterPair("{", "}"),
            FFSimpleCharacterPair("\"", "\""),
            FFSimpleCharacterPair("'", "'"),
        ]
        textView.characterPairs = characterPairList
        textView.editorDelegate = self

        NotificationCenter.default.addObserver(
            self, selector: #selector(ffKeyboardFrameChanged(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(ffKeyboardFrameChanged(_:)),
            name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(ffKeyboardFrameChanged(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func ffKeyboardFrameChanged(_ notification: Notification) {
        if let endValue = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue {
            keyboardEndFrameInScreen = endValue.cgRectValue
        } else if notification.name == UIResponder.keyboardWillHideNotification {
            keyboardEndFrameInScreen = .null
        }
    }

    // MARK: - ObjC-visible surface

    @objc var text: String {
        get { textView.text }
        set { textView.text = newValue }
    }

    @objc var editorIsEditable: Bool {
        get { textView.isEditable }
        set { textView.isEditable = newValue }
    }

    @objc var lineWrappingEnabled: Bool {
        get { textView.isLineWrappingEnabled }
        set { textView.isLineWrappingEnabled = newValue }
    }

    @objc var invisibleCharactersVisible: Bool {
        get { textView.showTabs }
        set {
            textView.showTabs = newValue
            textView.showSpaces = newValue
            textView.showLineBreaks = newValue
        }
    }

    @objc func setIndentUsesTabs(_ usesTabs: Bool, width: Int) {
        textView.indentStrategy = usesTabs ? .tab(length: width) : .space(length: width)
    }

    @objc func setLineEndingStyle(_ style: Int) {
        switch style {
        case 1: textView.lineEndings = .crlf
        case 2: textView.lineEndings = .cr
        default: textView.lineEndings = .lf
        }
    }

    @objc func setLanguageEnabled(_ enabled: Bool) {
        let mode: LanguageMode
        if enabled, let spec = currentLanguageSpec {
            let highlightsQuery: TreeSitterLanguage.Query?
            if let resource = spec.queryResource {
                highlightsQuery = Self.queryForResource(name: resource)
            } else {
                highlightsQuery = nil
            }
            mode = TreeSitterLanguageMode(language: TreeSitterLanguage(
                spec.language,
                highlightsQuery: highlightsQuery,
                injectionsQuery: nil,
                indentationScopes: nil))
        } else {
            mode = PlainTextLanguageMode()
        }
        textView.setLanguageMode(mode)
    }

    @objc func setLanguageForExtension(_ ext: String) {
        currentLanguageSpec = ffLanguages[ext.lowercased()]
        setLanguageEnabled(currentLanguageSpec != nil)
    }

    private static func queryForResource(name: String) -> TreeSitterLanguage.Query? {
        var candidates: [URL] = []
        if let url = Bundle.main.url(forResource: name, withExtension: "scm",
                                     subdirectory: "Languages/\(name)") {
            candidates.append(url)
        }
        for url in candidates {
            if let query = TreeSitterLanguage.Query(contentsOf: url) {
                return query
            }
        }
        return nil
    }

    // MARK: - Editing surface

    @objc override func becomeFirstResponder() -> Bool {
        return textView.becomeFirstResponder()
    }

    @objc override func resignFirstResponder() -> Bool {
        return textView.resignFirstResponder()
    }

    @objc func reloadEditorInputViews() {
        textView.reloadInputViews()
    }

    @objc var editorInputAccessoryView: UIView? {
        get { textView.inputAccessoryView }
        set { textView.inputAccessoryView = newValue }
    }

    @objc func canUndo() -> Bool { textView.undoManager?.canUndo ?? false }
    @objc func undo() { textView.undoManager?.undo() }
    @objc func canRedo() -> Bool { textView.undoManager?.canRedo ?? false }
    @objc func redo() { textView.undoManager?.redo() }

    @objc func insertText(_ text: String) { textView.insertText(text) }
    @objc func deleteBackward() { textView.deleteBackward() }
    @objc func indentOut() { textView.shiftLeft() }
    @objc func indentIn() { textView.shiftRight() }

    @objc func goToLine(_ line: Int) -> Bool {
        textView.goToLine(max(0, line - 1))
    }

    @objc func selectRange(_ range: NSRange) {
        let nsText = textView.text as NSString
        guard range.location != NSNotFound, range.location <= nsText.length else { return }
        let length = min(range.length, nsText.length - range.location)
        let target = NSRange(location: range.location, length: length)
        textView.selectedRange = target
        textView.scrollRangeToVisible(target)
    }

    /// Previous / Next 共用的唯一搜索定位路径。
    ///
    /// 修复两个独立问题：
    /// 1. Runestone 对远距离 range 会懒布局，第一次 firstRect(for:) 不能作为
    ///    文档绝对 y 直接赋给 contentOffset；旧实现因此会跳到 100/200/300
    ///    行等无关位置，等相关区域布局过一次后才“看起来正常”。
    /// 2. 连续快速点 ↑/↓ 时，多次 animated setContentOffset 会重叠，旧动画/
    ///    延迟 layout 可能在新 match 选中后继续改 offset。
    ///
    /// 现在先让 Runestone 自己 scrollRangeToVisible 物化目标布局，再在下一轮
    /// 主线程用 UITextInput 契约返回的 rect 转到 window 坐标；按真实 keyboard
    /// + inputAccessoryView 遮挡计算 effective viewport，只做 delta 校正。
    @objc func selectRangeCentered(_ range: NSRange) {
        let nsText = textView.text as NSString
        guard range.location != NSNotFound,
              range.location <= nsText.length,
              range.length > 0 else { return }

        let length = min(range.length, nsText.length - range.location)
        guard length > 0 else { return }
        let target = NSRange(location: range.location, length: length)

        searchNavigationGeneration &+= 1
        let generation = searchNavigationGeneration

        // 终止上一项还在进行的 UIScrollView 动画，避免 Previous/Next 快速交替时
        // 旧动画在新选择之后继续落地。
        textView.setContentOffset(textView.contentOffset, animated: false)
        textView.selectedRange = target

        // 第一步只负责让 Runestone 建立远距离目标的 layout fragment。
        textView.scrollRangeToVisible(target)

        DispatchQueue.main.async { [weak self] in
            self?.correctSearchSelectionViewport(target,
                                                 generation: generation,
                                                 remainingPasses: 2)
        }
    }

    private func correctSearchSelectionViewport(_ target: NSRange,
                                                generation: UInt64,
                                                remainingPasses: Int) {
        guard generation == searchNavigationGeneration,
              NSEqualRanges(textView.selectedRange, target),
              let window = textView.window else { return }

        textView.layoutIfNeeded()
        guard
            let start = textView.position(from: textView.beginningOfDocument,
                                          offset: target.location),
            let end = textView.position(from: textView.beginningOfDocument,
                                        offset: NSMaxRange(target)),
            let uiRange = textView.textRange(from: start, to: end)
        else {
            textView.scrollRangeToVisible(target)
            return
        }

        let localRect = textView.firstRect(for: uiRange)
        guard !localRect.isNull, !localRect.isInfinite,
              localRect.height > 0 else {
            if remainingPasses > 0 {
                textView.scrollRangeToVisible(target)
                DispatchQueue.main.async { [weak self] in
                    self?.correctSearchSelectionViewport(target,
                                                         generation: generation,
                                                         remainingPasses: remainingPasses - 1)
                }
            }
            return
        }

        let matchFrame = textView.convert(localRect, to: window)
        var visibleFrame = textView.convert(textView.bounds, to: window)
            .intersection(window.bounds)
        guard !visibleFrame.isNull, visibleFrame.height > 1 else { return }

        // keyboardFrameEndUserInfoKey 是 screen coordinate space；转换到当前 window。
        if !keyboardEndFrameInScreen.isNull {
            let keyboardFrame = window.convert(keyboardEndFrameInScreen,
                                               from: window.screen.coordinateSpace)
            if keyboardFrame.intersects(visibleFrame) {
                visibleFrame.size.height = max(0, keyboardFrame.minY - visibleFrame.minY)
            }
        }

        // 某些 iOS 版本 keyboard notification 的 frame 不含自定义 accessory；
        // 直接读取实际 findBar/accessory 的 window frame 再收一次底边。
        if let accessory = textView.inputAccessoryView,
           accessory.window === window {
            let accessoryFrame = accessory.convert(accessory.bounds, to: window)
            if accessoryFrame.intersects(visibleFrame) {
                visibleFrame.size.height = max(0, accessoryFrame.minY - visibleFrame.minY)
            }
        }

        // 太小的 viewport 不做强制居中，但仍保留上面的系统 scrollRangeToVisible。
        guard visibleFrame.height >= 80 else { return }

        // 当前命中放在实际可见正文的 42% 高度，略偏上，Prev/Next 完全同路。
        let desiredY = visibleFrame.minY + visibleFrame.height * 0.42
        let deltaY = matchFrame.midY - desiredY
        guard abs(deltaY) > 1 else { return }

        let insets = textView.adjustedContentInset
        let minY = -insets.top
        let maxY = max(minY,
            textView.contentSize.height - textView.bounds.height + insets.bottom)
        let proposedY = textView.contentOffset.y + deltaY
        let clampedY = min(max(proposedY, minY), maxY)

        // 搜索导航要求确定性，禁用动画；快速连点不会累积动画状态。
        textView.setContentOffset(
            CGPoint(x: textView.contentOffset.x, y: clampedY), animated: false)

        // 自动换行 / lazy layout 在第一次校正后 contentSize/rect 可能细微变化。
        // 同 generation 最多再验一次；一旦用户点到另一项，generation 立即失效。
        if remainingPasses > 0 {
            DispatchQueue.main.async { [weak self] in
                self?.correctSearchSelectionViewport(target,
                                                     generation: generation,
                                                     remainingPasses: remainingPasses - 1)
            }
        }
    }

    @objc func setSearchHighlights(_ ranges: [NSValue]) {
        textView.highlightedRanges = ranges.map {
            HighlightedRange(range: $0.rangeValue,
                             color: UIColor.systemYellow.withAlphaComponent(0.3),
                             cornerRadius: 2)
        }
    }

    @objc func clearSearchHighlights() {
        textView.highlightedRanges = []
    }

    @objc func applyReplacements(_ ranges: [NSValue], texts: [String]) {
        var replacements: [BatchReplaceSet.Replacement] = []
        for (index, value) in ranges.enumerated() {
            let range = value.rangeValue
            let replacementText = index < texts.count ? texts[index] : ""
            replacements.append(BatchReplaceSet.Replacement(range: range, text: replacementText))
        }
        if !replacements.isEmpty {
            textView.replaceText(in: BatchReplaceSet(replacements: replacements))
        }
    }

    @objc func currentText() -> String {
        textView.text
    }
}

extension FFCodeEditorView: TextViewDelegate {
    func textViewDidChange(_ textView: TextView) {
        onTextChanged?()
    }

    func textViewDidBeginEditing(_ textView: TextView) {
        onDidBeginEditing?()
    }

    func textViewDidEndEditing(_ textView: TextView) {
        onDidEndEditing?()
    }
}
