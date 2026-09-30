import Foundation

// MARK: - 导出（DATA-2：CSV / OPML / Markdown）

public enum ExportFormat: String, CaseIterable, Sendable {
    case csv
    case opml
    case markdown

    public var fileExtension: String {
        switch self {
        case .csv: "csv"
        case .opml: "opml"
        case .markdown: "md"
        }
    }

    public var label: String {
        switch self {
        case .csv: "CSV 表格"
        case .opml: "OPML 大纲"
        case .markdown: "Markdown"
        }
    }
}

/// 从 TaskStore 导出全部数据（含已完成/放弃任务），供菜单导出与测试使用
public struct TaskExporter: Sendable {
    private let store: TaskStore

    public init(store: TaskStore) {
        self.store = store
    }

    // MARK: 树结构收集

    /// 一个顶层任务及其全部后代（先序遍历，带深度）
    private struct TreeNode {
        let task: TaskItem
        let depth: Int
        let children: [TreeNode]
    }

    private func collectTree(includeCompleted: Bool = true) throws -> (projects: [ProjectItem], byProject: [UUID: [TreeNode]], inbox: [TreeNode]) {
        let projects = try store.projects()
        let subtasks = try store.subtasksTree(includeCompleted: includeCompleted)

        func build(_ task: TaskItem, depth: Int) -> TreeNode {
            let children = (subtasks[task.id] ?? []).map { build($0, depth: depth + 1) }
            return TreeNode(task: task, depth: depth, children: children)
        }

        var byProject: [UUID: [TreeNode]] = [:]
        for project in projects {
            byProject[project.id] = try store.projectTasks(project.id, includeCompleted: includeCompleted)
                .map { build($0, depth: 0) }
        }
        let inbox = try store.inboxTasks(includeCompleted: includeCompleted).map { build($0, depth: 0) }
        return (projects, byProject, inbox)
    }

    // MARK: 通用格式化

    private func statusText(_ status: ItemStatus) -> String {
        switch status {
        case .active: "进行中"
        case .completed: "已完成"
        case .dropped: "已放弃"
        }
    }

    private func dueText(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    // MARK: CSV

    /// UTF-8 带 BOM；全字段引号包裹，内部引号翻倍（RFC 4180）
    public func csv() throws -> String {
        let tree = try collectTree()
        var rows: [[String]] = [["标题", "项目", "父任务", "状态", "截止", "创建时间", "备注"]]

        var titleByID: [UUID: String] = [:]
        for (_, nodes) in tree.byProject {
            for node in nodes { index(node, into: &titleByID) }
        }
        for node in tree.inbox { index(node, into: &titleByID) }

        func index(_ node: TreeNode, into map: inout [UUID: String]) {
            map[node.task.id] = node.task.title
            for child in node.children { index(child, into: &map) }
        }

        func append(_ node: TreeNode, projectName: String) {
            let t = node.task
            rows.append([
                t.title,
                projectName,
                t.parentID.flatMap { titleByID[$0] } ?? "",
                statusText(t.status),
                dueText(t.dueDate),
                dueText(t.createdAt),
                t.note.replacingOccurrences(of: "\n", with: " "),
            ])
            for child in node.children { append(child, projectName: projectName) }
        }

        for project in tree.projects {
            for node in tree.byProject[project.id] ?? [] {
                append(node, projectName: project.name)
            }
        }
        for node in tree.inbox { append(node, projectName: "收件箱") }

        let body = rows.map { row in
            row.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
        }.joined(separator: "\r\n")
        return "\u{FEFF}\(body)\n"
    }

    // MARK: OPML 2.0

    private func xmlEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func opmlText(_ task: TaskItem) -> String {
        var text = task.title
        switch task.status {
        case .completed: text = "[已完成] " + text
        case .dropped: text = "[已放弃] " + text
        case .active: break
        }
        if let due = task.dueDate {
            text += "（截止 \(dueText(due))）"
        }
        return text
    }

    private func opmlOutline(_ node: TreeNode, indent: String) -> String {
        var xml = "\(indent)<outline text=\"\(xmlEscape(opmlText(node.task)))\""
        if node.children.isEmpty {
            return xml + "/>\n"
        }
        xml += ">\n"
        for child in node.children {
            xml += opmlOutline(child, indent: indent + "  ")
        }
        return xml + indent + "</outline>\n"
    }

    public func opml() throws -> String {
        let tree = try collectTree()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head>
            <title>Taskfold 导出 \(xmlEscape(formatter.string(from: Date())))</title>
          </head>
          <body>

        """
        for project in tree.projects {
            let nodes = tree.byProject[project.id] ?? []
            var xmlProject = "    <outline text=\"\(xmlEscape(project.name))\""
            if nodes.isEmpty {
                xml += xmlProject + "/>\n"
                continue
            }
            xmlProject += ">\n"
            for node in nodes { xmlProject += opmlOutline(node, indent: "      ") }
            xml += xmlProject + "    </outline>\n"
        }
        if !tree.inbox.isEmpty {
            var inboxXml = "    <outline text=\"收件箱\">\n"
            for node in tree.inbox { inboxXml += opmlOutline(node, indent: "      ") }
            xml += inboxXml + "    </outline>\n"
        }
        xml += "  </body>\n</opml>\n"
        return xml
    }

    // MARK: Markdown（GFM 任务列表）

    private func markdownLine(_ node: TreeNode) -> String {
        let t = node.task
        let indent = String(repeating: "  ", count: node.depth)
        var line: String
        switch t.status {
        case .active: line = "\(indent)- [ ] \(t.title)"
        case .completed: line = "\(indent)- [x] \(t.title)"
        case .dropped: line = "\(indent)- ~~\(t.title)~~"
        }
        if let due = t.dueDate {
            let overdueMark = (t.status == .active && due < Date()) ? "（已逾期）" : ""
            line += "（截止 \(dueText(due))）\(overdueMark)"
        }
        return line
    }

    private func markdownTree(_ nodes: [TreeNode]) -> String {
        var lines: [String] = []
        func walk(_ node: TreeNode) {
            lines.append(markdownLine(node))
            for child in node.children { walk(child) }
        }
        for node in nodes { walk(node) }
        return lines.joined(separator: "\n")
    }

    public func markdown() throws -> String {
        let tree = try collectTree()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        var md = "# Taskfold 导出（\(formatter.string(from: Date()))）\n\n"
        for project in tree.projects {
            md += "## \(project.name)\n\n"
            let nodes = tree.byProject[project.id] ?? []
            md += nodes.isEmpty ? "_（无任务）_\n\n" : markdownTree(nodes) + "\n\n"
        }
        if !tree.inbox.isEmpty {
            md += "## 收件箱\n\n" + markdownTree(tree.inbox) + "\n\n"
        }
        return md
    }
}
