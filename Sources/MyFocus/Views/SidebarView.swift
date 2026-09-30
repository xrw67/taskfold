import SwiftUI
import MyFocusKit

/// 计数徽章：紧急（逾期/今天）用红，普通用次级色
struct CountBadge: View {
    let count: Int
    var urgent = false

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.caption)
                .monospacedDigit()
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background((urgent ? Color.red : Color.secondary).opacity(0.15), in: Capsule())
                .foregroundStyle(urgent ? .red : .secondary)
        }
    }
}

struct SidebarView: View {
    @Environment(AppState.self) private var app
    @State private var newProjectShown = false
    @State private var newProjectName = ""
    @State private var renamingProject: ProjectItem?
    @State private var renameText = ""
    @State private var deletingProject: ProjectItem?
    /// 拖放高亮：收件箱与各项目行（INB-3）
    @State private var dropTargetIDs: Set<FocusSection> = []

    private var inboxDropHovered: Bool {
        dropTargetIDs.contains(.inbox)
    }

    /// 拖拽任务 id 到侧边栏 = 分配项目（INB-3）
    private func dropTasks(_ items: [String], to projectID: UUID?) -> Bool {
        guard let idString = items.first,
              let taskID = UUID(uuidString: idString),
              let task = try? app.store.task(id: taskID)
        else { return false }
        app.assign(task, to: projectID)
        return true
    }

    var body: some View {
        @Bindable var app = app
        List(selection: sectionBinding) {
            Section {
                inboxRow
                todayRow
            }

            Section("项目") {
                ForEach(app.projects) { project in
                    sidebarRow(project)
                }
                .onMove { app.moveProjects(from: $0, to: $1) }
                newProjectButton
            }
        }
        .listStyle(.sidebar)
        .alert("新建项目", isPresented: $newProjectShown) {
            TextField("项目名称", text: $newProjectName)
            Button("创建") { app.newProject(name: newProjectName) }
                .keyboardShortcut(.defaultAction)
            Button("取消", role: .cancel) {}
        }
        .alert("重命名项目", isPresented: Binding(
            get: { renamingProject != nil },
            set: { if !$0 { renamingProject = nil } }
        )) {
            TextField("项目名称", text: $renameText)
            Button("存储") {
                if var p = renamingProject {
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        p.name = name
                        app.update(p)
                    }
                }
                renamingProject = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("取消", role: .cancel) { renamingProject = nil }
        }
        .alert(
            "删除项目「\(deletingProject?.name ?? "")」？",
            isPresented: Binding(
                get: { deletingProject != nil },
                set: { if !$0 { deletingProject = nil } }
            )
        ) {
            Button("删除", role: .destructive) {
                if let p = deletingProject { app.delete(p) }
                deletingProject = nil
            }
            Button("取消", role: .cancel) { deletingProject = nil }
        } message: {
            Text("其中的任务会移回收件箱，不会被删除。")
        }
    }

    private var sectionBinding: Binding<FocusSection?> {
        Binding(
            get: { app.section },
            set: { if let s = $0 { app.section = s } }
        )
    }

    /// 收件箱行（也是拖放目标：拖到这里 = 移回收件箱）
    private var inboxRow: some View {
        HStack {
            Label("收件箱", systemImage: "tray")
            Spacer()
            CountBadge(count: app.inboxBadge)
        }
        .tag(FocusSection.inbox)
        .dropDestination(for: String.self) { items, _ in
            dropTasks(items, to: nil)
        } isTargeted: { hovering in
            setHover(.inbox, hovering)
        }
        .background(
            dropTargetIDs.contains(.inbox) ? Color.accentColor.opacity(0.15) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    private var todayRow: some View {
        HStack {
            Label("今天", systemImage: "sun.max")
            Spacer()
            CountBadge(count: app.todayBadge.overdue, urgent: true)
            CountBadge(count: app.todayBadge.today + app.todayBadge.next7Days)
        }
        .tag(FocusSection.today)
    }

    private var newProjectButton: some View {
        Button {
            newProjectName = ""
            newProjectShown = true
        } label: {
            Label("新建项目", systemImage: "plus")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func setHover(_ section: FocusSection, _ hovering: Bool) {
        if hovering {
            dropTargetIDs.insert(section)
        } else {
            dropTargetIDs.remove(section)
        }
    }

    @ViewBuilder
    private func sidebarRow(_ project: ProjectItem) -> some View {
        let section = FocusSection.project(project.id)
        HStack {
            Label(project.name, systemImage: project.status == .active ? "folder" : "folder.badge.minus")
                .foregroundStyle(project.status == .active ? .primary : .secondary)
            Spacer()
            CountBadge(count: app.projectBadges[project.id]?.overdue ?? 0, urgent: true)
            CountBadge(count: app.projectBadges[project.id]?.remaining ?? 0)
        }
        .tag(section)
        .dropDestination(for: String.self) { items, _ in
            dropTasks(items, to: project.id)
        } isTargeted: { hovering in
            if hovering { dropTargetIDs.insert(section) } else { dropTargetIDs.remove(section) }
        }
        .background(dropTargetIDs.contains(section) ? Color.accentColor.opacity(0.15) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            Button("重命名…") {
                renameText = project.name
                renamingProject = project
            }
            if project.status == .active {
                Button("完成项目") { app.setProjectStatus(project, to: .completed) }
                Button("放弃项目") { app.setProjectStatus(project, to: .dropped) }
            } else {
                Button("重新激活") { app.setProjectStatus(project, to: .active) }
            }
            Divider()
            Button("删除项目…", role: .destructive) {
                deletingProject = project
            }
        }
    }
}
