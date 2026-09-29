import SwiftUI
import AppKit
import MyFocusKit

/// 设置窗口（⌘,）：默认截止时刻 + 数据库位置（DS-1）
struct SettingsView: View {
    @Environment(AppState.self) private var app
    @AppStorage(AppState.defaultDueHourKey) private var dueHour = 17
    @AppStorage(AppState.defaultDueMinuteKey) private var dueMinute = 0

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
        }
        .formStyle(.grouped)
        .frame(width: 440)
    }
}
