import SwiftUI
import AppKit
import UniformTypeIdentifiers
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
    let backupManager = BackupManager()
    private(set) var backups: [BackupEntry] = []

    // MARK: 视图状态

    var section: FocusSection = .inbox
    var selectedTaskID: UUID?
    var editingTaskID: UUID?
    var expandedParents: Set<UUID> = []
    var showInspector = true
    /// 是否显示已完成/放弃任务。默认开启（用户偏好，持久化到 UserDefaults）
    var showCompleted: Bool {
        didSet {
            UserDefaults.standard.set(showCompleted, forKey: Self.showCompletedKey)
        }
    }

    static let showCompletedKey = "showCompleted"
    var searchText = ""
    var lastError: String?
    /// ⌘F 请求聚焦搜索框：MainView 监听该值变化（菜单命令无法直接持有 FocusState）
    var searchFocusRequest = 0
    /// 方向键移动选中后自增：OutlineView 监听并 scrollTo 选中行
    var selectionScrollRequest = 0

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
        // 首次使用默认显示已完成；之后记住用户选择
        if let saved = UserDefaults.standard.object(forKey: Self.showCompletedKey) as? Bool {
            showCompleted = saved
        } else {
            showCompleted = true
        }
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
            for project in projects {
                topByProject[project.id] = try store.projectTasks(project.id, includeCompleted: showCompleted)
            }
            projectTasks = topByProject
            // 一次查询取全部分组（任意层级），TaskRow 递归渲染
            subtasks = try store.subtasksTree(includeCompleted: showCompleted)

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

    // MARK: 备份与导出（DATA-1 / DATA-2）

    func refreshBackups() {
        backups = backupManager.listBackups()
    }

    @discardableResult
    func createBackupNow() -> Bool {
        do {
            _ = try backupManager.createBackup(of: store)
            refreshBackups()
            return true
        } catch {
            lastError = "备份失败：\(error.localizedDescription)"
            return false
        }
    }

    /// 应用启动时调用：当天还没有备份则自动创建一份
    func createDailyBackupIfNeeded() {
        do {
            _ = try backupManager.createDailyBackupIfNeeded(of: store)
            refreshBackups()
        } catch {
            lastError = "自动备份失败：\(error.localizedDescription)"
        }
    }

    /// 用备份覆盖当前库后整界面刷新（在线热替换，无需重启）
    func restoreBackup(_ entry: BackupEntry) {
        do {
            selectedTaskID = nil
            editingTaskID = nil
            expandedParents.removeAll()
            try backupManager.restore(entry, into: store)
            reload()
            refreshBackups()
        } catch {
            lastError = "恢复备份失败：\(error.localizedDescription)"
        }
    }

    /// 导出并弹存储面板
    func exportThenSave(_ format: ExportFormat) {
        let content: String
        do {
            let exporter = TaskExporter(store: store)
            switch format {
            case .csv: content = try exporter.csv()
            case .opml: content = try exporter.opml()
            case .markdown: content = try exporter.markdown()
            }
        } catch {
            lastError = "导出失败：\(error.localizedDescription)"
            return
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MyFocus-\(formatter.string(from: Date())).\(format.fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            lastError = "写入文件失败：\(error.localizedDescription)"
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

    /// Tab 缩进成功后自动展开新的父任务
    func indentSelected() {
        guard let task = selectedTask else { return }
        do {
            if try store.indentTask(task.id) {
                if let moved = try store.task(id: task.id), let newParent = moved.parentID {
                    expandedParents.insert(newParent)
                }
                reload()
            } else {
                NSSound.beep()
            }
        } catch {
            lastError = "缩进失败：\(error.localizedDescription)"
        }
    }

    func outdentSelected() {
        guard let task = selectedTask else { return }
        do {
            if try store.outdentTask(task.id) {
                reload()
            } else {
                NSSound.beep()
            }
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

    /// 行间拖拽落点：插前/插后/成为子任务（子树跟随）。返回是否生效（拖入自身子树/无变化 beep 并返回 false）
    @discardableResult
    func dropTask(_ id: UUID, relativeTo anchor: TaskItem, position: OutlineDropPosition) -> Bool {
        do {
            if try store.dropTask(id, relativeTo: anchor.id, position: position) {
                if case .into = position { expandedParents.insert(anchor.id) }
                reload()
                return true
            }
        } catch {
            lastError = "移动任务失败：\(error.localizedDescription)"
        }
        NSSound.beep()
        return false
    }

    // MARK: 方向键导航（↑↓←→）

    /// 当前视图可见行的扁平序列，顺序与 OutlineView 渲染一致：
    /// 顶层任务 + 递归展开的子任务（今天视图按 逾期→今天→未来7天 分段拼接）
    private var visibleTasks: [TaskItem] {
        let tops: [TaskItem]
        if isSearching {
            tops = searchResults
        } else {
            switch section {
            case .inbox: tops = inboxTasks
            case .today: tops = [.overdue, .today, .next7Days].flatMap { todaySections[$0] ?? [] }
            case .project(let id): tops = projectTasks[id] ?? []
            }
        }
        var result: [TaskItem] = []
        func append(_ task: TaskItem) {
            result.append(task)
            guard expandedParents.contains(task.id) else { return }
            for child in subtasks[task.id] ?? [] { append(child) }
        }
        for task in tops { append(task) }
        return result
    }

    /// ↑/↓：移到可见行的上/下一行；无选中或选中不在当前视图时，↓ 落首行、↑ 落末行。
    /// 返回是否吞掉事件：无可见行时 false（放行给侧边栏等原生行为），边界处 true（无动作）
    @discardableResult
    func moveSelection(_ offset: Int) -> Bool {
        let tasks = visibleTasks
        guard !tasks.isEmpty else { return false }
        let index = selectedTaskID.flatMap { id in tasks.firstIndex(where: { $0.id == id }) }
        let next: Int
        if let index {
            next = index + offset
            guard tasks.indices.contains(next) else { return true }
        } else {
            next = offset > 0 ? tasks.startIndex : tasks.index(before: tasks.endIndex)
        }
        select(tasks[next].id)
        return true
    }

    /// →：未展开则展开；已展开则进入第一个子任务
    func arrowRight() {
        guard let task = selectedTask else { return }
        guard let children = subtasks[task.id], !children.isEmpty else {
            NSSound.beep()
            return
        }
        if expandedParents.contains(task.id) {
            select(children[0].id)
        } else {
            expandedParents.insert(task.id)
        }
    }

    /// ←：已展开则折叠；否则选中父任务（父行在当前视图不可见时无效，如今天/搜索视图）
    func arrowLeft() {
        guard let task = selectedTask else { return }
        if expandedParents.contains(task.id), !(subtasks[task.id] ?? []).isEmpty {
            expandedParents.remove(task.id)
            return
        }
        if let parentID = task.parentID, visibleTasks.contains(where: { $0.id == parentID }) {
            select(parentID)
        } else {
            NSSound.beep()
        }
    }

    private func select(_ id: UUID) {
        selectedTaskID = id
        refreshSelected()
        selectionScrollRequest += 1
    }

    // MARK: 键盘路由（KeyboardRouter 调用）

    /// 应用级 keyDown 拦截：命中大纲快捷键返回 true（吞掉事件）。
    /// 文本编辑上下文（行内编辑/搜索框/检查器文本框）一律放行。
    /// 裸 ↑↓ 例外：无选中任务时也响应（↓ 选首行 / ↑ 选末行）。
    func swallowKeyEvent(_ event: NSEvent) -> Bool {
        guard editingTaskID == nil,
              event.window === NSApp.keyWindow,
              !(NSApp.keyWindow?.firstResponder is NSTextView)
        else { return false }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasShift = mods.contains(.shift)
        let hasOption = mods.contains(.option)
        let hasCommand = mods.contains(.command)
        let hasControl = mods.contains(.control)
        let hasNoModifiers = !hasShift && !hasOption && !hasCommand && !hasControl

        // 裸 ↑↓ 前置：不依赖选中；无可选行时放行（如空大纲，交给侧边栏原生行为）
        if hasNoModifiers && (event.keyCode == 125 || event.keyCode == 126) {
            return moveSelection(event.keyCode == 125 ? 1 : -1)
        }

        guard selectedTask != nil else { return false }

        // macOS keyCode：48=Tab 36=Return 49=Space 123=← 124=→ 125=↓ 126=↑
        switch event.keyCode {
        case 48 where !hasCommand && !hasControl && !hasOption:
            if hasShift { outdentSelected() } else { indentSelected() }
            return true
        case 36 where hasNoModifiers:
            insertAfter(selectedTask!)
            return true
        case 125 where hasOption && !hasShift && !hasCommand && !hasControl:
            moveSelected(1)
            return true
        case 126 where hasOption && !hasShift && !hasCommand && !hasControl:
            moveSelected(-1)
            return true
        case 123 where hasNoModifiers:
            arrowLeft()
            return true
        case 124 where hasNoModifiers:
            arrowRight()
            return true
        case 49 where !hasCommand && !hasControl:
            if hasOption {
                setStatus(selectedTask!, to: selectedTask!.status == .active ? .dropped : .active)
            } else if !hasShift {
                toggleComplete(selectedTask!)
            } else {
                return false
            }
            return true
        default:
            return false
        }
    }

    func toggleComplete(_ task: TaskItem) {
        setStatus(task, to: task.status == .active ? .completed : .active)
    }

    func setStatus(_ task: TaskItem, to status: ItemStatus) {
        do {
            try store.setTaskStatus(task.id, status)
            // 完成后把选中转移到同容器的相邻任务：被完成的任务会从列表消失，
            // 若留给 List 自行处理，选中可能跳到其父任务行，下一次空格就会误完成整棵子树
            if status != .active, selectedTaskID == task.id {
                selectedTaskID = neighborForSelection(around: task)
            }
            reload()
        } catch {
            lastError = "更新状态失败：\(error.localizedDescription)"
        }
    }

    /// 同容器内被移除任务的相邻任务（先取后方，再取前方）
    private func neighborForSelection(around task: TaskItem) -> UUID? {
        guard let list = try? store.siblingTasks(of: task),
              let index = list.firstIndex(where: { $0.id == task.id })
        else { return nil }
        if index + 1 < list.count { return list[index + 1].id }
        if index > 0 { return list[index - 1].id }
        return nil
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

    /// 侧边栏拖拽调整项目顺序（onMove）
    func moveProjects(from source: IndexSet, to destination: Int) {
        var ordered = projects
        ordered.move(fromOffsets: source, toOffset: destination)
        do {
            try store.reorderProjects(ordered.map(\.id))
            reload()
        } catch {
            lastError = "调整项目顺序失败：\(error.localizedDescription)"
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
