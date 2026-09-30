import Foundation

/// 条目状态：进行中 / 已完成 / 已放弃
public enum ItemStatus: String, Codable, Sendable, CaseIterable {
    case active
    case completed
    case dropped

    public var label: String {
        switch self {
        case .active: "进行中"
        case .completed: "已完成"
        case .dropped: "已放弃"
        }
    }
}

/// 项目：一组围绕同一目标的任务容器（V1 全部视为并行）
public struct ProjectItem: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var note: String
    public var status: ItemStatus
    public var sortIndex: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        note: String = "",
        status: ItemStatus = .active,
        sortIndex: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.note = note
        self.status = status
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// 任务在大纲中的拖拽落点：插到锚点前/后（同容器兄弟）或成为锚点的子任务
public enum OutlineDropPosition: Sendable, Equatable {
    case before
    case after
    case into
}

/// 任务：最小待办单元。V1 子任务最多一层（parentID 指向同为任务的父项）
public struct TaskItem: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var note: String
    /// 所属项目；nil = 收件箱任务
    public var projectID: UUID?
    /// 父任务（子任务）；nil = 顶层任务
    public var parentID: UUID?
    public var status: ItemStatus
    /// 截止时间；nil = 无截止。无时间部分按当天 17:00 处理（App 层约定）
    public var dueDate: Date?
    public var sortIndex: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        note: String = "",
        projectID: UUID? = nil,
        parentID: UUID? = nil,
        status: ItemStatus = .active,
        dueDate: Date? = nil,
        sortIndex: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.note = note
        self.projectID = projectID
        self.parentID = parentID
        self.status = status
        self.dueDate = dueDate
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 是否逾期：有截止且截止早于当前时间且未完成
    public func isOverdue(now: Date = Date()) -> Bool {
        guard status == .active, let due = dueDate else { return false }
        return due < now
    }

    /// 是否"即将到期"：截止时间落在参考时间当天（颜色语义=今天/黄橙）
    public func isDueToday(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let due = dueDate else { return false }
        return calendar.isDate(due, inSameDayAs: now)
    }
}

/// 「今天」视图的三段分组
public enum TodaySection: String, CaseIterable, Sendable {
    case overdue = "逾期"
    case today = "今天"
    case next7Days = "未来 7 天"

    public func contains(_ task: TaskItem, now: Date, calendar: Calendar) -> Bool {
        switch self {
        case .overdue:
            return task.isOverdue(now: now)
        case .today:
            guard let due = task.dueDate, task.status == .active else { return false }
            return due >= now && calendar.isDate(due, inSameDayAs: now)
        case .next7Days:
            guard let due = task.dueDate, task.status == .active else { return false }
            guard let endOf7Days = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: now))
            else { return false }
            return due > now
                && !calendar.isDate(due, inSameDayAs: now)
                && due < endOf7Days
        }
    }
}
