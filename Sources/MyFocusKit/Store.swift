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

    /// 默认数据库路径：~/Library/Application Support/MyFocus/MyFocus.sqlite
    public static func defaultDatabaseURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("MyFocus", isDirectory: true).appendingPathComponent("MyFocus.sqlite")
    }

    public static func createDefault() throws -> TaskStore {
        let url = defaultDatabaseURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try TaskStore(path: url.path)
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

    public func updateTask(_ task: TaskItem) throws {
        var t = task
        t.updatedAt = Date()
        try db.write { try t.update($0) }
    }

    /// 改所属项目：指定项目后立即移出收件箱（INB-2）
    public func setTaskProject(_ taskID: UUID, projectID: UUID?) throws {
        _ = try db.write { db in
            try TaskItem.filter(id: taskID)
                .updateAll(db, Column("projectID").set(to: projectID), Column("updatedAt").set(to: Date()))
        }
    }

    /// 设置任务状态。完成/放弃父任务时级联处理其子任务；恢复不级联
    public func setTaskStatus(_ taskID: UUID, _ status: ItemStatus) throws {
        _ = try db.write { db in
            let now = Date()
            try TaskItem.filter(id: taskID)
                .updateAll(db, Column("status").set(to: status.rawValue), Column("updatedAt").set(to: now))
            if status != .active {
                try TaskItem
                    .filter(Column("parentID") == taskID && Column("status") == ItemStatus.active.rawValue)
                    .updateAll(db, Column("status").set(to: status.rawValue), Column("updatedAt").set(to: now))
            }
        }
    }

    /// 删除任务及其子任务
    public func deleteTask(_ taskID: UUID) throws {
        _ = try db.write { db in
            try TaskItem.filter(Column("parentID") == taskID).deleteAll(db)
            try TaskItem.filter(id: taskID).deleteAll(db)
        }
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
