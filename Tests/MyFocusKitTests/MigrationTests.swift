import Foundation
import Testing
@testable import MyFocusKit

@Suite
struct MigrationTests {
    private func makeTempDir(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("migrate-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeLegacyStore() throws -> URL {
        let legacyDir = makeTempDir("legacy")
        let dbPath = legacyDir.appendingPathComponent("MyFocus.sqlite").path
        let store = try TaskStore(path: dbPath)
        try store.addProject(name: "迁移项目")
        try store.addTask(title: "迁移任务")
        let backups = legacyDir.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: backups.appendingPathComponent("MyFocus-20260930-100000.sqlite").path,
            contents: Data("fake".utf8)
        )
        return legacyDir
    }

    @Test func migratesRealDatabaseAndBackups() throws {
        let legacyDir = try makeLegacyStore()
        let newDir = makeTempDir("new")

        #expect(try TaskStore.migrateLegacyData(from: legacyDir, to: newDir) == true)

        // 库文件与备份目录都到了新位置，且数据可用
        let reopened = try TaskStore(path: newDir.appendingPathComponent("MyFocus.sqlite").path)
        #expect(try reopened.projects().first?.name == "迁移项目")
        #expect(try reopened.inboxTasks(includeCompleted: true).map(\.title) == ["迁移任务"])
        #expect(FileManager.default.fileExists(
            atPath: newDir.appendingPathComponent("Backups/MyFocus-20260930-100000.sqlite").path))
        #expect(!FileManager.default.fileExists(atPath: legacyDir.path), "移空的旧目录应被清理")
    }

    @Test func skipsWhenNewDatabaseAlreadyExists() throws {
        let legacyDir = try makeLegacyStore()
        let newDir = makeTempDir("new")
        FileManager.default.createFile(
            atPath: newDir.appendingPathComponent("MyFocus.sqlite").path,
            contents: Data("existing".utf8)
        )

        #expect(try TaskStore.migrateLegacyData(from: legacyDir, to: newDir) == false)
        #expect(FileManager.default.fileExists(atPath: legacyDir.path), "新库已存在时旧目录保持原样")
    }

    @Test func skipsOnFreshInstall() throws {
        let newDir = makeTempDir("new")
        let absentLegacy = makeTempDir("absent")
        try FileManager.default.removeItem(at: absentLegacy)

        #expect(try TaskStore.migrateLegacyData(from: absentLegacy, to: newDir) == false)
        #expect(!FileManager.default.fileExists(
            atPath: newDir.appendingPathComponent("MyFocus.sqlite").path), "全新安装不应凭空造库")
    }
}
