import Foundation
import Testing
@testable import MyFocusKit

@Suite
struct StoreTests {
    let store: TaskStore
    var calendar: Calendar { Calendar(identifier: .gregorian) }

    init() throws {
        store = try TaskStore.inMemory()
    }

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    // MARK: 基础 CRUD 与持久化

    @Test func taskCRUDRoundtrip() throws {
        let created = try store.addTask(title: "写周报", dueDate: date(2026, 9, 30, 17))
        #expect(created.title == "写周报")
        #expect(created.status == .active)

        var updated = created
        updated.title = "写月报"
        try store.updateTask(updated)
        #expect(try store.inboxTasks().first?.title == "写月报")
    }

    @Test func onDiskPersistenceAcrossReopen() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("storetest-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let s1 = try TaskStore(path: url.path)
        try s1.addProject(name: "网站改版")
        try s1.addTask(title: "画首页原型")

        let s2 = try TaskStore(path: url.path)
        #expect(try s2.projects().first?.name == "网站改版")
        #expect(try s2.inboxTasks().count == 1)
    }

    // MARK: 展开状态持久化

    @Test func expandedStatePersistsAcrossReopen() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("storetest-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let s1 = try TaskStore(path: url.path)
        let parent = try s1.addTask(title: "父任务")
        _ = try s1.addTask(title: "子任务", parentID: parent.id)
        #expect(try s1.task(id: parent.id)?.isExpanded == false, "新任务默认折叠")

        try s1.setExpanded(parent.id, true)
        let s2 = try TaskStore(path: url.path)
        #expect(try s2.task(id: parent.id)?.isExpanded == true, "重开后展开状态保持")
        #expect(try s2.expandedTaskIDs() == [parent.id])

        try s2.setExpanded(parent.id, false)
        let s3 = try TaskStore(path: url.path)
        #expect(try s3.task(id: parent.id)?.isExpanded == false, "折叠后重开同样保持")
        #expect(try s3.expandedTaskIDs().isEmpty)
    }

    // MARK: 收件箱整理（INB-2）

    @Test func assignProjectMovesTaskOutOfInbox() throws {
        let project = try store.addProject(name: "网站改版")
        let task = try store.addTask(title: "画首页原型")

        #expect(try store.inboxCount() == 1)
        try store.setTaskProject(task.id, projectID: project.id)

        #expect(try store.inboxCount() == 0, "指定项目后应立即移出收件箱")
        #expect(try store.projectTasks(project.id).count == 1)
    }

    @Test func assignProjectMovesSubtasksAlong() throws {
        let project = try store.addProject(name: "网站改版")
        _ = try store.addTask(title: "A")
        let parent = try store.addTask(title: "B")
        let child = try store.addTask(title: "C")
        try store.indentTask(child.id)   // C 成为 B 的子任务

        try store.setTaskProject(parent.id, projectID: project.id)
        let movedChild = try store.task(id: child.id)!
        #expect(movedChild.projectID == project.id, "拖拽整组换项目时子任务应跟随")
        #expect(movedChild.parentID == parent.id, "父子关系保持不变")
    }

    // MARK: 项目级联（DS-4 / TP-4）

    @Test func completeProjectCascadesToTasks() throws {
        let project = try store.addProject(name: "读书计划")
        try store.addTask(title: "读第一章", projectID: project.id)
        try store.addTask(title: "读第二章", projectID: project.id)

        try store.setProjectStatus(project.id, .completed)

        let tasks = try store.projectTasks(project.id, includeCompleted: true)
        #expect(tasks.count == 2)
        #expect(tasks.allSatisfy { $0.status == .completed }, "完成项目应级联完成未完成任务")
        #expect(try store.projectTasks(project.id).count == 0, "默认视图不显示已完成")
    }

    @Test func deleteProjectMovesTasksToInbox() throws {
        let project = try store.addProject(name: "临时项目")
        let task = try store.addTask(title: "某任务", projectID: project.id)

        try store.deleteProject(project.id)

        #expect(try store.projects().isEmpty)
        let inbox = try store.inboxTasks()
        #expect(inbox.count == 1, "删除项目时任务应移回收件箱而非删除")
        #expect(inbox.first?.id == task.id)
    }

