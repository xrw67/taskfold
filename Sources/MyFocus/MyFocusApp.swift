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
                    appState = try AppState(store: TaskStore.createDefault())
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
                    get: { appState?.showCompleted ?? false },
                    set: {
                        appState?.showCompleted = $0
                        appState?.reload()
                    }
                ))
            }
            CommandMenu("任务") {
                Button("完成 / 恢复") {
                    if let task = appState?.selectedTask {
                        appState?.toggleComplete(task)
                    }
                }
                .disabled(appState?.selectedTask == nil)

                Button("删除", role: .destructive) {
                    if let task = appState?.selectedTask {
                        appState?.delete(task)
                    }
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(appState?.selectedTask == nil)
            }
        }
    }
}
