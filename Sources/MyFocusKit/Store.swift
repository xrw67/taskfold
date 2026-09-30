import Foundation
import GRDB

// MARK: - GRDB 记录适配

extension TaskItem: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "task"
}

extension ProjectItem: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "project"
}

// MARK: - 存储层

/// 本地 SQLite 存储（GRDB）。线程安全：DatabaseQueue 串行执行所有读写。
/// V1 在主线程同步调用即可（基准：万级数据查询 < 30ms）。
public final class TaskStore: Sendable {
    private let db: DatabaseQueue

    /// 打开（必要时创建并迁移）数据库文件
    public init(path: String) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
        }
        db = try DatabaseQueue(path: path, configuration: config)
        try Self.migrator.migrate(db)
    }

    /// 内存库，用于测试
    public static func inMemory() throws -> TaskStore {
        try TaskStore(path: ":memory:")
    }

    // MARK: 备份（SQLite online backup，支持 WAL 快照与在线热替换）

    /// 把当前库在线备份到目标文件：先写临时名，成功后改为正式名（防半截备份）
    public func backupDatabase(to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmpURL = dir.appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let destination = try DatabaseQueue(path: tmpURL.path)
        try db.backup(to: destination)

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tmpURL, to: url)
    }

    /// 用备份文件在线覆盖当前库（反向 backup，热替换，无需重启应用）
    public func restoreDatabase(from url: URL) throws {
        let source = try DatabaseQueue(path: url.path)
        try source.backup(to: db)
    }

    // MARK: 数据目录

    /// 数据目录：~/.config/MyFocus
    public static var defaultDataDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/MyFocus", isDirectory: true)
    }

    /// 旧版数据目录（~/Library/Application Support/MyFocus），仅供一次性迁移
    public static var legacyDataDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("MyFocus", isDirectory: true)
    }

    public static func defaultDatabaseURL() -> URL {
        defaultDataDirectory.appendingPathComponent("MyFocus.sqlite")
    }

    public static func createDefault() throws -> TaskStore {
        // 打开数据库前先做旧目录迁移（无文件占用）
        try migrateLegacyData(from: legacyDataDirectory, to: defaultDataDirectory)
        let url = defaultDatabaseURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try TaskStore(path: url.path)
    }

    /// 一次性迁移：新库不存在且旧目录有库时，把库文件（含 WAL/SHM）与备份目录整体移到新目录。
    /// 幂等：已迁移或全新安装返回 false。旧目录移空后删除；残留未知文件则保留（避免误删）。
    @discardableResult
    public static func migrateLegacyData(from legacyDir: URL, to newDir: URL) throws -> Bool {
        let fm = FileManager.default
        let legacyDB = legacyDir.appendingPathComponent("MyFocus.sqlite")
        let newDB = newDir.appendingPathComponent("MyFocus.sqlite")
        guard !fm.fileExists(atPath: newDB.path), fm.fileExists(atPath: legacyDB.path) else {
            return false
        }

        try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        for name in ["MyFocus.sqlite", "MyFocus.sqlite-wal", "MyFocus.sqlite-shm"] {
            let source = legacyDir.appendingPathComponent(name)
            if fm.fileExists(atPath: source.path) {
                try fm.moveItem(at: source, to: newDir.appendingPathComponent(name))
            }
        }
        let legacyBackups = legacyDir.appendingPathComponent("Backups")
        if fm.fileExists(atPath: legacyBackups.path) {
            try fm.moveItem(at: legacyBackups, to: newDir.appendingPathComponent("Backups"))
        }
        if let leftovers = try? fm.contentsOfDirectory(atPath: legacyDir.path), leftovers.isEmpty {
            try? fm.removeItem(at: legacyDir)
        }
        return true
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "project") { t in
                t.primaryKey("id", .blob)
                t.column("name", .text).notNull()
                t.column("note", .text).notNull().defaults(to: "")
                t.column("status", .text).notNull().defaults(to: ItemStatus.active.rawValue)
                t.column("sortIndex", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "task") { t in
                t.primaryKey("id", .blob)
                t.column("title", .text).notNull()
                t.column("note", .text).notNull().defaults(to: "")
                t.column("projectID", .blob).indexed()
                t.column("parentID", .blob).indexed()
                t.column("status", .text).notNull().defaults(to: ItemStatus.active.rawValue)
                t.column("dueDate", .datetime).indexed()
                t.column("sortIndex", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }
        return migrator
    }

    // MARK: 项目

    public func projects() throws -> [ProjectItem] {
        try db.read { db in
            try ProjectItem.order(Column("sortIndex"), Column("createdAt")).fetchAll(db)
        }
    }

    @discardableResult
    public func addProject(name: String) throws -> ProjectItem {
        var project = ProjectItem(name: name)
        try db.write { db in
            let max: Int? = try Int.fetchOne(db, ProjectItem.select(max(Column("sortIndex"))))
            project.sortIndex = (max ?? -1) + 1
            try project.insert(db)
        }
        return project
    }

    public func updateProject(_ project: ProjectItem) throws {
        var p = project
        p.updatedAt = Date()
        try db.write { try p.update($0) }
    }

    /// 更新项目状态；完成/放弃时级联处理其下未完成任务（DS-4）
    public func setProjectStatus(_ projectID: UUID, _ status: ItemStatus) throws {
        _ = try db.write { db in
            let now = Date()
            try ProjectItem.filter(id: projectID)
                .updateAll(db, Column("status").set(to: status.rawValue), Column("updatedAt").set(to: now))
            if status != .active {
                try TaskItem
                    .filter(Column("projectID") == projectID && Column("status") == ItemStatus.active.rawValue)
                    .updateAll(db, Column("status").set(to: status.rawValue), Column("updatedAt").set(to: now))
            }
        }
    }

    /// 删除项目：其下任务移回收件箱，不连带删除（TP-4）
    public func deleteProject(_ projectID: UUID) throws {
        _ = try db.write { db in
            try ProjectItem.filter(id: projectID).deleteAll(db)
            try TaskItem.filter(Column("projectID") == projectID)
                .updateAll(db, Column("projectID").set(to: nil), Column("updatedAt").set(to: Date()))
        }
    }

    /// 按给定顺序整体重排项目（侧边栏拖拽排序）：重写全部 sortIndex 为 0…n-1。
    /// 调用方应传入完整顺序（app.projects 全量）；未包含的项目保留原 sortIndex。
    public func reorderProjects(_ orderedIDs: [UUID]) throws {
        _ = try db.write { db in
            let now = Date()
            for (index, id) in orderedIDs.enumerated() {
                try ProjectItem.filter(id: id)
                    .updateAll(db, Column("sortIndex").set(to: index), Column("updatedAt").set(to: now))
            }
        }
    }

    // MARK: 任务

    @discardableResult
    public func addTask(
        title: String,
        projectID: UUID? = nil,
        parentID: UUID? = nil,
        dueDate: Date? = nil
    ) throws -> TaskItem {
        var task = TaskItem(title: title, projectID: projectID, parentID: parentID, dueDate: dueDate)
        try db.write { db in
            var request = TaskItem.select(max(Column("sortIndex")))
            switch (parentID, projectID) {
            case (let parent?, _):
                request = request.filter(Column("parentID") == parent)
            case (nil, let project?):
                request = request.filter(Column("projectID") == project && Column("parentID") == nil)
            case (nil, nil):
                request = request.filter(Column("projectID") == nil && Column("parentID") == nil)
            }
            let max: Int? = try Int.fetchOne(db, request)
            task.sortIndex = (max ?? -1) + 1
            try task.insert(db)
        }
        return task
    }

    /// 编辑任务内容（标题/备注/截止）。只更新内容字段——状态走 setTaskStatus、
    /// 层级走大纲操作、归属走 setTaskProject，避免过期快照覆盖这些字段
    public func updateTask(_ task: TaskItem) throws {
        _ = try db.write { db in
            try TaskItem.filter(id: task.id).updateAll(
                db,
                Column("title").set(to: task.title),
                Column("note").set(to: task.note),
                Column("dueDate").set(to: task.dueDate),
                Column("updatedAt").set(to: Date())
            )
        }
    }

    // MARK: 大纲编辑（TP-1：Tab 缩进 / ⇧Tab 提升 / ⌥↑↓ 移动 / 回车续行）

    /// 同容器兄弟任务（含已完成，按顺序）。供 UI 的选中转移等逻辑使用。
    public func siblingTasks(of task: TaskItem) throws -> [TaskItem] {
        try db.read { try siblings($0, of: task) }
    }

    /// 同容器的兄弟任务（含已完成），按 sortIndex 排序
    private func siblings(_ db: Database, of task: TaskItem) throws -> [TaskItem] {
        var request = TaskItem.order(Column("sortIndex"), Column("createdAt"))
        switch (task.parentID, task.projectID) {
        case (let parent?, _):
            request = request.filter(Column("parentID") == parent)
        case (nil, let project?):
            request = request.filter(Column("projectID") == project && Column("parentID") == nil)
        case (nil, nil):
            request = request.filter(Column("projectID") == nil && Column("parentID") == nil)
        }
        return try request.fetchAll(db)
    }

    /// Tab：把任务缩进为「同容器前一个兄弟」的子任务（任意层级；子树经 parentID 链自动跟随）。
    /// 第一个兄弟没有前置兄弟，返回 false。
    @discardableResult
    public func indentTask(_ taskID: UUID) throws -> Bool {
        try db.write { db in
            guard let task = try TaskItem.filter(id: taskID).fetchOne(db) else { return false }

            let list = try siblings(db, of: task)
            guard let index = list.firstIndex(where: { $0.id == taskID }), index > 0 else {
                return false
            }

            let newParent = list[index - 1]
            let childMax: Int? = try Int.fetchOne(
                db,
                TaskItem.filter(Column("parentID") == newParent.id).select(max(Column("sortIndex")))
            )
            try TaskItem.filter(id: taskID).updateAll(
                db,
                Column("parentID").set(to: newParent.id),
                Column("sortIndex").set(to: (childMax ?? -1) + 1),
                Column("updatedAt").set(to: Date())
            )
            return true
        }
    }

    /// ⇧Tab：把任务提升一级（parentID = 原父的父），插到原父之后；子树自动跟随。
    @discardableResult
    public func outdentTask(_ taskID: UUID) throws -> Bool {
        try db.write { db in
            guard let task = try TaskItem.filter(id: taskID).fetchOne(db),
                  let parentID = task.parentID,
                  let parent = try TaskItem.filter(id: parentID).fetchOne(db)
            else { return false }

            // 原父所在容器中排在原父之后的兄弟整体后移一位
            try shiftSiblings(db, after: parent, by: 1)
            try TaskItem.filter(id: taskID).updateAll(
                db,
                Column("parentID").set(to: parent.parentID),
                Column("sortIndex").set(to: parent.sortIndex + 1),
                Column("updatedAt").set(to: Date())
            )
            return true
        }
    }

    /// ⌥↑ / ⌥↓：在同级内与上/下一个兄弟交换位置
    @discardableResult
    public func moveTask(_ taskID: UUID, offset: Int) throws -> Bool {
        try db.write { db in
            guard var task = try TaskItem.filter(id: taskID).fetchOne(db) else { return false }

            // sortIndex 出现重复（脏数据）时先按当前顺序归一化，避免交换后乱序
            var list = try siblings(db, of: task)
            let hasDuplicate = zip(list, list.dropFirst()).contains { $0.0.sortIndex >= $0.1.sortIndex }
            if hasDuplicate {
                let now = Date()
                for (i, s) in list.enumerated() {
                    try TaskItem.filter(id: s.id).updateAll(
                        db, Column("sortIndex").set(to: i), Column("updatedAt").set(to: now))
                }
                task = try TaskItem.filter(id: taskID).fetchOne(db)!
                list = try siblings(db, of: task)
            }

            guard let index = list.firstIndex(where: { $0.id == taskID }) else { return false }
            let target = index + offset
            guard list.indices.contains(target) else { return false }
            let other = list[target]

            try TaskItem.filter(id: taskID).updateAll(
                db, Column("sortIndex").set(to: other.sortIndex), Column("updatedAt").set(to: Date()))
            try TaskItem.filter(id: other.id).updateAll(
                db, Column("sortIndex").set(to: task.sortIndex), Column("updatedAt").set(to: Date()))
            return true
        }
    }

    /// 回车续行：在选中任务之后插入同级新任务
    @discardableResult
    public func insertTask(after taskID: UUID, title: String) throws -> TaskItem? {
        try db.write { db in
            guard let task = try TaskItem.filter(id: taskID).fetchOne(db) else { return nil }
            try shiftSiblings(db, after: task, by: 1)

            var new = TaskItem(title: title, projectID: task.projectID, parentID: task.parentID)
            new.sortIndex = task.sortIndex + 1
            try new.insert(db)
            return new
        }
    }

    /// 把同容器中 sortIndex 大于 anchor 的顶层/子任务整体平移（保持插入空间）
    private func shiftSiblings(_ db: Database, after anchor: TaskItem, by delta: Int) throws {
        var request = TaskItem.filter(Column("sortIndex") > anchor.sortIndex)
        switch (anchor.parentID, anchor.projectID) {
        case (let parent?, _):
            request = request.filter(Column("parentID") == parent)
        case (nil, let project?):
            request = request.filter(Column("projectID") == project && Column("parentID") == nil)
        case (nil, nil):
            request = request.filter(Column("projectID") == nil && Column("parentID") == nil)
        }
        try request.updateAll(
            db,
            Column("sortIndex").set(to: Column("sortIndex") + delta),
            Column("updatedAt").set(to: Date())
        )
    }

    // MARK: 首启示例数据（需求 7.3）

    /// 库为空时写入示例项目与任务，让新用户立即看到完整工作流。返回是否写入了。
    @discardableResult
    public func seedSampleDataIfEmpty(now: Date = Date(), calendar: Calendar = .current) throws -> Bool {
        let hasData = try db.read { db in
            try TaskItem.fetchCount(db) > 0 || ProjectItem.fetchCount(db) > 0
        }
        guard !hasData else { return false }

        let project = try addProject(name: "示例：网站改版")
        try addTask(title: "梳理需求（点左边的圆圈完成它）", projectID: project.id)
        let design = try addTask(title: "画首页原型", projectID: project.id)
        try addTask(title: "线框图", projectID: project.id, parentID: design.id)
        try addTask(title: "高保真设计稿", projectID: project.id, parentID: design.id)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        try addTask(title: "修复导航栏样式（已逾期演示）", projectID: project.id,
                    dueDate: calendar.date(bySettingHour: 17, minute: 0, second: 0, of: yesterday))
        try addTask(title: "联调 API", projectID: project.id,
                    dueDate: calendar.date(bySettingHour: 17, minute: 0, second: 0, of: now))

        try addTask(title: "试试拖到左侧「示例：网站改版」里")
        try addTask(title: "试试双击改标题，Tab 缩进成子任务",
                    dueDate: calendar.date(bySettingHour: 17, minute: 0, second: 0,
                                           of: calendar.date(byAdding: .day, value: 1, to: now)!))
        return true
    }

    /// 改所属项目：指定项目后立即移出收件箱（INB-2）；子任务随顶层任务一起移动（INB-3 拖拽）
    public func setTaskProject(_ taskID: UUID, projectID: UUID?) throws {
        _ = try db.write { db in
            let now = Date()
            try TaskItem.filter(id: taskID)
                .updateAll(db, Column("projectID").set(to: projectID), Column("updatedAt").set(to: now))
            try TaskItem.filter(Column("parentID") == taskID)
                .updateAll(db, Column("projectID").set(to: projectID), Column("updatedAt").set(to: now))
        }
    }

    /// 设置任务状态，整棵子树同步（多层大纲：完成/放弃/恢复父任务时递归作用于全部后代）
    public func setTaskStatus(_ taskID: UUID, _ status: ItemStatus) throws {
        _ = try db.write { db in
            let ids = try descendantIDs(db, root: taskID)
            try TaskItem
                .filter(ids.contains(Column("id")))
                .updateAll(db, Column("status").set(to: status.rawValue), Column("updatedAt").set(to: Date()))
        }
    }

    /// 删除任务及其全部后代（递归）
    public func deleteTask(_ taskID: UUID) throws {
        _ = try db.write { db in
            let ids = try descendantIDs(db, root: taskID)
            try TaskItem.filter(ids.contains(Column("id"))).deleteAll(db)
        }
    }

    /// 收集任务及其全部后代 id（宽度优先遍历 parentID 链）
    private func descendantIDs(_ db: Database, root taskID: UUID) throws -> Set<UUID> {
        var queue = [taskID]
        var visited: Set<UUID> = []
        while let id = queue.popLast() {
            guard visited.insert(id).inserted else { continue }
            let children = try UUID.fetchAll(
                db,
                sql: "SELECT id FROM task WHERE parentID = ?",
                arguments: [id]
            )
            queue.append(contentsOf: children)
        }
        return visited
    }

    // MARK: 查询

    /// 收件箱任务（无项目、顶层）
    public func task(id: UUID) throws -> TaskItem? {
        try db.read { try TaskItem.filter(id: id).fetchOne($0) }
    }

    public func project(id: UUID) throws -> ProjectItem? {
        try db.read { try ProjectItem.filter(id: id).fetchOne($0) }
    }

    public func inboxTasks(includeCompleted: Bool = false) throws -> [TaskItem] {
        try db.read { db in
            var request = TaskItem
                .filter(Column("projectID") == nil && Column("parentID") == nil)
                .order(Column("sortIndex"))
            if !includeCompleted {
                request = request.filter(Column("status") == ItemStatus.active.rawValue)
            }
            return try request.fetchAll(db)
        }
    }

    /// 项目顶层任务
    public func projectTasks(_ projectID: UUID, includeCompleted: Bool = false) throws -> [TaskItem] {
        try db.read { db in
            var request = TaskItem
                .filter(Column("projectID") == projectID && Column("parentID") == nil)
                .order(Column("sortIndex"))
            if !includeCompleted {
                request = request.filter(Column("status") == ItemStatus.active.rawValue)
            }
            return try request.fetchAll(db)
        }
    }

    /// 某父任务的子任务
    public func subtasks(of parentID: UUID, includeCompleted: Bool = false) throws -> [TaskItem] {
        try db.read { db in
            var request = TaskItem.filter(Column("parentID") == parentID).order(Column("sortIndex"))
            if !includeCompleted {
                request = request.filter(Column("status") == ItemStatus.active.rawValue)
            }
            return try request.fetchAll(db)
        }
    }

    /// 全部子任务按父分组（任意层级），一次查询供 UI 递归渲染，替代逐父查询的 N+1
    public func subtasksTree(includeCompleted: Bool = false) throws -> [UUID: [TaskItem]] {
        try db.read { db in
            var request = TaskItem.filter(Column("parentID") != nil).order(Column("sortIndex"))
            if !includeCompleted {
                request = request.filter(Column("status") == ItemStatus.active.rawValue)
            }
            let rows = try request.fetchAll(db)
            var result: [UUID: [TaskItem]] = [:]
            for row in rows {
                if let parent = row.parentID {
                    result[parent, default: []].append(row)
                }
            }
            return result
        }
    }

    /// 「今天」视图候选：所有有截止、未完成、且截止在 7 天窗口内（含逾期）的任务。
    /// 三段分组由 TodaySection.contains 完成（App 层）。
    public func tasksDueWithin7Days(now: Date, calendar: Calendar) throws -> [TaskItem] {
        let end = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: now))!
        return try db.read { db in
            try TaskItem
                .filter(
                    Column("status") == ItemStatus.active.rawValue
                        && Column("dueDate") != nil
                        && Column("dueDate") < end
                )
                .order(Column("dueDate"))
                .fetchAll(db)
        }
    }

    /// 全文搜索（标题+备注，LIKE 起步；FTS5 属 V2 优化）
    public func searchTasks(matching text: String, includeCompleted: Bool) throws -> [TaskItem] {
        let keyword = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }
        let escaped = keyword
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\(escaped)%"
        return try db.read { db in
            var request = TaskItem
                .filter(
                    sql: "title LIKE ? ESCAPE '\\' OR note LIKE ? ESCAPE '\\'",
                    arguments: [pattern, pattern]
                )
                .order(Column("updatedAt"), Column("sortIndex"))
            if !includeCompleted {
                request = request.filter(Column("status") == ItemStatus.active.rawValue)
            }
            return try request.fetchAll(db)
        }
    }

    // MARK: 徽章计数

    public func inboxCount() throws -> Int {
        try db.read { db in
            try TaskItem
                .filter(Column("projectID") == nil && Column("parentID") == nil
                    && Column("status") == ItemStatus.active.rawValue)
                .fetchCount(db)
        }
    }

    /// 各项目的（剩余数, 逾期数）
    public func projectBadgeCounts(now: Date) throws -> [UUID: (remaining: Int, overdue: Int)] {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT projectID,
                       COUNT(*) AS remaining,
                       SUM(CASE WHEN dueDate IS NOT NULL AND dueDate < ? THEN 1 ELSE 0 END) AS overdue
                FROM task
                WHERE status = 'active' AND projectID IS NOT NULL
                GROUP BY projectID
                """,
                arguments: [now]
            )
            var result: [UUID: (remaining: Int, overdue: Int)] = [:]
            for row in rows {
                if let id: UUID = row["projectID"] {
                    result[id] = (row["remaining"] ?? 0, row["overdue"] ?? 0)
                }
            }
            return result
        }
    }

    /// 侧边栏「今天」徽章：(逾期, 今天剩余, 未来7天)
    public func todayBadgeCounts(now: Date, calendar: Calendar) throws -> (overdue: Int, today: Int, next7Days: Int) {
        let tasks = try tasksDueWithin7Days(now: now, calendar: calendar)
        var overdue = 0, today = 0, next7 = 0
        for t in tasks {
            if t.isOverdue(now: now) {
                overdue += 1
            } else if t.isDueToday(now: now, calendar: calendar), let due = t.dueDate, due >= now {
                today += 1
            } else {
                next7 += 1
            }
        }
        return (overdue, today, next7)
    }
}
