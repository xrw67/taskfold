import SwiftUI
import MyFocusKit

@main
struct MyFocusApp: App {
    @State private var appState: AppState?
    @State private var bootError: String?

    var body: some Scene {
        WindowGroup("MyFocus") {
            Group {
                if let appState {
                    MainView()
                        .environment(appState)
                } else if let bootError {
                    ContentUnavailableView {
                        Label("无法打开数据库", systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        Text(bootError)
                    }
                } else {
                    ProgressView()
                }
            }
            .task {
                guard appState == nil, bootError == nil else { return }
                do {
                    let state = try AppState(store: TaskStore.createDefault())
                    appState = state
                    // 大纲快捷键（Tab/⇧Tab/回车/⌥↑↓/Space）由 NSEvent monitor 统一接管：
                    // 无修饰键 Tab 的菜单 key equivalent 会被系统焦点循环吞掉
                    KeyboardRouter.shared.install(state)
                    // 当天首次启动自动做一份备份（DATA-1）
                    state.createDailyBackupIfNeeded()
                } catch {
                    bootError = "数据库位置：\(TaskStore.defaultDatabaseURL().path)\n\n\(error.localizedDescription)"
                }
            }
        }
        .defaultSize(width: 1180, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建任务") { appState?.newTask() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .saveItem) {
                Menu("导出为") {
                    Button("CSV 表格…") { appState?.exportThenSave(.csv) }
                    Button("OPML 大纲…") { appState?.exportThenSave(.opml) }
                    Button("Markdown…") { appState?.exportThenSave(.markdown) }
                }
                Divider()
                Button("立即备份") { _ = appState?.createBackupNow() }
            }
            CommandMenu("视图") {
                Button("收件箱") { appState?.section = .inbox }
                    .keyboardShortcut("1", modifiers: .command)
                Button("今天") { appState?.section = .today }
                    .keyboardShortcut("2", modifiers: .command)
                Button("第一个项目") {
                    if let first = appState?.projects.first {
                        appState?.section = .project(first.id)
                    }
                }
                .keyboardShortcut("3", modifiers: .command)
                Divider()
                Toggle("显示检查器", isOn: Binding(
                    get: { appState?.showInspector ?? true },
                    set: { appState?.showInspector = $0 }
                ))
                .keyboardShortcut("i", modifiers: [.command, .option])
                Toggle("显示已完成", isOn: Binding(
                    get: { appState?.showCompleted ?? true },
                    set: {
                        appState?.showCompleted = $0
                        appState?.reload()
                    }
                ))
            }
            CommandMenu("任务") {
                // 说明：Tab/⇧Tab/回车/Space/⌥Space 由 KeyboardRouter（NSEvent monitor）接管，
                // 不再绑定菜单 key equivalent（无修饰键 Tab 会被系统焦点循环吞掉）；菜单项仅供鼠标点击
                Button("完成 / 恢复（Space）") {
                    if let task = appState?.selectedTask {
                        appState?.toggleComplete(task)
                    }
                }
                .disabled(appState?.selectedTask == nil)

                Button("放弃 / 恢复（⌥Space）") {
                    if let task = appState?.selectedTask {
                        appState?.setStatus(task, to: task.status == .active ? .dropped : .active)
                    }
                }
                .disabled(appState?.selectedTask == nil)

                Button("缩进为子任务（Tab）") {
                    appState?.indentSelected()
                }
                .disabled(appState?.selectedTask == nil)

                Button("提升一级（⇧Tab）") {
                    appState?.outdentSelected()
                }
                .disabled(appState?.selectedTask == nil)

                Button("在下方插入任务（回车）") {
                    if let task = appState?.selectedTask {
                        appState?.insertAfter(task)
                    }
                }
                .disabled(appState?.selectedTask == nil)

                Button("上移（⌥↑）") { appState?.moveSelected(-1) }
                    .disabled(appState?.selectedTask == nil)
                Button("下移（⌥↓）") { appState?.moveSelected(1) }
                    .disabled(appState?.selectedTask == nil)

                Button("删除", role: .destructive) {
                    if let task = appState?.selectedTask {
                        appState?.delete(task)
                    }
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(appState?.selectedTask == nil)
            }

            CommandMenu("帮助") {
                Button("聚焦搜索") { appState?.searchFocusRequest += 1 }
                    .keyboardShortcut("f", modifiers: .command)
            }
        }

        settingsScene
    }

    private var settingsScene: some Scene {
        Settings {
            if let appState {
                SettingsView()
                    .environment(appState)
            }
        }
    }
}
