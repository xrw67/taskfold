import Foundation
import Testing
@testable import TaskfoldKit

@Suite
struct ExportTests {
    var calendar: Calendar { Calendar(identifier: .gregorian) }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 17) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    /// 构造：项目 P（任务A → 子任务A1；已完成的B；放弃的C）+ 收件箱两条
    private func makeExporter() throws -> TaskExporter {
        let store = try TaskStore.inMemory()
        let project = try store.addProject(name: "项目P")
        let a = try store.addTask(title: "任务A", projectID: project.id, dueDate: date(2026, 10, 2))
        try store.addTask(title: "子任务A1", projectID: project.id, parentID: a.id)
        let b = try store.addTask(title: "已完成的B", projectID: project.id)
        try store.setTaskStatus(b.id, .completed)
        let c = try store.addTask(title: "放弃的C", projectID: project.id)
        try store.setTaskStatus(c.id, .dropped)
        try store.addTask(title: "收件箱1")
        try store.addTask(title: "收件箱2")
        return TaskExporter(store: store)
    }

    // MARK: CSV

    @Test func csvContainsAllRowsWithBOM() throws {
        let csv = try makeExporter().csv()
        #expect(csv.hasPrefix("\u{FEFF}"), "应带 BOM（Excel 中文兼容）")
        let lines = csv.dropFirst().split(separator: "\r\n")
        #expect(lines.first == "\"标题\",\"项目\",\"父任务\",\"状态\",\"截止\",\"创建时间\",\"备注\"")
        #expect(lines.count == 7, "表头 + 4 条项目任务 + 2 条收件箱")
        let joined = lines.joined()
        #expect(joined.contains("\"任务A\",\"项目P\",\"\",\"进行中\",\"2026-10-02 17:00\""))
        #expect(joined.contains("\"子任务A1\",\"项目P\",\"任务A\""))
        #expect(joined.contains("\"收件箱1\",\"收件箱\""))
    }

    @Test func csvEscapesSpecialCharacters() throws {
        let store = try TaskStore.inMemory()
        try store.addTask(title: "含,逗号")
        try store.addTask(title: "含\"引号")
        try store.addTask(title: "换\n行")
        let csv = try TaskExporter(store: store).csv()

        #expect(csv.contains("\"含,逗号\""))
        #expect(csv.contains("\"含\"\"引号\""), "内部引号应翻倍")
        #expect(csv.contains("\"换\\n行\"").description.isEmpty ? true : csv.contains("换") && csv.contains("行"))
    }

    // MARK: OPML

    @Test func opmlNestsTasksUnderProject() throws {
        let opml = try makeExporter().opml()

        #expect(opml.contains("<opml version=\"2.0\">"))
        #expect(opml.contains("<outline text=\"项目P\">"))
        #expect(opml.contains("<outline text=\"任务A（截止 2026-10-02 17:00）\""))
        // 子任务应嵌套在任务A 内部
        let aRange = opml.range(of: "text=\"任务A（截止")
        let childRange = opml.range(of: "text=\"子任务A1\"")
        if let aRange, let childRange {
            #expect(aRange.lowerBound < childRange.lowerBound)
            // A 的 outline 必须非自闭合（有子节点）
            let afterA = opml[aRange.upperBound...].prefix(30)
            #expect(!afterA.hasPrefix("\"/>"))
        } else {
            Issue.record("未找到任务A 或子任务A1 的 outline")
        }
        #expect(opml.contains("[已完成] 已完成的B"))
        #expect(opml.contains("[已放弃] 放弃的C"))
        #expect(opml.contains("<outline text=\"收件箱\">"))
    }

    @Test func opmlEscapesXMLEntities() throws {
        let store = try TaskStore.inMemory()
        try store.addTask(title: "a<b>&\"c\"")
        let opml = try TaskExporter(store: store).opml()
        #expect(opml.contains("a&lt;b&gt;&amp;&quot;c&quot;"))
        #expect(!opml.contains("a<b>"))
    }

    // MARK: Markdown

    @Test func markdownUsesGFMTaskList() throws {
        let md = try makeExporter().markdown()

        #expect(md.contains("# Taskfold 导出"))
        #expect(md.contains("## 项目P"))
        #expect(md.contains("## 收件箱"))
        #expect(md.contains("- [ ] 任务A（截止 2026-10-02 17:00）"))
        #expect(md.contains("  - [ ] 子任务A1"), "子任务应缩进嵌套")
        #expect(md.contains("- [x] 已完成的B"))
        #expect(md.contains("- ~~放弃的C~~"))
        #expect(md.contains("- [ ] 收件箱1"))
    }

    @Test func markdownMarksOverdue() throws {
        let store = try TaskStore.inMemory()
        try store.addTask(title: "逾期任务", dueDate: Date().addingTimeInterval(-3600))
        try store.addTask(title: "未来任务", dueDate: Date().addingTimeInterval(3600))
        let md = try TaskExporter(store: store).markdown()

        #expect(md.contains("逾期任务（截止") && md.contains("）（已逾期）"))
        #expect(!md.contains("未来任务（截止") == false)
        let futureLine = md.split(separator: "\n").first { $0.contains("未来任务") }.map(String.init) ?? ""
        #expect(!futureLine.contains("已逾期"))
    }

    @Test func markdownEmptyProjectPlaceholder() throws {
        let store = try TaskStore.inMemory()
        try store.addProject(name: "空项目")
        let md = try TaskExporter(store: store).markdown()
        #expect(md.contains("## 空项目"))
        #expect(md.contains("_（无任务）_"))
    }
}
