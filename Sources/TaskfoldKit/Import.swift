import Foundation

// MARK: - 导入（DATA-2 补全：CSV / OPML，与导出格式对称）

/// 导入失败原因（用户可读描述见 errorDescription）
public enum ImportError: Error, Equatable, Sendable {
    /// 文件内容为空
    case emptyContent
    /// 没有任何可导入的数据
    case noData
    /// CSV 表头与导出格式不符
    case csvHeaderMismatch
    /// 数据行列数不符（附 1 起算行号）
    case csvRowColumns(Int)
    /// OPML XML 解析失败（附解析器报错）
    case xmlParseFailed(String)
}

extension ImportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyContent: "文件内容为空"
        case .noData: "文件中没有可导入的数据"
        case .csvHeaderMismatch: "CSV 表头与 Taskfold 导出格式不符（需为「导出为 CSV」生成的文件）"
        case .csvRowColumns(let line): "第 \(line) 行列数不符，应为 7 列"
        case .xmlParseFailed(let detail): "OPML 解析失败：\(detail)"
        }
    }
}

/// 解析产物：项目与任务均已构造完毕。
/// tasks 的 projectID 引用同批 projects 的 id（nil = 收件箱），parentID 指向同批任务；
/// 同名项目合并与 sortIndex 追加由 TaskStore.importData 落库时处理。
public struct ImportedData: Sendable {
    public var projects: [ProjectItem]
    public var tasks: [TaskItem]

    public init(projects: [ProjectItem] = [], tasks: [TaskItem] = []) {
        self.projects = projects
        self.tasks = tasks
    }
}

/// 解析 Taskfold 自有导出格式的 CSV / OPML（纯解析，不依赖 TaskStore）
public enum TaskImporter {

    private static let csvHeader = ["标题", "项目", "父任务", "状态", "截止", "创建时间", "备注"]
    fileprivate static let inboxName = "收件箱"

    private static func makeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"  // 与 TaskExporter 一致
        return formatter
    }

    /// 空串返回 nil；解析失败同样返回 nil（宽松，兼容手工编辑的文件）
    private static func parseDate(_ text: String, formatter: DateFormatter) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : formatter.date(from: trimmed)
    }

    /// 中文状态文本反查（与 TaskExporter.statusText 对称）；未知文本按进行中
    private static func status(from text: String) -> ItemStatus {
        ItemStatus.allCases.first { $0.label == text } ?? .active
    }

    // MARK: CSV

    public static func parseCSV(_ content: String) throws -> ImportedData {
        var text = content
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }  // 剥 UTF-8 BOM
        let rows = csvRows(from: text)

        guard let header = rows.first else { throw ImportError.emptyContent }
        guard header == csvHeader else { throw ImportError.csvHeaderMismatch }

        var data = ImportedData()
        var projectIDByName: [String: UUID] = [:]
        // 标题 → 最近出现任务的 id：导出行序为先序遍历，父任务必在子任务之前
        var taskIDByTitle: [String: UUID] = [:]
        let formatter = makeFormatter()

        for (index, fields) in rows.dropFirst().enumerated() {
            guard fields.count == csvHeader.count else { throw ImportError.csvRowColumns(index + 2) }
            let title = fields[0].trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }

            var projectID: UUID?
            let projectName = fields[1]
            if !projectName.isEmpty && projectName != inboxName {
                if let existing = projectIDByName[projectName] {
                    projectID = existing
                } else {
                    let project = ProjectItem(name: projectName)
                    projectIDByName[projectName] = project.id
                    data.projects.append(project)
                    projectID = project.id
                }
            }

            let parentTitle = fields[2]
            let task = TaskItem(
                title: title,
                note: fields[6],
                projectID: projectID,
                // 父任务按标题反查，找不到则置顶层（宽松）
                parentID: parentTitle.isEmpty ? nil : taskIDByTitle[parentTitle],
                status: status(from: fields[3]),
                dueDate: parseDate(fields[4], formatter: formatter),
                createdAt: parseDate(fields[5], formatter: formatter) ?? Date()
            )
            taskIDByTitle[title] = task.id
            data.tasks.append(task)
        }

        guard !data.tasks.isEmpty else { throw ImportError.noData }
        return data
    }

    /// RFC 4180 逐字符解析：引号包裹、内部引号翻倍、\r\n 或 \n 分行、引号内换行
    private static func csvRows(from content: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(content)
        var i = 0

        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 2
                    } else {
                        inQuotes = false
                        i += 1
                    }
                } else {
                    field.append(c)
                    i += 1
                }
                continue
            }
            switch c {
            case "\"": inQuotes = true; i += 1
            case ",": row.append(field); field = ""; i += 1
            case "\r", "\n", "\r\n":
                // CRLF 在 Swift String 中是单个 Character（grapheme），无需再看下一字符
                row.append(field); field = ""
                rows.append(row); row = []
                i += 1
            default: field.append(c); i += 1
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }  // 丢弃空行
    }

    // MARK: OPML 2.0

    public static func parseOPML(_ content: String) throws -> ImportedData {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImportError.emptyContent }
        guard trimmed.contains("<opml") else { throw ImportError.xmlParseFailed("缺少 <opml> 根元素") }

        let parser = XMLParser(data: Data(trimmed.utf8))
        let delegate = OPMLDelegate(formatter: makeFormatter())
        parser.delegate = delegate
        guard parser.parse() else {
            throw ImportError.xmlParseFailed(delegate.errorText ?? "XML 语法错误")
        }
        guard !delegate.data.tasks.isEmpty || !delegate.data.projects.isEmpty else {
            throw ImportError.noData
        }
        return delegate.data
    }

    /// 剥析 outline text 的状态前缀与截止后缀（与 TaskExporter.opmlText 对称）。
    /// 后缀格式固定为结尾的「（截止 yyyy-MM-dd HH:mm）」，日期解析失败则整段视为标题。
    static func parseOPMLText(_ raw: String, formatter: DateFormatter) -> (title: String, status: ItemStatus, dueDate: Date?) {
        var text = raw
        var status = ItemStatus.active
        for (prefix, value) in [("[已完成] ", ItemStatus.completed), ("[已放弃] ", ItemStatus.dropped)] {
            if text.hasPrefix(prefix) {
                status = value
                text.removeFirst(prefix.count)
                break
            }
        }
        var due: Date?
        if text.hasSuffix("）"), let start = text.range(of: "（截止 ", options: .backwards) {
            let dateText = String(text[start.upperBound...].dropLast())
            if let parsed = parseDate(dateText, formatter: formatter) {
                due = parsed
                text = String(text[..<start.lowerBound])
            }
        }
        return (text, status, due)
    }
}

