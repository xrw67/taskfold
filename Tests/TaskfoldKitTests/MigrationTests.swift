import Foundation
import Testing
import GRDB
@testable import TaskfoldKit

@Suite
struct MigrationTests {
    private func makeTempDir(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("migrate-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 造一个旧版目录：库与备份沿用改名前的 MyFocus 命名（真实旧目录即如此）
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

        // 旧名库迁到新位置并改写为新名，且数据可用
        let reopened = try TaskStore(path: newDir.appendingPathComponent("Taskfold.sqlite").path)
        #expect(try reopened.projects().first?.name == "迁移项目")
        #expect(try reopened.inboxTasks(includeCompleted: true).map(\.title) == ["迁移任务"])
        // 备份文件随迁，且 MyFocus- 前缀改写为 Taskfold-（轮换/列举仍能识别）
        let newBackups = newDir.appendingPathComponent("Backups", isDirectory: true)
        #expect(FileManager.default.fileExists(
            atPath: newBackups.appendingPathComponent("Taskfold-20260930-100000.sqlite").path))
        #expect(!FileManager.default.fileExists(
            atPath: newBackups.appendingPathComponent("MyFocus-20260930-100000.sqlite").path))
        #expect(!FileManager.default.fileExists(atPath: legacyDir.path), "移空的旧目录应被清理")
    }

    @Test func skipsWhenNewDatabaseAlreadyExists() throws {
        let legacyDir = try makeLegacyStore()
        let newDir = makeTempDir("new")
        FileManager.default.createFile(
            atPath: newDir.appendingPathComponent("Taskfold.sqlite").path,
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
            atPath: newDir.appendingPathComponent("Taskfold.sqlite").path), "全新安装不应凭空造库")
    }

    // MARK: schema v1 → v2（task 加 expanded 列）

    /// 造一个只有 v1 结构的真实旧库（无 expanded 列，migrations 表只登记 v1）
    private func makeV1Database() throws -> (dir: URL, taskID: UUID) {
        let dir = makeTempDir("v1db")
        let taskID = UUID()
        let raw = try DatabaseQueue(path: dir.appendingPathComponent("Taskfold.sqlite").path)
        try raw.write { db in
            try db.execute(sql: """
                CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
                CREATE TABLE task (
                    id BLOB PRIMARY KEY,
                    title TEXT NOT NULL,
                    note TEXT NOT NULL DEFAULT '',
                    projectID BLOB,
                    parentID BLOB,
                    status TEXT NOT NULL DEFAULT 'active',
                    dueDate DATETIME,
                    sortIndex INTEGER NOT NULL,
                    createdAt DATETIME NOT NULL,
                    updatedAt DATETIME NOT NULL
                );
                INSERT INTO grdb_migrations (identifier) VALUES ('v1');
                INSERT INTO task (id, title, sortIndex, createdAt, updatedAt)
                    VALUES (?, ?, 0, ?, ?);
                """, arguments: [taskID, "旧任务", Date(), Date()])
        }
        return (dir, taskID)
    }

    @Test func v1DatabaseUpgradesToExpandedColumn() throws {
        let (dir, taskID) = try makeV1Database()
        let dbPath = dir.appendingPathComponent("Taskfold.sqlite").path

        let reopened = try TaskStore(path: dbPath)
        #expect(try reopened.task(id: taskID)?.title == "旧任务", "旧数据迁移后可读")
        #expect(try reopened.task(id: taskID)?.isExpanded == false, "旧行默认折叠，与 v1 行为一致")

        try reopened.setExpanded(taskID, true)
        let reopened2 = try TaskStore(path: dbPath)
        #expect(try reopened2.task(id: taskID)?.isExpanded == true, "迁移后可正常写读展开状态")
        #expect(try reopened2.expandedTaskIDs() == [taskID])

        // 新插入路径也带上了新列
        let added = try reopened2.addTask(title: "新任务")
        #expect(added.isExpanded == false)
        #expect(try reopened2.task(id: added.id)?.isExpanded == false)
    }
}
