import SwiftUI
import MyFocusKit

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
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - 任务检查器

    private func taskInspector(_ task: TaskItem) -> some View {
        @Bindable var app = app
        return Form {
            Section("任务") {
                TextField("标题", text: taskBinding(task, \.title))
                    .onSubmit { app.update(task) }

                Picker("状态", selection: taskBinding(task, \.status)) {
                    ForEach(ItemStatus.allCases, id: \.self) { status in
                        Text(status.label).tag(status)
                    }
                }
            }

            Section("归属") {
                Picker("项目", selection: Binding(
                    get: { task.projectID },
                    set: { app.assign(task, to: $0) }
                )) {
                    Text("收件箱").tag(UUID?.none)
                    ForEach(app.projects) { project in
                        Text(project.name).tag(UUID?.some(project.id))
                    }
                }
            }

            Section("时间") {
                DueDateRow(task: task)
            }

            Section("备注") {
                TextEditor(text: taskBinding(task, \.note))
                    .frame(minHeight: 80)
            }

            Section("元数据") {
                LabeledContent("创建于", value: task.createdAt.formatted(.dateTime.year().month().day().hour().minute()))
                LabeledContent("修改于", value: task.updatedAt.formatted(.dateTime.year().month().day().hour().minute()))
            }
        }
        .formStyle(.grouped)
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

    private func projectInspector(_ project: ProjectItem) -> some View {        @Bindable var app = app
        return Form {
            Section("项目") {
                TextField("名称", text: Binding(
                    get: { project.name },
                    set: { name in
                        var p = project
                        p.name = name
                        app.update(p)
                    }
                ))
                .onSubmit { app.update(project) }

                Picker("状态", selection: Binding(
                    get: { project.status },
                    set: { app.setProjectStatus(project, to: $0) }
                )) {
                    Text("进行中").tag(ItemStatus.active)
                    Text("已完成").tag(ItemStatus.completed)
                    Text("已放弃").tag(ItemStatus.dropped)
                }
            }

            Section("备注") {
                TextEditor(text: Binding(
                    get: { project.note },
                    set: { note in
                        var p = project
                        p.note = note
                        app.update(p)
                    }
                ))
                .frame(minHeight: 80)
            }

            Section("统计") {
                LabeledContent("剩余任务", value: "\(app.projectBadges[project.id]?.remaining ?? 0)")
                LabeledContent("逾期", value: "\(app.projectBadges[project.id]?.overdue ?? 0)")
                LabeledContent("创建于", value: project.createdAt.formatted(.dateTime.year().month().day()))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 截止日期（DT-1：值行 + 日历弹层）

/// 检查器「时间」区的值行：显示截止时间或「无」，点击弹系统迷你月历
private struct DueDateRow: View {
    @Environment(AppState.self) private var app
    let task: TaskItem

    @State private var popoverShown = false

    var body: some View {
        LabeledContent("截止") {
            Button {
                popoverShown.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(task.dueDate?.formatted(
                        .dateTime.month().day().weekday(.abbreviated).hour().minute())
                        ?? "无"
                    )
                    .foregroundStyle(task.dueDate == nil ? .secondary : .primary)
                    Image(systemName: "calendar")
                        .font(.caption)
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
