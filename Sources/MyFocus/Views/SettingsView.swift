import SwiftUI
import AppKit
import MyFocusKit

/// 设置窗口（⌘,）：默认截止时刻 + 数据库位置 + 备份管理（DS-1 / DATA-1）
struct SettingsView: View {
    @Environment(AppState.self) private var app
    @AppStorage(AppState.defaultDueHourKey) private var dueHour = 17
    @AppStorage(AppState.defaultDueMinuteKey) private var dueMinute = 0
    @AppStorage(BackupManager.keepCountKey) private var keepCount = BackupManager.defaultKeepCount
    @State private var confirmingRestore: BackupEntry?

    var body: some View {
        Form {
            Section("新任务") {
                DatePicker(
                    "默认截止时刻",
                    selection: Binding(
                        get: {
                            Calendar.current.date(bySettingHour: dueHour, minute: dueMinute, second: 0, of: Date())
                                ?? Date()
                        },
                        set: { newDate in
                            let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                            dueHour = comps.hour ?? 17
                            dueMinute = comps.minute ?? 0
                        }
                    ),
                    displayedComponents: .hourAndMinute
                )
                Text("在「今天」视图新建任务、或点日期快捷按钮（今天/明天/+1周）时使用该时刻。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("数据") {
                LabeledContent("数据库位置") {
                    Text(TaskStore.defaultDatabaseURL().path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([TaskStore.defaultDatabaseURL()])
                }
            }

            Section("备份") {
                Stepper("保留最近 \(keepCount) 份", onIncrement: {
                    keepCount = min(200, keepCount + 1)
                }, onDecrement: {
                    keepCount = max(1, keepCount - 1)
                })
                Button("立即备份") { _ = app.createBackupNow() }

                if app.backups.isEmpty {
                    Text("暂无备份")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(app.backups) { entry in
                        backupRow(entry)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
        .onAppear { app.refreshBackups() }
        .confirmationDialog(
            "恢复此备份？",
            isPresented: Binding(
                get: { confirmingRestore != nil },
                set: { if !$0 { confirmingRestore = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("恢复（当前数据将被覆盖）", role: .destructive) {
                if let entry = confirmingRestore {
                    app.restoreBackup(entry)
                }
                confirmingRestore = nil
            }
            Button("取消", role: .cancel) { confirmingRestore = nil }
        } message: {
            Text(confirmingRestore.map { "备份时间：\($0.date.formatted(.dateTime.year().month().day().hour().minute().second()))" } ?? "")
        }
    }

    private func backupRow(_ entry: BackupEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.date.formatted(.dateTime.year().month().day().hour().minute().second()))
                Text(ByteCountFormatter.string(fromByteCount: Int64(entry.fileSize), countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("恢复") { confirmingRestore = entry }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            } label: {
                Label("在 Finder 中显示", systemImage: "folder")
            }
        }
        .padding(.vertical, 1)
    }
}
