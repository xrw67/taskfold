import SwiftUI
import AppKit
import MyFocusKit

// MARK: - 状态圈（点击完成，⌥点击放弃）

struct StatusCircle: View {
    let task: TaskItem
    var onToggle: () -> Void
    var onDrop: () -> Void

    private var icon: String? {
        switch task.status {
        case .completed: "checkmark"
        case .dropped: "minus"
        case .active: nil
        }
    }

    private var color: Color {
        switch task.status {
        case .completed: .green
        case .dropped: .secondary
        case .active:
            if task.isOverdue() { .red }
            else if task.isDueToday() { .orange }
            else { .secondary }
        }
    }

    var body: some View {
        Button {
            if NSEvent.modifierFlags.contains(.option) {
                onDrop()
            } else {
                onToggle()
            }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(color, lineWidth: 1.5)
                    .frame(width: 18, height: 18)
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(color)
                }
            }
        }
        .buttonStyle(.plain)
        .help(task.status == .active ? "点击完成（⌥点击放弃）" : "点击恢复")
    }
}

// MARK: - 截止时间显示

struct DueChip: View {
    let due: Date

    private var text: String {
        let cal = Calendar.current
        let time = due.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute())
        if cal.isDateInYesterday(due) { return "昨天 \(time)" }
        if cal.isDateInToday(due) { return "今天 \(time)" }
        if cal.isDateInTomorrow(due) { return "明天 \(time)" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: due).day, days > 0, days <= 7 {
            let weekday = due.formatted(.dateTime.weekday(.wide))
            return "\(weekday) \(time)"
        }
        return due.formatted(.dateTime.month().day().hour(.twoDigits(amPM: .omitted)).minute())
    }

    private var color: Color {
        if due < Date() { .red }
        else if Calendar.current.isDateInToday(due) { .orange }
        else { .secondary }
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
    }
}

// MARK: - 任务行

struct TaskRow: View {
    @Environment(AppState.self) private var app
    let task: TaskItem
    var showProjectName = false
    var isSubtask = false

    @State private var editingText = ""
    @FocusState private var editing: Bool

    private var isEditing: Bool {
        app.editingTaskID == task.id
    }

    var body: some View {
        rowContent
            .tag(task.id)
            .draggable(task.id.uuidString)
            .contextMenu {
                if task.status == .active {
                    Button("完成") { app.setStatus(task, to: .completed) }
                    Button("放弃") { app.setStatus(task, to: .dropped) }
                } else {
                    Button("恢复为进行中") { app.setStatus(task, to: .active) }
                }
                Divider()
                Button("添加子任务") { app.addSubtask(to: task) }
                Divider()
                Button("删除", role: .destructive) { app.delete(task) }
            }
            .onTapGesture(count: 2) {
                editingText = task.title
                app.editingTaskID = task.id
                editing = true
            }
    }

    @ViewBuilder
    private var rowContent: some View {
        let children = app.subtasks[task.id] ?? []
        if children.isEmpty {
            plainRow
        } else {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { app.expandedParents.contains(task.id) },
                    set: { open in
                        if open { app.expandedParents.insert(task.id) }
                        else { app.expandedParents.remove(task.id) }
                    }
                )
            ) {
                ForEach(children) { child in
                    TaskRow(task: child, showProjectName: showProjectName, isSubtask: true)
                }
            } label: {
                plainRow
            }
        }
    }

    private var plainRow: some View {
        HStack(spacing: 6) {
            StatusCircle(task: task) {
                app.toggleComplete(task)
            } onDrop: {
                app.setStatus(task, to: task.status == .active ? .dropped : .active)
            }

            if isEditing {
                TextField("标题", text: $editingText)
                    .textFieldStyle(.roundedBorder)
                    .focused($editing)
                    .onSubmit { app.commitTitle(task, to: editingText, continueWithNew: true) }
                    .onKeyPress(.escape) {
                        editingText = task.title
                        app.editingTaskID = nil
                        return .handled
                    }
                    .onChange(of: editing) { _, focused in
                        if !focused, isEditing {
                            app.commitTitle(task, to: editingText)
                        }
                    }
                    .onAppear {
                        if isEditing {
                            editing = true
                        }
                    }
            } else {
                if app.isSearching, let query = app.searchText.trimmingCharacters(in: .whitespaces) as String?,
                   !query.isEmpty {
                    Text(highlightedTitle(task.title, query: query))
                        .strikethrough(task.status != .active)
                        .lineLimit(2)
                } else {
                    Text(task.title)
                        .strikethrough(task.status != .active)
                        .foregroundStyle(task.status == .active ? .primary : .secondary)
                        .lineLimit(2)
                }

                if showProjectName, let projectID = task.projectID,
                   let project = app.projects.first(where: { $0.id == projectID }) {
                    Text(project.name)
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let due = task.dueDate {
                DueChip(due: due)
            }
            if !task.note.isEmpty {
                Image(systemName: "note.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, isSubtask ? 8 : 0)
        .padding(.vertical, 1)
    }

    /// 搜索命中段高亮（KB-2）
    private func highlightedTitle(_ title: String, query: String) -> AttributedString {
        var attr = AttributedString(title)
        var searchRange = title.startIndex..<title.endIndex
        while let range = title.range(of: query, options: .caseInsensitive, range: searchRange) {
            if let attrRange = Range(NSRange(range, in: title), in: attr) {
                attr[attrRange].backgroundColor = Color.yellow.opacity(0.35)
                attr[attrRange].foregroundColor = .primary
            }
            searchRange = range.upperBound..<title.endIndex
        }
        return attr
    }
}
