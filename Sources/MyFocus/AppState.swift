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
    /// ⌘F 请求聚焦搜索框：MainView 监听该值变化（菜单命令无法直接持有 FocusState）
    var searchFocusRequest = 0

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
        do {
            try store.seedSampleDataIfEmpty()
        } catch {
            lastError = "示例数据创建失败：\(error.localizedDescription)"
        }
        reload()
    }

    /// 默认截止时刻（设置可改，DS-1/DT-1）
    static let defaultDueHourKey = "defaultDueHour"
    static let defaultDueMinuteKey = "defaultDueMinute"

    func defaultDue(on date: Date, calendar: Calendar = .current) -> Date {
        let defaults = UserDefaults.standard
        let hour = defaults.object(forKey: Self.defaultDueHourKey) as? Int ?? 17
        let minute = defaults.object(forKey: Self.defaultDueMinuteKey) as? Int ?? 0
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date)
            ?? date
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

    /// 在当前区域新建任务：项目页建到项目、今天页默认今天默认时刻截止、收件箱页进收件箱
    @discardableResult
    func newTask() -> UUID? {
        do {
            let due: Date? = {
                guard case .today = section else { return nil }
                return defaultDue(on: Date())
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

    /// 行内改名；提交空标题时删除该任务；continueWithNew 时在其后新建并继续编辑（回车续行）
    func commitTitle(_ task: TaskItem, to newTitle: String, continueWithNew: Bool = false) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            delete(task)
            editingTaskID = nil
            return
        }
        if trimmed != task.title {
            var t = task
            t.title = trimmed
            update(t)
        }
        if continueWithNew {
            insertAfter(task)
        } else {
            editingTaskID = nil
        }
    }

    // MARK: 大纲编辑（TP-1）

    func indentSelected() {
        guard let task = selectedTask else { return }
        do {
            if try store.indentTask(task.id) {
                expandedParents.insert(try store.task(id: task.id)!.parentID!)
                reload()
            }
        } catch {
            lastError = "缩进失败：\(error.localizedDescription)"
        }
    }

    func outdentSelected() {
        guard let task = selectedTask else { return }
        do {
            if try store.outdentTask(task.id) { reload() }
        } catch {
            lastError = "提升失败：\(error.localizedDescription)"
        }
    }

    func moveSelected(_ offset: Int) {
        guard let task = selectedTask else { return }
        do {
            if try store.moveTask(task.id, offset: offset) { reload() }
        } catch {
            lastError = "移动失败：\(error.localizedDescription)"
        }
    }

    /// 在选中任务之后插入同级新任务并进入编辑（回车续行）
    func insertAfter(_ task: TaskItem) {
        do {
            if let new = try store.insertTask(after: task.id, title: "新任务") {
                reload()
                selectedTaskID = new.id
                editingTaskID = new.id
            }
        } catch {
            lastError = "新建任务失败：\(error.localizedDescription)"
        }
    }

    /// 大纲键盘事件（挂在大纲 List 上）。编辑中不拦截。
    func handleOutlineKey(_ press: KeyPress) -> KeyPress.Result {
        guard editingTaskID == nil, let task = selectedTask else { return .ignored }

        switch press.key {
        case .tab where press.modifiers.contains(.shift):
            outdentSelected()
            return .handled
        case .tab:
            indentSelected()
            return .handled
        case .return:
            insertAfter(task)
            return .handled
        case .downArrow where press.modifiers.contains(.option):
            moveSelected(1)
            return .handled
        case .upArrow where press.modifiers.contains(.option):
            moveSelected(-1)
            return .handled
        default:
            return .ignored
        }
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
