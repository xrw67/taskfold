import Foundation
import Testing
@testable import MyFocusKit

@Suite
struct TaskDropTests {
    let store: TaskStore

    init() throws {
        store = try TaskStore.inMemory()
    }

    private func titles(_ tasks: [TaskItem]) -> [String] {
        tasks.map(\.title)
    }

    // MARK: 同容器重排

    @Test func reorderBeforeAndAfterInSameContainer() throws {
        let a = try store.addTask(title: "A")
        let b = try store.addTask(title: "B")
        let c = try store.addTask(title: "C")

        // C 插到 A 前面
        #expect(try store.dropTask(c.id, relativeTo: a.id, position: .before) == true)
        #expect(titles(try store.inboxTasks(includeCompleted: true)) == ["C", "A", "B"])

        // A 插到 B 后面
        #expect(try store.dropTask(a.id, relativeTo: b.id, position: .after) == true)
        #expect(titles(try store.inboxTasks(includeCompleted: true)) == ["C", "B", "A"])
    }

    @Test func dropAtCurrentPositionIsNoOp() throws {
        _ = try store.addTask(title: "A")
        let b = try store.addTask(title: "B")
        let c = try store.addTask(title: "C")

        // C 已在 B 之后
        #expect(try store.dropTask(c.id, relativeTo: b.id, position: .after) == false)
        #expect(titles(try store.inboxTasks(includeCompleted: true)) == ["A", "B", "C"])
    }

    // MARK: 跨容器移动

    @Test func crossContainerBeforeUpdatesParentAndProject() throws {
        let project = try store.addProject(name: "P")
        _ = try store.addTask(title: "A")
        let b = try store.addTask(title: "B")
        let p1 = try store.addTask(title: "P1", projectID: project.id)
        _ = try store.addTask(title: "P2", projectID: project.id)

        // B 插到 P1 前面 → 成为项目顶层第一个
        #expect(try store.dropTask(b.id, relativeTo: p1.id, position: .before) == true)
        #expect(titles(try store.projectTasks(project.id, includeCompleted: true)) == ["B", "P1", "P2"])
        #expect(titles(try store.inboxTasks(includeCompleted: true)) == ["A"])

        let bAfter = try store.task(id: b.id)!
        #expect(bAfter.parentID == nil)
        #expect(bAfter.projectID == project.id)
    }

    @Test func crossProjectCascadesProjectIDToDescendants() throws {
        let project = try store.addProject(name: "P")
        let a = try store.addTask(title: "A")
        let a1 = try store.addTask(title: "A1", parentID: a.id)
        let a2 = try store.addTask(title: "A2", parentID: a1.id)
        let target = try store.addTask(title: "T", projectID: project.id)

        _ = try store.dropTask(a.id, relativeTo: target.id, position: .after)

        #expect(try store.task(id: a1.id)!.projectID == project.id, "子任务 projectID 应级联")
        #expect(try store.task(id: a2.id)!.projectID == project.id, "孙任务 projectID 应级联")
    }

    // MARK: 成为子任务

    @Test func intoAppendsAsLastChildWithSubtreeFollowing() throws {
        let x = try store.addTask(title: "X")
        _ = try store.addTask(title: "X1", parentID: x.id)
        let y = try store.addTask(title: "Y")
        let y1 = try store.addTask(title: "Y1", parentID: y.id)

        _ = try store.dropTask(y.id, relativeTo: x.id, position: .into)

        #expect(titles(try store.subtasks(of: x.id)) == ["X1", "Y"], "应追加为末位子任务")
        #expect(try store.task(id: y.id)!.parentID == x.id)
        #expect(try store.task(id: y1.id)!.parentID == y.id, "子树应跟随（Y1 仍是 Y 的子任务）")
        #expect(titles(try store.subtasks(of: y.id)) == ["Y1"])
    }

    // MARK: 非法落点

    @Test func dropIntoOwnSubtreeRejected() throws {
        let p = try store.addTask(title: "P")
        let c = try store.addTask(title: "C", parentID: p.id)
        let before = try store.inboxTasks(includeCompleted: true).map(\.id)

        #expect(try store.dropTask(p.id, relativeTo: c.id, position: .before) == false)
        #expect(try store.dropTask(p.id, relativeTo: c.id, position: .after) == false)
        #expect(try store.dropTask(p.id, relativeTo: c.id, position: .into) == false)

        #expect(try store.task(id: p.id)!.parentID == nil)
        #expect(titles(try store.subtasks(of: p.id)) == ["C"])
        #expect(try store.inboxTasks(includeCompleted: true).map(\.id) == before)
    }
}
