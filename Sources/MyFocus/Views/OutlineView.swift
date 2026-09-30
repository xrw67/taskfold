import SwiftUI
import MyFocusKit

struct OutlineView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        Group {
            if app.isSearching {
                taskList(title: "搜索「\(app.searchText)」", tasks: app.searchResults, empty: .search)
            } else {
                switch app.section {
                case .inbox:
                    taskList(title: "收件箱", tasks: app.inboxTasks, empty: .inbox)
                case .today:
                    todayList
                case .project(let id):
                    let project = app.projects.first { $0.id == id }
                    taskList(
                        title: project?.name ?? "项目",
                        tasks: app.projectTasks[id] ?? [],
                        empty: .project
                    )
                }
            }
        }
    }

    // MARK: - 今天视图（逾期 / 今天 / 未来 7 天）

    private var todayList: some View {
        @Bindable var app = app
        let overdue = app.todaySections[.overdue] ?? []
        let today = app.todaySections[.today] ?? []
        let next7 = app.todaySections[.next7Days] ?? []
        let isEmpty = overdue.isEmpty && today.isEmpty && next7.isEmpty

        return Group {
            if isEmpty {
                OutlineEmptyState(kind: .today)
            } else {
                ScrollViewReader { proxy in
                    List(selection: $app.selectedTaskID) {
                        ForEach([(TodaySection.overdue, overdue), (.today, today), (.next7Days, next7)], id: \.0) { section, tasks in
                            if !tasks.isEmpty {
                                Section {
                                    ForEach(tasks) { task in
                                        TaskRow(task: task, showProjectName: true)
                                    }
                                } header: {
                                    TodaySectionHeader(
                                        title: section.rawValue,
                                        count: tasks.count,
                                        urgent: section == .overdue
                                    )
                                }
                            }
                        }
                    }
                    .onChange(of: app.selectedTaskID) { app.refreshSelected() }
                    .onChange(of: app.selectionScrollRequest) {
                        if let id = app.selectedTaskID { proxy.scrollTo(id) }
                    }
                }
            }
        }
    }

    // MARK: - 通用任务列表

    private func taskList(title: String, tasks: [TaskItem], empty: OutlineEmptyState.Kind) -> some View {
        @Bindable var app = app
        return Group {
            if tasks.isEmpty {
                OutlineEmptyState(kind: empty)
            } else {
                ScrollViewReader { proxy in
                    List(selection: $app.selectedTaskID) {
                        Section(title) {
                            ForEach(tasks) { task in
                                TaskRow(task: task)
                            }
                        }
                    }
                    .onChange(of: app.selectedTaskID) { app.refreshSelected() }
                    .onChange(of: app.selectionScrollRequest) {
                        if let id = app.selectedTaskID { proxy.scrollTo(id) }
                    }
                }
            }
        }
    }
}

// MARK: - 今天视图分区标题

struct TodaySectionHeader: View {
    let title: String
    let count: Int
    var urgent = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(urgent ? Color.red : Color.primary)
            Text("\(count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(urgent ? Color.red : Color.secondary)
        }
    }
}

// MARK: - 空状态

struct OutlineEmptyState: View {
    enum Kind {
        case inbox, today, project, search

        var icon: String {
            switch self {
            case .inbox: "tray"
            case .today: "sun.max"
            case .project: "folder"
            case .search: "magnifyingglass"
            }
        }

        var title: String {
            switch self {
            case .inbox: "收件箱是空的"
            case .today: "今天没有要截止的事"
            case .project: "项目还是空的"
            case .search: "没有匹配的结果"
            }
        }

        var hint: String {
            switch self {
            case .inbox: "按 ⌘N 快速捕获一个想法"
            case .today: "有截止日期的任务会自动出现在这里"
            case .project: "按 ⌘N 添加第一个任务"
            case .search: "换个关键词试试"
            }
        }
    }

    let kind: Kind

    var body: some View {
        ContentUnavailableView {
            Label(kind.title, systemImage: kind.icon)
        } description: {
            Text(kind.hint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
