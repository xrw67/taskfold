import Foundation
import Testing
@testable import MyFocusKit

@Suite
struct ProjectReorderTests {
    let store: TaskStore

    init() throws {
        store = try TaskStore.inMemory()
    }

    private func names() throws -> [String] {
        try store.projects().map(\.name)
    }

    @Test func reorderPersistsNewOrder() throws {
        let a = try store.addProject(name: "A")
        _ = try store.addProject(name: "B")
        let c = try store.addProject(name: "C")

        // 把 C 拖到最前
        try store.reorderProjects([c.id, a.id])

        #expect(try names() == ["C", "A", "B"])
    }

    @Test func addProjectAfterReorderAppendsToEnd() throws {
        let a = try store.addProject(name: "A")
        let b = try store.addProject(name: "B")
        try store.reorderProjects([b.id, a.id])

        _ = try store.addProject(name: "C")

        #expect(try names() == ["B", "A", "C"], "重排后新建项目应追加到末尾")
    }
}
