import Foundation
import SwiftUI

/// Documents 根到当前目录的横向路径条：逐段可点，当前段高亮。
/// `path` 不在 Documents 下时只显示当前目录名一段；`onSelect` 回传被点段路径。
struct BreadcrumbView: View {
    private struct Segment: Identifiable {
        let name: String
        let path: String
        let isCurrent: Bool
        var id: String { path }
    }

    private let path: String
    private let onSelect: (String) -> Void

    init(path: String, onSelect: @escaping (String) -> Void) {
        self.path = path
        self.onSelect = onSelect
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                        if index > 0 {
                            Image(systemName: "chevron.compact.right")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        Button {
                            onSelect(segment.path)
                        } label: {
                            Text(segment.name)
                                .font(.footnote.weight(segment.isCurrent ? .semibold : .regular))
                                .foregroundStyle(segment.isCurrent ? Color.primary : Color.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(segment.isCurrent ? .isSelected : [])
                        .id(segment.path)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
            }
            .onAppear { scrollToCurrent(proxy) }
            .onChange(of: path) { _ in scrollToCurrent(proxy) }
        }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        guard let current = segments.last else { return }
        proxy.scrollTo(current.id, anchor: .trailing)
    }

    private var segments: [Segment] {
        let root = (StorageEnvironment.documentsPath as NSString).standardizingPath
        let current = (path as NSString).standardizingPath
        guard !current.isEmpty else { return [] }
        guard current == root || current.hasPrefix(root + "/") else {
            return [Segment(name: displayName(current), path: current, isCurrent: true)]
        }

        var result = [Segment(name: displayName(root), path: root, isCurrent: current == root)]
        guard current != root else { return result }
        var cursor = root
        for component in current.dropFirst(root.count).split(separator: "/") {
            cursor = (cursor as NSString).appendingPathComponent(String(component))
            result.append(Segment(name: String(component),
                                  path: cursor,
                                  isCurrent: cursor == current))
        }
        return result
    }

    private func displayName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
}