/// OPML 解析委托：body 内顶层 outline 为项目（「收件箱」→ 收件箱容器），嵌套 outline 递归为子任务。
/// 仅在 TaskImporter.parseOPML 的调用线程内同步使用。
private final class OPMLDelegate: NSObject, XMLParserDelegate {
    private enum Node {
        case project(UUID?)  // 项目容器，nil = 收件箱
        case task(id: UUID, projectID: UUID?)
    }

    var data = ImportedData()
    var errorText: String?

    private let formatter: DateFormatter
    private var stack: [Node] = []
    private var projectIDByName: [String: UUID] = [:]
    private var inBody = false

    init(formatter: DateFormatter) {
        self.formatter = formatter
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        switch elementName {
        case "body":
            inBody = true
        case "outline" where inBody:
            let raw = attributeDict["text"] ?? ""
            // body 直接子级是项目；项目之下为顶层任务，任务之下递归为子任务
            let parentID: UUID?
            let projectID: UUID?
            switch stack.last {
            case nil:
                stack.append(containerNode(forProjectNamed: raw))
                return
            case .project(let pid):
                (parentID, projectID) = (nil, pid)
            case .task(let pid, let proj):
                (parentID, projectID) = (pid, proj)
            }
            let parsed = TaskImporter.parseOPMLText(raw, formatter: formatter)
            let task = TaskItem(
                title: parsed.title,
                projectID: projectID,
                parentID: parentID,
                status: parsed.status,
                dueDate: parsed.dueDate
            )
            data.tasks.append(task)
            stack.append(.task(id: task.id, projectID: projectID))
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "outline": if inBody, !stack.isEmpty { stack.removeLast() }
        case "body": inBody = false
        default: break
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        errorText = parseError.localizedDescription
    }

    /// 顶层 outline → 项目节点；同批同名项目沿用首个（与现有库的合并由 importData 处理）
    private func containerNode(forProjectNamed name: String) -> Node {
        if name == TaskImporter.inboxName { return .project(nil) }
        if let id = projectIDByName[name] { return .project(id) }
        let project = ProjectItem(name: name)
        projectIDByName[name] = project.id
        data.projects.append(project)
        return .project(project.id)
    }
}
