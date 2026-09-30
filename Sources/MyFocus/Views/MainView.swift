import SwiftUI

struct MainView: View {
    @Environment(AppState.self) private var app
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var app = app
        HSplitView {
            SidebarView()
                .frame(minWidth: 190, idealWidth: 220, maxWidth: 340)
            OutlineView()
                .frame(minWidth: 400)
                .layoutPriority(1)
            if app.showInspector {
                InspectorView()
                    .frame(minWidth: 250, idealWidth: 290, maxWidth: 400)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: Binding(
                    get: { app.showCompleted },
                    set: {
                        app.showCompleted = $0
                        app.reload()
                    }
                )) {
                    Label("显示已完成", systemImage: app.showCompleted ? "eye" : "eye.slash")
                }
                .toggleStyle(.button)
                .help("显示已完成任务")

                Button {
                    app.showInspector.toggle()
                } label: {
                    Label("检查器", systemImage: "sidebar.trailing")
                }
                Button {
                    app.newTask()
                } label: {
                    Label("新建任务", systemImage: "plus")
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                TextField("搜索", text: $app.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .focused($searchFocused)
                    .onChange(of: app.searchText) { app.reload() }
                    .onChange(of: app.searchFocusRequest) { _, _ in
                        searchFocused = true
                    }
                    .onKeyPress(.escape) {
                        app.searchText = ""
                        app.reload()
                        searchFocused = false
                        return .handled
                    }
            }
        }
        .alert(
            "出错了",
            isPresented: Binding(
                get: { app.lastError != nil },
                set: { if !$0 { app.lastError = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(app.lastError ?? "")
        }
    }
}
