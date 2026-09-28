import SwiftUI

struct MainView: View {
    @Environment(AppState.self) private var app

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
                TextField("搜索", text: $app.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onChange(of: app.searchText) { app.reload() }
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