    // MARK: 子任务

    @Test func parentCompletionCascadesToSubtasks() throws {
        let parent = try store.addTask(title: "父任务")
        try store.addTask(title: "子任务1", parentID: parent.id)
        try store.addTask(title: "子任务2", parentID: parent.id)
        #expect(try store.subtasks(of: parent.id).count == 2)

        try store.setTaskStatus(parent.id, .completed)
        #expect(try store.subtasks(of: parent.id).isEmpty, "完成父任务应级联完成子任务")
        let all = try store.subtasks(of: parent.id, includeCompleted: true)
        #expect(all.allSatisfy { $0.status == .completed })
    }

    @Test func deleteParentDeletesSubtasks() throws {
        let parent = try store.addTask(title: "父任务")
        try store.addTask(title: "子任务", parentID: parent.id)

        try store.deleteTask(parent.id)
        #expect(try store.subtasks(of: parent.id, includeCompleted: true).isEmpty)
        #expect(try store.inboxTasks(includeCompleted: true).isEmpty)
    }

    // MARK: 今天视图窗口

    @Test func todayWindowQuery() throws {
        let now = date(2026, 9, 28, 12)
        let project = try store.addProject(name: "P")
        try store.addTask(title: "逾期", projectID: project.id, dueDate: date(2026, 9, 27, 17))
        try store.addTask(title: "今天", projectID: project.id, dueDate: date(2026, 9, 28, 20))
        try store.addTask(title: "三天后", projectID: project.id, dueDate: date(2026, 10, 1, 10))
        try store.addTask(title: "8天后", projectID: project.id, dueDate: date(2026, 10, 7, 10))
        try store.addTask(title: "无截止", projectID: project.id)
        let doneTask = try store.addTask(title: "已完成今天", projectID: project.id, dueDate: date(2026, 9, 28, 20))
        try store.setTaskStatus(doneTask.id, .completed)

        let candidates = try store.tasksDueWithin7Days(now: now, calendar: calendar)
        let titles = Set(candidates.map(\.title))
        #expect(titles == ["逾期", "今天", "三天后"], "窗口应含逾期/今天/7天内，排除无截止、已完成与 8 天后")

        let badges = try store.todayBadgeCounts(now: now, calendar: calendar)
        #expect(badges.overdue == 1)
        #expect(badges.today == 1)
        #expect(badges.next7Days == 1)
    }

    // MARK: 搜索

    @Test func searchByTitleAndNote() throws {
        let t1 = try store.addTask(title: "预约牙医")
        var t2 = try store.addTask(title: "普通任务")
        t2.note = "记得带牙医病历"
        try store.updateTask(t2)

        #expect(try store.searchTasks(matching: "牙医", includeCompleted: false).count == 2, "标题与备注都应命中")
        #expect(try store.searchTasks(matching: "  ", includeCompleted: false).isEmpty, "空白关键词不搜索")

        try store.setTaskStatus(t1.id, .completed)
        #expect(try store.searchTasks(matching: "预约", includeCompleted: false).isEmpty)
        #expect(try store.searchTasks(matching: "预约", includeCompleted: true).count == 1)
    }

    @Test func searchEscapesLikeWildcards() throws {
        try store.addTask(title: "100% 完成")
        try store.addTask(title: "普通任务")
        #expect(try store.searchTasks(matching: "100%", includeCompleted: false).count == 1, "% 应被转义而非当作通配符")
    }

    // MARK: 徽章

    @Test func projectBadgeCounts() throws {
        let now = date(2026, 9, 28, 12)
        let p1 = try store.addProject(name: "P1")
        let p2 = try store.addProject(name: "P2")
        try store.addTask(title: "a", projectID: p1.id, dueDate: date(2026, 9, 27, 17))
        try store.addTask(title: "b", projectID: p1.id, dueDate: date(2026, 10, 5, 17))
        try store.addTask(title: "c", projectID: p2.id)

        let counts = try store.projectBadgeCounts(now: now)
        #expect(counts[p1.id]?.remaining == 2)
        #expect(counts[p1.id]?.overdue == 1)
        #expect(counts[p2.id]?.remaining == 1)
        #expect(counts[p2.id]?.overdue == 0)
    }
}
