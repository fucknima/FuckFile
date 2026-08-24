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

/// theos 下没有 SPM 资源包；Bundle.module 指向主 bundle。
extension Bundle {
    static var module: Bundle { .main }
}

/// 编辑器回调（ObjC 侧以 block 注入，跨语言边界稳定）。

/// 可设置的字符对（自动闭合）。
final class FFSimpleCharacterPair: CharacterPair {
    let leading: String
    let trailing: String
    init(_ leading: String, _ trailing: String) {
        self.leading = leading
        self.trailing = trailing
    }
}

/// 单文件语言配置（parser 指针 + 可选 highlights query 资源名）。
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
    // .mm 用 cpp grammar（ObjC++ 高亮以 cpp 为主，比无高亮强）。
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

    public var onTextChanged: (() -> Void)?
    public var onDidBeginEditing: (() -> Void)?
    public var onDidEndEditing: (() -> Void)?

    private let textView = TextView()
    private var characterPairList: [CharacterPair] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
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

    /// 启用/禁用语法高亮（第 2 档大文件降级：禁用 tree-sitter 语言模式）。
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

    /// 根据扩展名（不含点）设置语言并启用高亮。
    @objc func setLanguageForExtension(_ ext: String) {
        currentLanguageSpec = ffLanguages[ext.lowercased()]
        setLanguageEnabled(currentLanguageSpec != nil)
    }

    private var currentLanguageSpec: FFLanguageSpec?

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
        // 兜底：读主 bundle 顶层（开发未打包资源时）。
        return nil
    }

    // MARK: - Editing surface

    @objc override var canBecomeFirstResponder: Bool { true }

    @objc override func becomeFirstResponder() -> Bool {
        super.becomeFirstResponder()
        return textView.becomeFirstResponder()
    }

    @objc override func resignFirstResponder() -> Bool {
        let was = textView.resignFirstResponder()
        _ = super.resignFirstResponder()
        return was
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

    /// 选区定位 + 光标滚动。
    @objc func selectRange(_ range: NSRange) {
        let length = min(range.length, max(0, (textView.text as NSString).length - range.location))
        textView.selectedRange = NSRange(location: range.location, length: max(0, length))
        textView.scrollRangeToVisible(textView.selectedRange)
    }

    /// 高亮一批查找命中。
    @objc func setSearchHighlights(_ ranges: [NSValue]) {
        textView.highlightedRanges = ranges.map {
            HighlightedRange(range: $0.rangeValue, color: UIColor.systemYellow.withAlphaComponent(0.3), cornerRadius: 2)
        }
    }

    @objc func clearSearchHighlights() {
        textView.highlightedRanges = []
    }

    /// 批量替换（单次 undo）。ranges 基于当前文本。
    @objc func applyReplacements(_ ranges: [NSValue], texts: [String]) {
        var replacements: [BatchReplaceSet.Replacement] = []
        for (index, value) in ranges.enumerated() {
            let range = value.rangeValue
            let replacementText = index < texts.count ? texts[index] : ""
            replacements.append(BatchReplaceSet.Replacement(range: range, text: replacementText))
        }
        if !replacements.isEmpty {
            // 逆序应用会破坏相对 range（BatchReplaceSet 需要相对于当前文本
            // 的 range）；Runestone 在一次批处理内部按倒序替换，因此这里
            // 直接按其约定传入即可（见 TextView.replaceText(in:)）。
            textView.replaceText(in: BatchReplaceSet(replacements: replacements))
        }
    }

    /// 当前文本（查找用）。
    @objc func currentText() -> String {
        textView.text
    }
}

// MARK: - TextViewDelegate 桥接（Swift 侧）

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
