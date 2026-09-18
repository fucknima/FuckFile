import SwiftUI
import UIKit

/// SQLite 只读浏览器（对齐 FFSQLiteBrowserViewController）：
/// 表/视图分组与行数、分页行列表（每页 200 行）、行详情、结构查看、CSV 导出分享。
struct SQLiteBrowserView: View {
    let entry: FileEntry

    @State private var service: SQLiteService?
    @State private var summary = ""
    @State private var tables: [String] = []
    @State private var views: [String] = []
    @State private var rowCounts: [String: Int64] = [:]
    @State private var isLoading = true
    @State private var loadError: String?

    init(entry: FileEntry) {
        self.entry = entry
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("正在打开数据库…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                errorState(loadError)
            } else if let service {
                content(service)
            } else {
                errorState("无法打开数据库")
            }
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: - 内容

    private func content(_ service: SQLiteService) -> some View {
        List {
            Section("数据库") {
                Text(summary.isEmpty ? "—" : summary)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Section("表（\(tables.count)）") {
                if tables.isEmpty {
                    Text("无表").foregroundColor(.secondary)
                }
                ForEach(tables, id: \.self) { name in
                    objectRow(service, name: name, icon: "tablecells")
                }
            }
            Section("视图（\(views.count)）") {
                if views.isEmpty {
                    Text("无视图").foregroundColor(.secondary)
                }
                ForEach(views, id: \.self) { name in
                    objectRow(service, name: name, icon: "eye")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func objectRow(_ service: SQLiteService, name: String, icon: String) -> some View {
        NavigationLink {
            SQLiteTableBrowserView(service: service, objectName: name)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundColor(.accentColor)
                    .frame(width: 22)
                Text(name)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(countText(name))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func countText(_ name: String) -> String {
        guard let count = rowCounts[name] else { return "统计中…" }
        return count < 0 ? "—" : "\(count) 行"
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "cylinder.split.1x2")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("无法打开数据库")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("重试") { Task { await load() } }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 载入

    @MainActor
    private func load() async {
        isLoading = true
        loadError = nil
        let path = entry.path
        let result = await Task.detached(priority: .userInitiated) {
            () -> Result<SQLiteOpenResult, Error> in
            do {
                let service = try SQLiteService(path: path)
                let summary = try service.databaseSummary()
                let tables = try service.tableNames()
                let views = try service.viewNames()
                return .success(SQLiteOpenResult(service: service, summary: summary,
                                                 tables: tables, views: views))
            } catch {
                return .failure(error)
            }
        }.value

        isLoading = false
        switch result {
        case .success(let loaded):
            service = loaded.service
            summary = loaded.summary
            tables = loaded.tables
            views = loaded.views
            AppLog.tag("SQLite", "open \(path) tables=\(loaded.tables.count) views=\(loaded.views.count)")
            await loadRowCounts(service: loaded.service, names: loaded.tables + loaded.views)
        case .failure(let error):
            service = nil
            loadError = error.localizedDescription
            AppLog.tag("SQLite", "open FAIL \(path) \(error.localizedDescription)")
        }
    }

    /// 逐个后台统计行数，算完一个更新一个；失败显示「—」。
    @MainActor
    private func loadRowCounts(service: SQLiteService, names: [String]) async {
        for name in names {
            let count = await Task.detached(priority: .utility) {
                try? service.rowCount(forObject: name)
            }.value
            rowCounts[name] = count ?? -1
        }
    }
}

private struct SQLiteOpenResult {
    let service: SQLiteService
    let summary: String
    let tables: [String]
    let views: [String]
}

// MARK: - 表/视图数据

private struct SQLiteTableBrowserView: View {
    let service: SQLiteService
    let objectName: String

    @State private var columns: [String] = []
    @State private var rows: [[String]] = []
    @State private var offset = 0
    @State private var totalRows: Int64?
    @State private var isLoading = true
    @State private var pageError: String?
    @State private var isSchemaPresented = false
    @State private var isExporting = false
    @State private var exportedFile: SQLiteExportedFile?
    @State private var alertMessage = ""
    @State private var isAlertPresented = false

    private let pageSize = 200

    var body: some View {
        Group {
            if isLoading && rows.isEmpty {
                ProgressView("正在查询…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let pageError {
                errorState(pageError)
            } else if rows.isEmpty {
                emptyState
            } else {
                rowList
            }
        }
        .navigationTitle(objectName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task {
            await loadPage(offset: 0)
            await loadTotal()
        }
        .sheet(isPresented: $isSchemaPresented) {
            SQLiteSchemaSheet(service: service, objectName: objectName)
        }
        .sheet(item: $exportedFile) { file in
            SQLiteShareSheet(activityItems: [file.url])
        }
        .alert("提示", isPresented: $isAlertPresented) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private var rowList: some View {
        List {
            Section {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    NavigationLink {
                        SQLiteRowDetailView(columns: columns, values: row)
                    } label: {
                        Text(summaryLine(row))
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(3)
                    }
                }
            } footer: {
                Text(statusText)
            }
            Section {
                HStack {
                    Button("上一页") {
                        Task { await loadPage(offset: max(0, offset - pageSize)) }
                    }
                    .disabled(offset == 0 || isLoading)
                    Spacer()
                    if isLoading { ProgressView() }
                    Spacer()
                    Button("下一页") {
                        Task { await loadPage(offset: offset + pageSize) }
                    }
                    .disabled(!canGoNext || isLoading)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("该对象没有数据")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("查询失败")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("重试") { Task { await loadPage(offset: offset) } }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button { isSchemaPresented = true } label: {
                Label("结构", systemImage: "doc.text.magnifyingglass")
            }
            if isExporting {
                ProgressView()
            } else {
                Button { exportCSV() } label: {
                    Label("导出 CSV", systemImage: "square.and.arrow.up")
                }
                .disabled(columns.isEmpty)
            }
        }
    }

    // MARK: - 分页

    @MainActor
    private func loadPage(offset newOffset: Int) async {
        isLoading = true
        let name = objectName
        let limit = pageSize
        let service = self.service
        let result = await Task.detached(priority: .userInitiated) {
            () -> Result<SQLiteQueryResult, Error> in
            do {
                return .success(try service.rows(inObject: name, limit: limit, offset: newOffset))
            } catch {
                return .failure(error)
            }
        }.value

        isLoading = false
        switch result {
        case .success(let page):
            pageError = nil
            columns = page.columns
            rows = page.rows
            offset = newOffset
        case .failure(let error):
            if rows.isEmpty {
                pageError = error.localizedDescription
            } else {
                alertMessage = error.localizedDescription
                isAlertPresented = true
            }
        }
    }

    @MainActor
    private func loadTotal() async {
        let name = objectName
        let service = self.service
        totalRows = await Task.detached(priority: .utility) {
            try? service.rowCount(forObject: name)
        }.value
    }

    private var canGoNext: Bool {
        guard rows.count == pageSize else { return false }
        if let totalRows, totalRows >= 0 {
            return Int64(offset + pageSize) < totalRows
        }
        return true
    }

    private var statusText: String {
        guard !rows.isEmpty else { return "没有数据" }
        let position = "显示第 \(offset + 1)–\(offset + rows.count) 行"
        if let totalRows, totalRows >= 0 {
            return "共 \(totalRows) 行 · " + position
        }
        return position
    }

    private func summaryLine(_ row: [String]) -> String {
        var line = ""
        for (index, column) in columns.enumerated() {
            if !line.isEmpty { line += " | " }
            line += "\(column)=\(index < row.count ? row[index] : "")"
        }
        return line
    }

    // MARK: - 导出

    @MainActor
    private func exportCSV() {
        guard !isExporting else { return }
        isExporting = true
        let name = objectName
        let service = self.service
        Task.detached(priority: .userInitiated) {
            do {
                let safeName = name
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: ":", with: "_")
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(safeName.isEmpty ? "export" : safeName)
                    .appendingPathExtension("csv")
                let written = try service.exportCSV(forObject: name, to: url)
                AppLog.tag("SQLite", "export \(name) rows=\(written) path=\(url.path)")
                await MainActor.run {
                    isExporting = false
                    exportedFile = SQLiteExportedFile(url: url)
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    alertMessage = "导出失败：\(error.localizedDescription)"
                    isAlertPresented = true
                }
            }
        }
    }
}

// MARK: - 行详情

private struct SQLiteRowDetailView: View {
    let columns: [String]
    let values: [String]

    var body: some View {
        List {
            ForEach(Array(columns.enumerated()), id: \.offset) { index, name in
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(index < values.count ? values[index] : "")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("行详情")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 结构

private struct SQLiteSchemaSheet: View {
    let service: SQLiteService
    let objectName: String

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var errorText: String?
    @State private var isLoading = true

    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    ProgressView("正在读取结构…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(32)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        Text(text)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
            }
            .navigationTitle("\(objectName) 结构")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("复制") { UIPasteboard.general.string = text }
                        .disabled(text.isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
        .task { await load() }
    }

    @MainActor
    private func load() async {
        isLoading = true
        errorText = nil
        let name = objectName
        let service = self.service
        let result = await Task.detached(priority: .userInitiated) {
            () -> Result<String, Error> in
            do {
                var body = try service.schema(forObject: name)
                if body.isEmpty { body = "-- 无 schema" }
                for index in try service.indexNames(forTable: name) {
                    let sql = try service.schema(forObject: index)
                    if !sql.isEmpty { body += "\n\n\(index)\n\(sql)" }
                }
                return .success(body)
            } catch {
                return .failure(error)
            }
        }.value

        isLoading = false
        switch result {
        case .success(let body): text = body
        case .failure(let error): errorText = error.localizedDescription
        }
    }
}

// MARK: - 分享

private struct SQLiteExportedFile: Identifiable {
    var id: String { url.path }
    let url: URL
}

private struct SQLiteShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
