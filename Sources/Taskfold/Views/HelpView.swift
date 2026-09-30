import SwiftUI

/// 应用内帮助窗口：加载并渲染打包进 bundle 的 Help.md（Sources/Taskfold/Resources/Help.md）。
/// 双构建体系兼容：SPM（make run）资源在 Bundle.module 的 Resources/ 子目录，
/// xcodeproj（.app）由 Resources 构建阶段平铺到 Bundle.main 资源根，故做双路径探测。
struct HelpView: View {
    enum Content: Equatable {
        case loading
        case loaded(blocks: [HelpBlock])
        case failed
    }

    /// 帮助文档使用的 Markdown 子集块级元素（文档与解析器约定，不追求通用）
    enum HelpBlock: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case list(items: [ListItem])
        case table(rows: [[String]])
        case divider
    }

    struct ListItem: Equatable {
        var marker: String
        var text: String
    }

    @State private var content: Content = .loading

    var body: some View {
        Group {
            switch content {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                ContentUnavailableView {
                    Label("找不到帮助文档", systemImage: "questionmark.square.dashed")
                } description: {
                    Text("打包资源 Help.md 缺失，请重新构建应用。")
                }
            case .loaded(let blocks):
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                            blockView(block)
                        }
                        if let version = versionFooter {
                            Divider()
                            Text(version)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: 660, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .textSelection(.enabled)
        .task {
            guard content == .loading else { return }
            if let markdown = Self.loadMarkdown() {
                content = .loaded(blocks: Self.parse(markdown))
            } else {
                content = .failed
            }
        }
    }

    // MARK: 块渲染

    @ViewBuilder
    private func blockView(_ block: HelpBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            headingView(level: level, text: text)
        case .paragraph(let text):
            helpInlineText(text)
                .font(.body)
        case .list(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.marker)
                            .foregroundStyle(.secondary)
                        helpInlineText(item.text)
                    }
                }
            }
            .padding(.leading, 6)
        case .table(let rows):
            HelpTableView(rows: rows)
        case .divider:
            Divider()
        }
    }

    @ViewBuilder
    private func headingView(level: Int, text: String) -> some View {
        switch level {
        case 1:
            Text(text)
                .font(.largeTitle.bold())
        case 2:
            VStack(alignment: .leading, spacing: 10) {
                Text(text)
                    .font(.title2.bold())
                Divider()
            }
        default:
            Text(text)
                .font(.title3.bold())
                .padding(.top, 4)
        }
    }

    /// 窗口底部版本号（读自 .app 的 Info；SPM 裸可执行没有则不显示）
    private var versionFooter: String? {
        guard let version = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        else { return nil }
        return "Taskfold \(version)"
    }

    // MARK: 资源加载（双构建体系兼容）

    private static func loadMarkdown() -> String? {
        let bundle: Bundle
        #if SWIFT_PACKAGE
        bundle = Bundle.module
        #else
        bundle = Bundle.main
        #endif
        let url = bundle.url(forResource: "Help", withExtension: "md")
            ?? bundle.url(forResource: "Help", withExtension: "md", subdirectory: "Resources")
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    // MARK: Markdown 子集解析（标题 / 段落 / 无序+有序列表 / 表格 / 分隔线）

    private static func parse(_ markdown: String) -> [HelpBlock] {
        var blocks: [HelpBlock] = []
        var tableRows: [[String]] = []
        var listItems: [ListItem] = []

        func flushTable() {
            guard !tableRows.isEmpty else { return }
            blocks.append(.table(rows: tableRows))
            tableRows = []
        }
        func flushList() {
            guard !listItems.isEmpty else { return }
            blocks.append(.list(items: listItems))
            listItems = []
        }

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushTable()
                flushList()
                continue
            }
            if line.hasPrefix("|") {
                var cells = line
                    .split(separator: "|", omittingEmptySubsequences: false)
                    .dropFirst()
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.last == "" { cells.removeLast() }  // 丢掉行尾竖线产生的空尾格
                let isSeparator = !cells.isEmpty && cells.allSatisfy { cell in
                    cell.allSatisfy { $0 == "-" || $0 == ":" }
                }
                if !isSeparator { tableRows.append(cells) }
                continue
            }
            flushTable()
            if line.hasPrefix("#") {
                flushList()
                let level = line.prefix(while: { $0 == "#" }).count
                let text = line.dropFirst(level).drop(while: { $0 == " " })
                blocks.append(.heading(level: min(level, 4), text: String(text)))
            } else if line == "---" {
                flushList()
                blocks.append(.divider)
            } else if line.hasPrefix("- ") {
                listItems.append(ListItem(marker: "•", text: String(line.dropFirst(2))))
            } else if let item = orderedListItem(line) {
                listItems.append(item)
            } else {
                flushList()
                blocks.append(.paragraph(line))
            }
        }
        flushTable()
        flushList()
        return blocks
    }

    /// 识别 "1. xxx" 形式的有序列表行（限一两位数字，避免把年份误判为列表）
    private static func orderedListItem(_ line: String) -> ListItem? {
        guard let match = line.firstMatch(of: #/^(\d{1,2})\.\s+(.+)$/#) else { return nil }
        return ListItem(marker: "\(match.1).", text: String(match.2))
    }
}

/// 行内 Markdown（**粗体**、*斜体*、[链接]）交给 Foundation 解析，失败退回纯文本
private func helpInlineText(_ raw: String) -> Text {
    let attributed: AttributedString
    do {
        attributed = try AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
    } catch {
        attributed = AttributedString(raw)
    }
    return Text(attributed)
}

/// 帮助文档表格：首行表头加粗、斑马纹、圆角描边（快捷键表等均为两列）
private struct HelpTableView: View {
    let rows: [[String]]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { columnIndex, cell in
                        helpInlineText(cell)
                            .font(rowIndex == 0 ? .subheadline.bold() : .subheadline)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .frame(minWidth: columnIndex == 0 ? 96 : 200, alignment: .leading)
                            .background(rowBackground(rowIndex))
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.1))
        )
    }

    private func rowBackground(_ rowIndex: Int) -> Color {
        if rowIndex == 0 { return Color.primary.opacity(0.06) }
        return rowIndex % 2 == 0 ? Color.primary.opacity(0.03) : .clear
    }
}
