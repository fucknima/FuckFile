import Foundation

enum FileConflictPolicy: String, CaseIterable, Identifiable {
    case ask, replace, keepBoth, skip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: return "询问"
        case .replace: return "替换"
        case .keepBoth: return "保留两者"
        case .skip: return "跳过"
        }
    }
}
