import Foundation
import Testing
@testable import MyFocusKit

@Suite
struct OutlineEditingTests {
    let store: TaskStore
    var calendar: Calendar { Calendar(identifier: .gregorian) }

    init() throws {
        store = try TaskStore.inMemory()
    }

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private func titles(_ tasks: [TaskItem]) -> [String] {
        tasks.map(\.title)
    }

    // MARK: Tab 缩进

    @Test func indentMakesPreviousSiblingParent() throws {
        _ = try store.addTask(title: "A")
        let b = try store.addTask(title: "B")
        let c = try store.addTask(title: "C")

        #expect(try store.indentTask(c.id) == true)
        let cAfter = try store.task(id: c.id)!
        #expect(cAfter.parentID == b.id, "C 应缩进为紧邻上一行 B 的子任务")
        #expect(try store.subtasks(of: b.id).map(\.title) == ["C"])
        #expect(titles(try store.inboxTasks(includeCompleted: true)) == ["A", "B"])
    }

    @Test func indentFirstSiblingFails() throws {
        let a = try store.addTask(title: "A")
        #expect(try store.indentTask(a.id) == false, "第一个兄弟没有前置兄弟，不可缩进")
    }

    @Test func indentSubtaskFailsInV1() throws {
        _ = try store.addTask(title: "A")
        _ = try store.addTask(title: "B")
        let c = try store.addTask(title: "C")
        try store.indentTask(c.id)

        #expect(try store.indentTask(c.id) == false, "V1 只有一层子任务，已是子任务不可再缩进")
    }

    // MARK: ⇧Tab 提升

    @Test func outdentPromotesToTopLevelAfterParent() throws {
        _ = try store.addTask(title: "A")
        let b = try store.addTask(title: "B")
        let c = try store.addTask(title: "C")
        try store.indentTask(c.id)
        // 现在结构：A；B → [C]

        #expect(try store.outdentTask(c.id) == true)
        let cAfter = try store.task(id: c.id)!
        #expect(cAfter.parentID == nil)
        let top = try store.inboxTasks(includeCompleted: true)
        #expect(titles(top) == ["A", "B", "C"], "C 应提升到父任务 B 的紧后面")
        #expect(try store.subtasks(of: b.id, includeCompleted: true).isEmpty)
    }

    @Test func outdentTopLevelFails() throws {
        let a = try store.addTask(title: "A")
        #expect(try store.outdentTask(a.id) == false)
    }

    // MARK: ⌥↑/⌥↓ 移动

    @Test func moveTaskDownSwapsWithNextSibling() throws {
        _ = try store.addTask(title: "A")
        let b = try store.addTask(title: "B")
        _ = try store.addTask(title: "C")

        #expect(try store.moveTask(b.id, offset: 1) == true)
        #expect(titles(try store.inboxTasks(includeCompleted: true)) == ["A", "C", "B"])

        #expect(try store.moveTask(b.id, offset: 1) == false, "已在末尾，不能再下移")
        #expect(titles(try store.inboxTasks(includeCompleted: true)) == ["A", "C", "B"])
    }

    @Test func moveTaskUpSwapsWithPreviousSibling() throws {
        _ = try store.addTask(title: "A")
        let b = try store.addTask(title: "B")
        _ = try store.addTask(title: "C")

        #expect(try store.moveTask(b.id, offset: -1) == true)
        #expect(titles(try store.inboxTasks(includeCompleted: true)) == ["B", "A", "C"])
    }

    @Test func moveWithinParentOnlyAffectsSubtasks() throws {
        _ = try store.addTask(title: "A")
        let b = try store.addTask(title: "B")
        let c = try store.addTask(title: "C")
        try store.indentTask(c.id)
        let d = try store.addTask(title: "D")
        try store.indentTask(d.id)
        // 结构：A；B → [C, D]（D 的前一个顶层兄弟是 B）

        #expect(try store.moveTask(d.id, offset: -1) == true)
        #expect(titles(try store.subtasks(of: b.id)) == ["D", "C"])
        #expect(titles(try store.inboxTasks(includeCompleted: true)) == ["A", "B"])
    }

    // MARK: 回车续行

    @Test func insertTaskAfterShiftsFollowingSiblings() throws {
        _ = try store.addTask(title: "A")
        let b = try store.addTask(title: "B")
        _ = try store.addTask(title: "C")

        let inserted = try store.insertTask(after: b.id, title: "B2")
        #expect(inserted != nil)
        #expect(titles(try store.inboxTasks(includeCompleted: true)) == ["A", "B", "B2", "C"])
    }

    @Test func insertAfterSubtaskKeepsParent() throws {
        _ = try store.addTask(title: "A")
        let b = try store.addTask(title: "B")
        let c = try store.addTask(title: "C")
        try store.indentTask(c.id)
        // C 现在是 B 的子任务

        let inserted = try store.insertTask(after: c.id, title: "C2")
        #expect(inserted?.parentID == b.id)
        #expect(inserted?.projectID == nil)
        #expect(titles(try store.subtasks(of: b.id)) == ["C", "C2"])
    }

    @Test func insertAfterInheritsProject() throws {
        let project = try store.addProject(name: "P")
        let a = try store.addTask(title: "A", projectID: project.id)
        let inserted = try store.insertTask(after: a.id, title: "A2")
        #expect(inserted?.projectID == project.id)
    }

    // MARK: 首启示例数据

    @Test func seedOnlyWhenEmpty() throws {
        #expect(try store.seedSampleDataIfEmpty(now: date(2026, 9, 28, 10)) == true)
        #expect(try store.projects().count == 1)
        #expect(try store.inboxCount() == 2)
        #expect(try store.inboxTasks().allSatisfy { !$0.title.isEmpty })

        // 已有数据时不再写入
        #expect(try store.seedSampleDataIfEmpty(now: date(2026, 9, 28, 10)) == false)
        #expect(try store.projects().count == 1)
    }
}
