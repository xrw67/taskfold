import SwiftUI
import MyFocusKit

/// 侧边栏当前区域
enum FocusSection: Hashable {
    case inbox
    case today
    case project(UUID)

    var title: String {
        switch self {
        case .inbox: "收件箱"
        case .today: "今天"
        case .project: "项目"
        }
    }
}

@MainActor @Observable
final class AppState {
    let store: TaskStore

    // MARK: 视图状态

    var section: FocusSection = .inbox
    var selectedTaskID: UUID?
    var editingTaskID: UUID?
    var expandedParents: Set<UUID> = []
    var showInspector = true
    var showCompleted = false
    var searchText = ""
    var lastError: String?

    // MARK: 展示数据（每次变更后整体刷新）

    private(set) var projects: [ProjectItem] = []
    private(set) var inboxTasks: [TaskItem] = []
    private(set) var todaySections: [TodaySection: [TaskItem]] = [:]
    private(set) var projectTasks: [UUID: [TaskItem]] = [:]
    private(set) var subtasks: [UUID: [TaskItem]] = [:]
    private(set) var searchResults: [TaskItem] = []
    private(set) var selectedTask: TaskItem?
    var inboxBadge = 0
    var todayBadge = (overdue: 0, today: 0, next7Days: 0)
    var projectBadges: [UUID: (remaining: Int, overdue: Int)] = [:]

    init(store: TaskStore) {
        self.store = store
        reload()
    }

    var currentProject: ProjectItem? {
        if case let .project(id) = section {
            return projects.first { $0.id == id }
        }
        return nil
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: 刷新

    /// 选中项变化时仅刷新选中任务（轻量）
    func refreshSelected() {
        guard let id = selectedTaskID else {
            selectedTask = nil
            return
        }
        selectedTask = try? store.task(id: id)
    }

    func reload() {
        do {
            let now = Date()
            let cal = Calendar.current

            projects = try store.projects()
            inboxTasks = try store.inboxTasks(includeCompleted: showCompleted)

            var sections: [TodaySection: [TaskItem]] = [:]
            for task in try store.tasksDueWithin7Days(now: now, calendar: cal) {
                for s in TodaySection.allCases where s.contains(task, now: now, calendar: cal) {
                    sections[s, default: []].append(task)
                }
            }
            todaySections = sections

            var topByProject: [UUID: [TaskItem]] = [:]
            var subs: [UUID: [TaskItem]] = [:]
            for project in projects {
                let tops = try store.projectTasks(project.id, includeCompleted: showCompleted)
                topByProject[project.id] = tops
                for t in tops {
                    subs[t.id] = try store.subtasks(of: t.id, includeCompleted: showCompleted)
                }
            }
            for t in inboxTasks {
                subs[t.id] = try store.subtasks(of: t.id, includeCompleted: showCompleted)
            }
            projectTasks = topByProject
            subtasks = subs

            inboxBadge = try store.inboxCount()
            todayBadge = try store.todayBadgeCounts(now: now, calendar: cal)
            projectBadges = try store.projectBadgeCounts(now: now)

            searchResults = isSearching
                ? try store.searchTasks(matching: searchText, includeCompleted: showCompleted)
                : []

            if let id = selectedTaskID {
                selectedTask = try store.task(id: id)
                if selectedTask == nil { selectedTaskID = nil }
            } else {
                selectedTask = nil
            }
            lastError = nil
        } catch {
            lastError = "数据加载失败：\(error.localizedDescription)"
        }
    }

    // MARK: 任务操作

    /// 在当前区域新建任务：项目页建到项目、今天页默认今天 17:00 截止、收件箱页进收件箱
    @discardableResult
    func newTask() -> UUID? {
        do {
            let due: Date? = {
                guard case .today = section else { return nil }
                let cal = Calendar.current
                return cal.date(bySettingHour: 17, minute: 0, second: 0, of: Date())
            }()
            let projectID = currentProject?.id
            let task = try store.addTask(title: "新任务", projectID: projectID, dueDate: due)
            reload()
            selectedTaskID = task.id
            editingTaskID = task.id
            return task.id
        } catch {
            lastError = "新建任务失败：\(error.localizedDescription)"
            return nil
        }
    }

    func addSubtask(to parent: TaskItem) {
        do {
            let child = try store.addTask(title: "新子任务", projectID: parent.projectID, parentID: parent.id)
            expandedParents.insert(parent.id)
            reload()
            selectedTaskID = child.id
            editingTaskID = child.id
        } catch {
            lastError = "新建子任务失败：\(error.localizedDescription)"
        }
    }

    /// 行内改名；提交空标题时删除该任务
    func commitTitle(_ task: TaskItem, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            delete(task)
        } else if trimmed != task.title {
            var t = task
            t.title = trimmed
            update(t)
        }
        editingTaskID = nil
    }

    func toggleComplete(_ task: TaskItem) {
        setStatus(task, to: task.status == .active ? .completed : .active)
    }

    func setStatus(_ task: TaskItem, to status: ItemStatus) {
        do {
            try store.setTaskStatus(task.id, status)
            reload()
        } catch {
            lastError = "更新状态失败：\(error.localizedDescription)"
        }
    }

    func update(_ task: TaskItem) {
        do {
            try store.updateTask(task)
            reload()
        } catch {
            lastError = "更新任务失败：\(error.localizedDescription)"
        }
    }

    func delete(_ task: TaskItem) {
        do {
            try store.deleteTask(task.id)
            if selectedTaskID == task.id { selectedTaskID = nil }
            editingTaskID = nil
            reload()
        } catch {
            lastError = "删除任务失败：\(error.localizedDescription)"
        }
    }

    func assign(_ task: TaskItem, to projectID: UUID?) {
        do {
            try store.setTaskProject(task.id, projectID: projectID)
            reload()
        } catch {
            lastError = "移动任务失败：\(error.localizedDescription)"
        }
    }

    func setDue(_ task: TaskItem, to date: Date?) {
        var t = task
        t.dueDate = date
        update(t)
    }

    // MARK: 项目操作

    func newProject(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            let p = try store.addProject(name: trimmed)
            reload()
            section = .project(p.id)
        } catch {
            lastError = "新建项目失败：\(error.localizedDescription)"
        }
    }

    func update(_ project: ProjectItem) {
        do {
            try store.updateProject(project)
            reload()
        } catch {
            lastError = "更新项目失败：\(error.localizedDescription)"
        }
    }

    func setProjectStatus(_ project: ProjectItem, to status: ItemStatus) {
        do {
            try store.setProjectStatus(project.id, status)
            reload()
        } catch {
            lastError = "更新项目状态失败：\(error.localizedDescription)"
        }
    }

    func delete(_ project: ProjectItem) {
        do {
            try store.deleteProject(project.id)
            if case .project(project.id) = section { section = .inbox }
            selectedTaskID = nil
            reload()
        } catch {
            lastError = "删除项目失败：\(error.localizedDescription)"
        }
    }
}
