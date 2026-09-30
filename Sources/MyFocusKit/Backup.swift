import Foundation

// MARK: - 备份条目

public struct BackupEntry: Identifiable, Sendable, Equatable {
    public var id: String { url.absoluteString }
    public let url: URL
    public let date: Date
    public let fileSize: Int

    public init(url: URL, date: Date, fileSize: Int) {
        self.url = url
        self.date = date
        self.fileSize = fileSize
    }
}

// MARK: - 备份策略（DATA-1）

/// 快照式 SQLite 备份管理：创建、按日去重、按保留数轮换、列举与恢复。
/// 目录可注入，便于测试。
public final class BackupManager: Sendable {
    public static let keepCountKey = "backupKeepCount"
    public static let defaultKeepCount = 20

    public static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("MyFocus/Backups", isDirectory: true)
    }

    private let directory: URL

    public init(directory: URL = BackupManager.defaultDirectory) {
        self.directory = directory
    }

    /// 保留份数（UserDefaults 可配，默认 20）
    public var keepCount: Int {
        let raw = UserDefaults.standard.object(forKey: Self.keepCountKey) as? Int
        return max(1, min(200, raw ?? Self.defaultKeepCount))
    }

    /// 创建一份备份并按保留数裁剪。返回新建的条目。
    @discardableResult
    public func createBackup(of store: TaskStore, now: Date = Date()) throws -> BackupEntry {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = directory.appendingPathComponent("MyFocus-\(formatter.string(from: now)).sqlite")

        try store.backupDatabase(to: url)
        prune(keeping: keepCount)
        return entry(at: url) ?? BackupEntry(url: url, date: now, fileSize: 0)
    }

    /// 每日自动备份：当天已有备份则跳过。返回是否新建。
    @discardableResult
    public func createDailyBackupIfNeeded(of store: TaskStore, now: Date = Date()) throws -> Bool {
        let calendar = Calendar.current
        if listBackups().contains(where: { calendar.isDate($0.date, inSameDayAs: now) }) {
            return false
        }
        try createBackup(of: store, now: now)
        return true
    }

    /// 备份列表，新→旧
    public func listBackups() -> [BackupEntry] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return []
        }
        return files
            .filter { $0.lastPathComponent.hasPrefix("MyFocus-") && $0.pathExtension == "sqlite" }
            .compactMap { entry(at: $0) }
            .sorted { $0.date > $1.date }
    }

    /// 只保留最近 count 份，其余删除
    public func prune(keeping count: Int) {
        for stale in listBackups().dropFirst(count) {
            try? FileManager.default.removeItem(at: stale.url)
        }
    }

    /// 恢复：备份内容在线覆盖当前库
    public func restore(_ entry: BackupEntry, into store: TaskStore) throws {
        try store.restoreDatabase(from: entry.url)
    }

    private func entry(at url: URL) -> BackupEntry? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return nil
        }
        return BackupEntry(
            url: url,
            date: values.contentModificationDate ?? .distantPast,
            fileSize: values.fileSize ?? 0
        )
    }
}
