import SwiftUI
import TaskfoldKit

struct InspectorView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Group {
            if let task = app.selectedTask {
                taskInspector(task)
            } else if let project = app.currentProject {
                projectInspector(project)
            } else {
                ContentUnavailableView(
                    "检查器",
                    systemImage: "sidebar.trailing",
                    description: Text("选择一个任务查看和编辑其属性")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - 任务检查器

    private func taskInspector(_ task: TaskItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    StatusCircle(task: task, onToggle: {
                        app.toggleComplete(task)
                    }, onDrop: {
                        app.setStatus(task, to: task.status == .active ? .dropped : .active)
                    }, size: 22)

                    VStack(alignment: .leading, spacing: 4) {
                        TextField("标题", text: taskBinding(task, \.title))
                            .textFieldStyle(.plain)
                            .font(.title3.weight(.semibold))
                            .strikethrough(task.status != .active)
                            .foregroundStyle(task.status == .active ? .primary : .secondary)
                            .onSubmit { app.update(task) }

                        HStack(spacing: 8) {
                            if let projectID = task.projectID,
                               let project = app.projects.first(where: { $0.id == projectID }) {
                                Label(project.name, systemImage: "folder")
                                    .font(.caption)
                                    .foregroundStyle(.tint)
                            }
                            if let due = task.dueDate {
                                DueChip(due: due)
                            }
                            if !task.note.isEmpty {
                                Image(systemName: "note.text")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Divider()

                statusRow(task.status) { app.setStatus(task, to: $0) }

                projectRow(task)

                DueDateRow(task: task)

                Divider()

                noteSection(text: taskBinding(task, \.note), minHeight: 100)

                Divider()

                Text(
                    "创建于 \(task.createdAt.formatted(date: .abbreviated, time: .shortened)) · "
                        + "修改于 \(task.updatedAt.formatted(date: .abbreviated, time: .shortened))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    /// 通用绑定：写入即保存
    private func taskBinding<T>(_ task: TaskItem, _ keyPath: WritableKeyPath<TaskItem, T>) -> Binding<T> {
        Binding(
            get: { task[keyPath: keyPath] },
            set: { newValue in
                var t = task
                t[keyPath: keyPath] = newValue
                app.update(t)
            }
        )
    }

    // MARK: - 项目检查器

    private func projectInspector(_ project: ProjectItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: project.status == .active ? "folder" : "folder.badge.minus")
                        .font(.system(size: 20))
                        .foregroundStyle(project.status == .active ? Color.accentColor : .secondary)
                        .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 4) {
                        TextField("名称", text: Binding(
                            get: { project.name },
                            set: { name in
                                var p = project
                                p.name = name
                                app.update(p)
                            }
                        ))
                        .textFieldStyle(.plain)
                        .font(.title3.weight(.semibold))
                        .onSubmit { app.update(project) }

                        Text("\(app.projectBadges[project.id]?.remaining ?? 0) 个剩余 · \(app.projectBadges[project.id]?.overdue ?? 0) 个逾期")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                statusRow(project.status) { app.setProjectStatus(project, to: $0) }

                Divider()

                noteSection(text: Binding(
                    get: { project.note },
                    set: { note in
                        var p = project
                        p.note = note
                        app.update(p)
                    }
                ), minHeight: 100)

                Divider()

                Text("创建于 \(project.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    // MARK: - 共享行组件

    /// 状态行：右侧彩色胶囊菜单
    private func statusRow(_ status: ItemStatus, action: @escaping (ItemStatus) -> Void) -> some View {
        HStack {
            Label("状态", systemImage: "flag")
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(ItemStatus.allCases, id: \.self) { candidate in
                    Button {
                        action(candidate)
                    } label: {
                        if candidate == status {
                            Label(candidate.label, systemImage: "checkmark")
                        } else {
                            Text(candidate.label)
                        }
                    }
                }
            } label: {
                menuLabel(color: Self.statusColor(status), text: status.label)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    /// 归属行：右侧项目菜单
    private func projectRow(_ task: TaskItem) -> some View {
        let currentName = task.projectID.flatMap { id in
            app.projects.first { $0.id == id }?.name
        } ?? "收件箱"

        return HStack {
            Label("项目", systemImage: "folder")
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button {
                    app.assign(task, to: nil)
                } label: {
                    if task.projectID == nil { Label("收件箱", systemImage: "checkmark") } else { Text("收件箱") }
                }
                ForEach(app.projects) { project in
                    Button {
                        app.assign(task, to: project.id)
                    } label: {
                        if task.projectID == project.id {
                            Label(project.name, systemImage: "checkmark")
                        } else {
                            Text(project.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(currentName)
                    chevron
                }
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    /// 备注区：小节标题 + 圆角灰底输入框
    private func noteSection(text: Binding<String>, minHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("备注")
            TextEditor(text: text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: minHeight + 16, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary.opacity(0.5))
                )
        }
    }

    /// 菜单胶囊标签：彩点 + 文字 + 下拉箭头
    private func menuLabel(color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
            chevron
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
        .contentShape(Capsule())
    }

    private var chevron: some View {
        Image(systemName: "chevron.up.chevron.down")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    fileprivate static func statusColor(_ status: ItemStatus) -> Color {
        switch status {
        case .active: .accentColor
        case .completed: .green
        case .dropped: .secondary
        }
    }
}

// MARK: - 小节标题

private struct SectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }
}

// MARK: - 截止日期（DT-1：值行 + 日历弹层）

/// 检查器「截止」行：显示截止时间或「无」，点击弹系统迷你月历
private struct DueDateRow: View {
    @Environment(AppState.self) private var app
    let task: TaskItem

    @State private var popoverShown = false

    var body: some View {
        HStack {
            Label("截止", systemImage: "calendar")
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                popoverShown.toggle()
            } label: {
                HStack(spacing: 4) {
                    if let due = task.dueDate {
                        DueChip(due: due)
                    } else {
                        Text("无")
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("点击选择截止时间")
            .popover(isPresented: $popoverShown, arrowEdge: .trailing) {
                DueDatePopover(task: task)
            }
        }
    }
}

/// 日历弹层：迷你月历 + 时间 + 快捷按钮
private struct DueDatePopover: View {
    @Environment(AppState.self) private var app
    let task: TaskItem

    /// 弹层当前展示的值：有截止用截止，无截止以「今天 + 默认时刻」作为起点
    private var effective: Date {
        task.dueDate ?? app.defaultDue(on: Date())
    }

    /// 月历：改日期保留现有时间分量
    private var datePart: Binding<Date> {
        Binding(
            get: { effective },
            set: { app.setDue(task, to: merge(dayFrom: $0, timeFrom: effective)) }
        )
    }

    /// 时间：改时间不动日期
    private var timePart: Binding<Date> {
        Binding(
            get: { effective },
            set: { app.setDue(task, to: merge(dayFrom: effective, timeFrom: $0)) }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            DatePicker("", selection: datePart, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()

            Divider().padding(.vertical, 8)

            DatePicker("时间", selection: timePart, displayedComponents: .hourAndMinute)
                .datePickerStyle(.compact)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider().padding(.vertical, 8)

            HStack {
                Button("今天") { app.setDue(task, to: app.defaultDue(on: Date())) }
                Button("明天") {
                    app.setDue(task, to: app.defaultDue(on: Calendar.current.date(byAdding: .day, value: 1, to: Date())!))
                }
                Button("+1周") {
                    app.setDue(task, to: app.defaultDue(on: Calendar.current.date(byAdding: .day, value: 7, to: Date())!))
                }
                Spacer()
                if task.dueDate != nil {
                    Button("清除", role: .destructive) { app.setDue(task, to: nil) }
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding()
        .frame(width: 280)
    }

    /// daySource 取年月日，timeSource 取时分，合成一个日期
    private func merge(dayFrom daySource: Date, timeFrom timeSource: Date) -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: daySource)
        let time = cal.dateComponents([.hour, .minute], from: timeSource)
        comps.hour = time.hour
        comps.minute = time.minute
        return cal.date(from: comps) ?? daySource
    }
}
