import SwiftUI
import AppKit
import MyFocusKit

// MARK: - 状态圈（点击完成，⌥点击放弃）

struct StatusCircle: View {
    let task: TaskItem
    var onToggle: () -> Void
    var onDrop: () -> Void
    /// 圈外径；图标字号与热区随之缩放（大纲行 18，检查器头部 22）
    var size: CGFloat = 18

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
                    .frame(width: size, height: size)
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: size * 0.45, weight: .bold))
                        .foregroundStyle(color)
                }
            }
            // 热区放大，降低紧凑行距下点到相邻行的概率
            .frame(width: size + 6, height: size + 6)
            .contentShape(Rectangle())
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
    /// 是否响应行间拖放（今天/搜索视图禁用）
    var supportsRowDrop = true

    @State private var editingText = ""
    @FocusState private var editing: Bool
    /// 行间拖放悬停位置（上边缘=插前 / 下边缘=插后 / 中部=成为子任务）
    @State private var hoverSlot: OutlineDropPosition?

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
    }

    @ViewBuilder
    private var rowContent: some View {
        let children = app.subtasks[task.id] ?? []
        if children.isEmpty {
            dropDecorated(plainRow)
        } else {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { app.expandedParents.contains(task.id) },
                    set: { open in app.setExpanded(task.id, open) }
                )
            ) {
                ForEach(children) { child in
                    TaskRow(task: child, showProjectName: showProjectName)
                }
            } label: {
                dropDecorated(plainRow)
            }
        }
    }

    // MARK: 行间拖放（装饰挂在行标签上，随层级递归生效）

    /// 中部 = 成为子任务；上/下 10pt 边缘 = 插入前/后；悬停显示插入线或淡色底
    @ViewBuilder
    private func dropDecorated(_ content: some View) -> some View {
        if supportsRowDrop {
            content
                .background {
                    if hoverSlot == .into {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(0.15))
                    }
                }
                .dropDestination(for: String.self) { items, _ in
                    performDrop(items, position: .into)
                } isTargeted: { setHover(.into, hovering: $0) }
                .overlay(alignment: .top) {
                    dropZone(position: .before)
                        .frame(height: 10)
                }
                .overlay(alignment: .bottom) {
                    dropZone(position: .after)
                        .frame(height: 10)
                }
                .overlay(alignment: .top) {
                    if hoverSlot == .before { insertionLine }
                }
                .overlay(alignment: .bottom) {
                    if hoverSlot == .after { insertionLine }
                }
        } else {
            content
        }
    }

    /// 行边缘拖放条
    private func dropZone(position: OutlineDropPosition) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                performDrop(items, position: position)
            } isTargeted: { setHover(position, hovering: $0) }
    }

    /// 3pt 插入指示线
    private var insertionLine: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(height: 3)
            .padding(.horizontal, 4)
            .allowsHitTesting(false)
    }

    /// 悬停状态：置 nil 只清自己那个值，避免相邻区切换时闪烁
    private func setHover(_ position: OutlineDropPosition, hovering: Bool) {
        if hovering {
            hoverSlot = position
        } else if hoverSlot == position {
            hoverSlot = nil
        }
    }

    private func performDrop(_ items: [String], position: OutlineDropPosition) -> Bool {
        guard let first = items.first, let id = UUID(uuidString: first) else { return false }
        hoverSlot = nil
        return app.dropTask(id, relativeTo: task, position: position)
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
                titleText
                    // 双击重命名只挂标题：若挂整行，count:2 手势会迫使状态圈等按钮
                    // 等双击窗口（约 0.5s）过期确认无第二击后才触发，点击明显发黏
                    .onTapGesture(count: 2) {
                        editingText = task.title
                        app.editingTaskID = task.id
                        editing = true
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
        .padding(.vertical, 3)
    }

    /// 标题文本（搜索时带命中高亮）
    @ViewBuilder
    private var titleText: some View {
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
