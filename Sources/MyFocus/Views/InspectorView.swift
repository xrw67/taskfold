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
                Toggle("有截止时间", isOn: Binding(
                    get: { task.dueDate != nil },
                    set: { hasDue in
                        if hasDue {
                            let cal = Calendar.current
                            let defaultDue = cal.date(bySettingHour: 17, minute: 0, second: 0, of: Date())
                                ?? Date().addingTimeInterval(24 * 3600)
                            app.setDue(task, to: task.dueDate ?? defaultDue)
                        } else {
                            app.setDue(task, to: nil)
                        }
                    }
                ))

                if task.dueDate != nil {
                    DatePicker(
                        "截止",
                        selection: Binding(
                            get: { task.dueDate ?? Date() },
                            set: { app.setDue(task, to: $0) }
                        ),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    Button("清除截止", role: .destructive) {
                        app.setDue(task, to: nil)
                    }
                }
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

    private func projectInspector(_ project: ProjectItem) -> some View {
        @Bindable var app = app
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
