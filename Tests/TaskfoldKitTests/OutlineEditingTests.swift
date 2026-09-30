import Foundation
import Testing
@testable import TaskfoldKit

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

    @Test func indentSupportsMultipleLevels() throws {
        _ = try store.addTask(title: "A")
        let b = try store.addTask(title: "B")
        let c = try store.addTask(title: "C")
        let d = try store.addTask(title: "D")

        #expect(try store.indentTask(c.id) == true)  // C → B 下
        #expect(try store.indentTask(d.id) == true)  // D → B 下
        #expect(try store.indentTask(d.id) == true)  // D → C 下（第三层）

        let cAfter = try store.task(id: c.id)!
        let dAfter = try store.task(id: d.id)!
        #expect(cAfter.parentID == b.id)
        #expect(dAfter.parentID == c.id, "D 应可缩进为 C 的子任务（多层嵌套）")

        let tree = try store.subtasksTree(includeCompleted: true)
        #expect(titles(tree[b.id] ?? []) == ["C"])
        #expect(titles(tree[c.id] ?? []) == ["D"])
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

    /// 中间层提升：C 从 B 下提升到 B 的父（A）下，且自己的子树（D）跟随
    @Test func outdentMiddleLevelPromotesExactlyOneLevel() throws {
        let a = try store.addTask(title: "A")
        let b = try store.addTask(title: "B")
        try store.indentTask(b.id)                       // B → A 下
        let c = try store.addTask(title: "C", parentID: b.id)
        let d = try store.addTask(title: "D", parentID: c.id)
        // 结构：A → B → C → D（四层）

        #expect(try store.outdentTask(c.id) == true)

        let cAfter = try store.task(id: c.id)!
        let dAfter = try store.task(id: d.id)!
        let bAfter = try store.task(id: b.id)!
        #expect(cAfter.parentID == a.id, "C 应提升一级到 A 下（而非直接到顶层）")
        #expect(cAfter.sortIndex == bAfter.sortIndex + 1, "C 插到原父 B 的紧后面")
        #expect(dAfter.parentID == c.id, "C 的子树 D 应跟随移动")
        #expect(try store.task(id: a.id)!.parentID == nil)
    }

    @Test func outdentTopLevelFails() throws {
        let a = try store.addTask(title: "A")
        #expect(try store.outdentTask(a.id) == false)
    }

    /// 缩进带子树的任务：子树经 parentID 链自动跟随
    @Test func indentBringsSubtreeAlong() throws {
        let a = try store.addTask(title: "A")
        let b = try store.addTask(title: "B")
        try store.addTask(title: "B1", parentID: b.id)
        _ = try store.addTask(title: "C")
        try store.indentTask(b.id)   // B（带 B1）→ A 下

        let bAfter = try store.task(id: b.id)!
        #expect(bAfter.parentID == a.id, "B 应挂到前一个兄弟 A 下")
        let tree = try store.subtasksTree(includeCompleted: true)
        #expect(titles(tree[a.id] ?? []) == ["B"])
        #expect(titles(tree[b.id] ?? []) == ["B1"], "B 的子任务 B1 应保持挂接")
        #expect(try store.inboxTasks(includeCompleted: true).map(\.title) == ["A", "C"])
    }

    // MARK: 递归删除与级联（多层）

    private func makeFourLevelChain() throws -> (UUID, UUID, UUID, UUID) {
        let a = try store.addTask(title: "A")
        let b = try store.addTask(title: "B")
        try store.indentTask(b.id)
        let c = try store.addTask(title: "C", parentID: b.id)
        let d = try store.addTask(title: "D", parentID: c.id)
        return (a.id, b.id, c.id, d.id)
    }

    @Test func deepDeleteRemovesAllDescendants() throws {
        let (a, b, c, d) = try makeFourLevelChain()

        try store.deleteTask(b)
        for id in [b, c, d] {
            #expect(try store.task(id: id) == nil, "后代应递归删除")
        }
        #expect(try store.task(id: a) != nil, "祖先不受影响")
    }

    @Test func statusCascadesToGrandchildren() throws {
        let (_, b, c, d) = try makeFourLevelChain()

        try store.setTaskStatus(b, .completed)
        for id in [b, c, d] {
            #expect(try store.task(id: id)?.status == .completed, "完成父任务应级联到全部后代")
        }

        try store.setTaskStatus(b, .active)
        for id in [b, c, d] {
            #expect(try store.task(id: id)?.status == .active, "恢复父任务应整树同步恢复")
        }
    }

    // MARK: subtasksTree

    @Test func subtasksTreeGroupsAllLevels() throws {
        let (_, _, _, _) = try makeFourLevelChain()
        _ = try store.addTask(title: "独立任务")

        let tree = try store.subtasksTree(includeCompleted: true)
        #expect(titles(tree[try store.inboxTasks(includeCompleted: true).first!.id] ?? []) == ["B"],
                "A 的直接子任务只有 B")

        let bItem = try store.subtasks(of: try store.inboxTasks(includeCompleted: true).first!.id).first!
        #expect(titles(tree[bItem.id] ?? []) == ["C"])

        let cItem = try store.subtasks(of: bItem.id).first!
        #expect(titles(tree[cItem.id] ?? []) == ["D"])

        // 完成过滤
        try store.setTaskStatus(cItem.id, .completed)
        let activeTree = try store.subtasksTree(includeCompleted: false)
        #expect(activeTree[bItem.id] == nil, "已完成的子树默认不显示")
        let fullTree = try store.subtasksTree(includeCompleted: true)
        #expect(titles(fullTree[bItem.id] ?? []) == ["C"])
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

    // MARK: 完成子任务不影响父任务（bug 报告回归测试）

    @Test func completingSubtaskNeverTouchesParent() throws {
        let parent = try store.addTask(title: "父任务")
        let child = try store.addTask(title: "子任务", parentID: parent.id)
        try store.addTask(title: "孙任务", parentID: child.id)

        // 完成/放弃最深层任务，祖先链状态必须保持不变
        try store.setTaskStatus(child.id, .completed)
        #expect(try store.task(id: parent.id)?.status == .active, "完成子任务绝不能改变父任务状态")

        try store.setTaskStatus(child.id, .dropped)
        #expect(try store.task(id: parent.id)?.status == .active)

        // 反向：完成父任务则整棵子树级联
        try store.setTaskStatus(parent.id, .completed)
        #expect(try store.task(id: child.id)?.status == .completed)
    }

    @Test func updateTaskOnlyTouchesContentFields() throws {
        let task = try store.addTask(title: "原标题")
        try store.setTaskStatus(task.id, .completed)

        // 过期快照：status 还是 active（模拟 UI 持有旧数据），只改标题
        var stale = task
        stale.title = "新标题"
        // stale.status == .active（过期）
        try store.updateTask(stale)

        let after = try store.task(id: task.id)!
        #expect(after.title == "新标题")
        #expect(after.status == ItemStatus.completed, "内容编辑不得过期快照覆盖状态")
    }
}
