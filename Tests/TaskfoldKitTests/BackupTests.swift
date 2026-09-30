import Foundation
import Testing
@testable import TaskfoldKit

@Suite
struct BackupTests {
    var calendar: Calendar { Calendar(identifier: .gregorian) }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("backuptest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func seed(_ store: TaskStore) throws {
        let project = try store.addProject(name: "项目A")
        try store.addTask(title: "任务1", projectID: project.id)
        try store.addTask(title: "任务2", projectID: project.id, dueDate: date(2026, 10, 2, 17))
        try store.addTask(title: "收件箱任务")
    }

    // MARK: 创建与内容一致性

    @Test func backupContainsSameData() throws {
        let store = try TaskStore.inMemory()
        try seed(store)
        let dir = makeTempDir()
        let manager = BackupManager(directory: dir)

        let entry = try manager.createBackup(of: store, now: date(2026, 9, 30, 10))

        #expect(FileManager.default.fileExists(atPath: entry.url.path))
        #expect(entry.url.lastPathComponent == "Taskfold-20260930-100000.sqlite")

        // 备份可独立打开，内容与源一致
        let reopened = try TaskStore(path: entry.url.path)
        #expect(try reopened.projects().count == 1)
        #expect(try reopened.projects().first?.name == "项目A")
        #expect(try reopened.inboxTasks(includeCompleted: true).count == 1)
        #expect(try reopened.projectTasks(try reopened.projects().first!.id, includeCompleted: true).count == 2)
    }

    @Test func backupCapturesCompletedStatus() throws {
        let store = try TaskStore.inMemory()
        let task = try store.addTask(title: "会完成的")
        try store.setTaskStatus(task.id, .completed)
        let manager = BackupManager(directory: makeTempDir())

        let entry = try manager.createBackup(of: store, now: date(2026, 9, 30))
        let reopened = try TaskStore(path: entry.url.path)

        #expect(try reopened.inboxTasks(includeCompleted: true).first?.status == .completed)
    }

    // MARK: 每日去重

    @Test func dailyBackupDeduplicatesSameDay() throws {
        let store = try TaskStore.inMemory()
        try seed(store)
        let manager = BackupManager(directory: makeTempDir())

        #expect(try manager.createDailyBackupIfNeeded(of: store, now: date(2026, 9, 30, 9)) == true)
        #expect(try manager.createDailyBackupIfNeeded(of: store, now: date(2026, 9, 30, 21)) == false,
                "同一天第二次启动不重复备份")
        #expect(manager.listBackups().count == 1)

        #expect(try manager.createDailyBackupIfNeeded(of: store, now: date(2026, 10, 1, 8)) == true)
        #expect(manager.listBackups().count == 2)
    }

    // MARK: 轮换

    @Test func pruneKeepsNewest() throws {
        let store = try TaskStore.inMemory()
        try seed(store)
        let manager = BackupManager(directory: makeTempDir())
        UserDefaults.standard.set(3, forKey: BackupManager.keepCountKey)
        defer { UserDefaults.standard.removeObject(forKey: BackupManager.keepCountKey) }

        for (i, day) in [1, 2, 3, 4, 5].enumerated() {
            _ = try manager.createBackup(of: store, now: date(2026, 9, day, 10 + i))
        }

        #expect(manager.listBackups().count == 3, "保留份数之外的旧备份应被删除")
        let names = manager.listBackups().map(\.url.lastPathComponent)
        #expect(names.contains("Taskfold-20260903-120000.sqlite"))
        #expect(!names.contains("Taskfold-20260901-100000.sqlite"), "最旧的应被裁掉")
    }

    // MARK: 恢复往返

    @Test func restoreRollsBackChanges() throws {
        let store = try TaskStore.inMemory()
        try seed(store)
        let manager = BackupManager(directory: makeTempDir())
        let entry = try manager.createBackup(of: store, now: date(2026, 9, 30))

        // 备份后继续变更：加任务、完成、删项目
        try store.addTask(title: "备份后新增")
        try store.setProjectStatus(try store.projects().first!.id, .completed)

        try manager.restore(entry, into: store)

        #expect(try store.inboxTasks(includeCompleted: true).map(\.title) == ["收件箱任务"],
                "恢复后备份后的新增应消失")
        #expect(try store.projects().first?.status == .active, "恢复后状态应回滚")
        #expect(try store.projectTasks(try store.projects().first!.id, includeCompleted: true).count == 2)
    }

    @Test func listBackupsSortedNewestFirst() throws {
        let store = try TaskStore.inMemory()
        let manager = BackupManager(directory: makeTempDir())
        for day in [1, 2, 3] {
            _ = try manager.createBackup(of: store, now: date(2026, 9, day))
        }
        let names = manager.listBackups().map(\.url.lastPathComponent)
        #expect(names.first?.contains("20260903") == true)
        #expect(names.last?.contains("20260901") == true)
    }
}
