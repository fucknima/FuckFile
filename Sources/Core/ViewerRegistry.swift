import Foundation

/// 查看器标识：展示名与 SF Symbol 照抄 Objective-C 版 FFViewerRegistry，
/// 是关联表、设置页与打开入口共用的唯一身份。
enum ViewerID: String, CaseIterable, Identifiable {
    case quickLook, image, media, pdf, text, web, sqlite, hex, archive, plist, office, spreadsheet, macho

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quickLook: return "快速查看"
        case .image: return "图片浏览器"
        case .media: return "媒体播放器"
        case .pdf: return "PDF 阅读器"
        case .text: return "文本编辑器"
        case .web: return "Web Viewer"
        case .sqlite: return "SQLite3 编辑器"
        case .hex: return "十六进制编辑器"
        case .archive: return "压缩包浏览器"
        case .plist: return "属性表编辑器"
        case .office: return "Office 阅读器"
        case .spreadsheet: return "电子表格"
        case .macho: return "Mach-O 检查器"
        }
    }

    var icon: String {
        switch self {
        case .quickLook: return "square.on.square.intersection.dashed"
        case .image: return "photo"
        case .media: return "play.circle"
        case .pdf: return "doc.richtext"
        case .text: return "doc.plaintext"
        case .web: return "safari"
        case .sqlite: return "cylinder.split.1x2"
        case .hex: return "waveform.path.ecg"
        case .archive: return "archivebox"
        case .plist: return "list.bullet.rectangle"
        case .office: return "doc.text.magnifyingglass"
        case .spreadsheet: return "tablecells"
        case .macho: return "cpu"
        }
    }

    /// 阶段 3a 已实现：quickLook/image/media/pdf/text；其余由路由回退 quickLook。
    var isImplemented: Bool {
        switch self {
        case .quickLook, .image, .media, .pdf, .text: return true
        case .web, .sqlite, .hex, .archive, .plist, .office, .spreadsheet, .macho: return false
        }
    }
}
