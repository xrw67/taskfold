import Foundation
import Testing
@testable import TaskfoldKit

@Suite
struct ImportTests {
    var calendar: Calendar { Calendar(identifier: .gregorian) }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 17) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private let csvHeader = "\"标题\",\"项目\",\"父任务\",\"状态\",\"截止\",\"创建时间\",\"备注\""

    /// 按 TaskExporter 的规则拼一行 CSV
    private func csvLine(_ fields: [String]) -> String {
        fields.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
    }

    // MARK: CSV 解析

    @Test func csvParsesQuotesAndCommas() throws {
        let csv = [
            csvHeader,
            csvLine(["含\"引号", "收件箱", "", "进行中", "", "2026-09-30 10:00", "含,逗号"]),
        ].joined(separator: "\r\n")

        let data = try TaskImporter.parseCSV(csv)
        #expect(data.tasks.count == 1)
        #expect(data.tasks[0].title == "含\"引号", "内部引号翻倍应还原")
        #expect(data.tasks[0].note == "含,逗号", "引号内逗号不应拆列")
        #expect(data.tasks[0].projectID == nil)
    }

    @Test func csvMapsStatusAndDates() throws {
        let csv = [
            csvHeader,
            csvLine(["B", "项目P", "", "已完成", "2026-10-02 17:00", "2026-09-30 10:00", "备注"]),
            csvLine(["C", "收件箱", "", "已放弃", "坏日期", "", ""]),
            csvLine(["D", "", "", "未知状态", "", "", ""]),
        ].joined(separator: "\r\n")

        let data = try TaskImporter.parseCSV(csv)
        #expect(data.tasks[0].status == .completed)
        #expect(data.tasks[0].dueDate == date(2026, 10, 2))
        #expect(data.tasks[0].note == "备注")
        #expect(data.tasks[0].createdAt == date(2026, 9, 30, 10))
        #expect(data.tasks[1].status == .dropped && data.tasks[1].dueDate == nil && data.tasks[1].projectID == nil,
                "「收件箱」与坏日期应宽松处理")
        #expect(data.tasks[2].status == .active, "未知状态宽松按进行中")
        #expect(data.projects.map(\.name) == ["项目P"])
    }

    @Test func csvResolvesParentByTitlePreferringLatest() throws {
        let csv = [
            csvHeader,
            csvLine(["任务A", "项目P", "", "进行中", "", "2026-09-30 10:00", ""]),
            csvLine(["子A1", "项目P", "任务A", "进行中", "", "2026-09-30 10:00", ""]),
            csvLine(["任务A", "项目P", "", "进行中", "", "2026-09-30 10:00", ""]),
            csvLine(["子A2", "项目P", "任务A", "进行中", "", "2026-09-30 10:00", ""]),
        ].joined(separator: "\r\n")

        let data = try TaskImporter.parseCSV(csv)
        #expect(data.tasks[1].parentID == data.tasks[0].id)
        #expect(data.tasks[3].parentID == data.tasks[2].id, "同名标题应取最近出现的父任务")
        #expect(data.projects.count == 1, "同批同名项目只建一个")
    }

    @Test func csvMissingParentFallsBackToTopLevel() throws {
        let csv = [
            csvHeader,
            csvLine(["孤儿", "项目P", "不存在的父", "进行中", "", "", ""]),
        ].joined(separator: "\r\n")

        let data = try TaskImporter.parseCSV(csv)
        #expect(data.tasks[0].parentID == nil, "父标题反查不到应置顶层")
    }

    @Test func csvRejectsBadHeader() {
        #expect(throws: ImportError.csvHeaderMismatch) {
            try TaskImporter.parseCSV("name,project,parent,status,due,created,note")
        }
    }

    @Test func csvRejectsWrongColumnCount() throws {
        let csv = [csvHeader, "\"只有三列\",\"a\",\"b\""].joined(separator: "\r\n")
        do {
            _ = try TaskImporter.parseCSV(csv)
            Issue.record("列数不符应抛错")
        } catch let error as ImportError {
            guard case .csvRowColumns(2) = error else {
                Issue.record("应为第 2 行列数错误：\(error)")
                return
            }
        }
    }

    @Test func csvRejectsEmptyAndHeaderOnly() {
        #expect(throws: ImportError.emptyContent) { try TaskImporter.parseCSV("") }
        #expect(throws: ImportError.noData) { try TaskImporter.parseCSV(csvHeader) }
    }

    // MARK: OPML 解析

    @Test func opmlParsesNestingAndAttributes() throws {
        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head><title>测试</title></head>
          <body>
            <outline text="项目P">
              <outline text="[已完成] B（截止 2026-10-02 17:00）"/>
              <outline text="任务A">
                <outline text="子任务A1"/>
              </outline>
            </outline>
            <outline text="收件箱">
              <outline text="收件箱1"/>
            </outline>
            <outline text="空项目"/>
          </body>
        </opml>
        """

        let data = try TaskImporter.parseOPML(opml)
        #expect(data.projects.map(\.name) == ["项目P", "空项目"], "「收件箱」是容器不建项目")
        #expect(data.tasks.count == 4)

        let b = data.tasks[0]
        #expect(b.title == "B" && b.status == .completed)
        #expect(b.dueDate == date(2026, 10, 2))
        #expect(b.projectID == data.projects[0].id)

        let a = data.tasks[1]
        #expect(a.title == "任务A" && a.parentID == nil)
        let a1 = data.tasks[2]
        #expect(a1.title == "子任务A1" && a1.parentID == a.id, "嵌套 outline 应为子任务")

        let inbox1 = data.tasks[3]
        #expect(inbox1.title == "收件箱1" && inbox1.projectID == nil && inbox1.parentID == nil)
    }

    @Test func opmlParsesEntities() throws {
        let opml = """
        <opml version="2.0"><body><outline text="P"><outline text="a&lt;b&gt;&amp;&#34;c&#34;"/></outline></body></opml>
        """
        let data = try TaskImporter.parseOPML(opml)
        #expect(data.projects[0].name == "P")
        #expect(data.tasks[0].title == "a<b>&\"c\"", "XML 实体应还原")
    }

    @Test func opmlRejectsBrokenAndEmpty() throws {
        let broken = "<opml version=\"2.0\"><body><outline text=\"a\"></body></opml>"
        do {
            _ = try TaskImporter.parseOPML(broken)
            Issue.record("坏 XML 应抛错")
        } catch let error as ImportError {
            guard case .xmlParseFailed = error else {
                Issue.record("应为 xmlParseFailed：\(error)")
                return
            }
        }

        #expect(throws: ImportError.emptyContent) { try TaskImporter.parseOPML("") }
        #expect(throws: ImportError.noData) {
            try TaskImporter.parseOPML("<opml version=\"2.0\"><head></head><body></body></opml>")
        }
    }

    // MARK: importData 落库

    @Test func importMergesSameNameProject() throws {
        let store = try TaskStore.inMemory()
        let existing = try store.addProject(name: "项目P")
        _ = try store.addTask(title: "已有任务", projectID: existing.id)

        var data = ImportedData()
        let imported = ProjectItem(name: "项目P")
        data.projects = [imported]
        data.tasks = [TaskItem(title: "导入任务", projectID: imported.id)]

        let result = try store.importData(data)
        #expect(result.importedProjects == 0, "同名项目并入现有，不新建")
        #expect(result.importedTasks == 1)

        #expect(try store.projects().count == 1)
        let titles = try store.projectTasks(existing.id, includeCompleted: true).map(\.title)
        #expect(titles == ["已有任务", "导入任务"], "sortIndex 追加到现有之后")
    }

    @Test func importAppendsAfterExistingSortIndex() throws {
        let store = try TaskStore.inMemory()
        _ = try store.addTask(title: "旧1")
        _ = try store.addTask(title: "旧2")

        var data = ImportedData()
        data.tasks = [TaskItem(title: "新1"), TaskItem(title: "新2")]
        _ = try store.importData(data)

        let titles = try store.inboxTasks(includeCompleted: true).map(\.title)
        #expect(titles == ["旧1", "旧2", "新1", "新2"])
    }

    // MARK: 导出 → 导入 roundtrip

    /// 项目 P（任务A → A1 → A11；已完成B；放弃C）+ 收件箱 2 条（1 条有截止）
    private func makeSampleStore() throws -> TaskStore {
        let store = try TaskStore.inMemory()
        let project = try store.addProject(name: "项目P")
        let a = try store.addTask(title: "任务A", projectID: project.id, dueDate: date(2026, 10, 2))
        let a1 = try store.addTask(title: "子任务A1", projectID: project.id, parentID: a.id)
        try store.addTask(title: "孙任务A11", projectID: project.id, parentID: a1.id)
        let b = try store.addTask(title: "已完成的B", projectID: project.id)
        try store.setTaskStatus(b.id, .completed)
        let c = try store.addTask(title: "放弃的C", projectID: project.id)
        try store.setTaskStatus(c.id, .dropped)
        try store.addTask(title: "收件箱1", dueDate: date(2026, 10, 5))
        try store.addTask(title: "收件箱2")
        return store
    }

    /// 展平后的任务快照（收件箱在前、各项目按顺序），用于跨库结构比对。
    /// 日期统一取整到分钟（CSV/OPML 格式只保留到分钟）；createdAt 可选纳入（OPML 不导出）。
    private struct Flat: Equatable {
        var title: String
        var status: ItemStatus
        var dueDate: Date?
        var createdAt: Date?
        var depth: Int
        var projectName: String?
    }

    private func flatten(_ store: TaskStore, includeCreatedAt: Bool) throws -> [Flat] {
        let projects = try store.projects()
        let subtasks = try store.subtasksTree(includeCompleted: true)
        var result: [Flat] = []
        func walk(_ task: TaskItem, depth: Int, projectName: String?) {
            result.append(Flat(
                title: task.title,
                status: task.status,
                dueDate: Self.floorToMinute(task.dueDate),
                createdAt: includeCreatedAt ? Self.floorToMinute(task.createdAt) : nil,
                depth: depth,
                projectName: projectName
            ))
            for child in subtasks[task.id] ?? [] { walk(child, depth: depth + 1, projectName: projectName) }
        }
        for task in try store.inboxTasks(includeCompleted: true) { walk(task, depth: 0, projectName: nil) }
        for project in projects {
            for task in try store.projectTasks(project.id, includeCompleted: true) {
                walk(task, depth: 0, projectName: project.name)
            }
        }
        return result
    }

    private static func floorToMinute(_ date: Date?) -> Date? {
        date.map { Date(timeIntervalSince1970: floor($0.timeIntervalSince1970 / 60) * 60) }
    }

    @Test func csvRoundtripRestoresEverything() throws {
        let source = try makeSampleStore()
        let csv = try TaskExporter(store: source).csv()

        let target = try TaskStore.inMemory()
        let result = try target.importData(try TaskImporter.parseCSV(csv))
        #expect(result.importedProjects == 1 && result.importedTasks == 7)

        #expect(try flatten(source, includeCreatedAt: true) == flatten(target, includeCreatedAt: true),
                "CSV roundtrip 应完整还原状态/截止/创建时间与层级归属")
    }

    @Test func opmlRoundtripRestoresStructure() throws {
        let source = try makeSampleStore()
        let opml = try TaskExporter(store: source).opml()

        let target = try TaskStore.inMemory()
        let result = try target.importData(try TaskImporter.parseOPML(opml))
        #expect(result.importedProjects == 1 && result.importedTasks == 7)

        #expect(try flatten(source, includeCreatedAt: false) == flatten(target, includeCreatedAt: false),
                "OPML roundtrip 应还原层级/状态/截止（OPML 不含备注与创建时间）")
    }
}
