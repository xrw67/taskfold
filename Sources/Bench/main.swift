import Foundation
import GRDB

// M0 存储选型基准测试（GRDB 单侧）。
//
// 选型过程：原计划对比 GRDB 与 SwiftData。实测发现默认工具链（xcode-select 指向
// Command Line Tools 时）不含 SwiftDataMacros 宏插件，SwiftData 的 @Model 无法
// 编译。结合 Swift 6 严格并发下 SwiftData 生态尚不成熟、缺少 FTS5/迁移工具等
// 因素，M0 决定：采用 GRDB 7。本基准用于验证 GRDB 在 V1 目标数据量（1 万条）
// 下的性能。
//
// 注：后续发现本机装有完整 Xcode 27（/Applications/Xcode.app），开发时统一用
// DEVELOPER_DIR 指向它（见 Makefile），但存储选型结论不变。

// MARK: - 测量工具

@inline(never)
func consume<T>(_ value: T) {}

func measure(_ label: String, _ body: () throws -> Void) rethrows {
    let start = DispatchTime.now().uptimeNanoseconds
    try body()
    let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    print("  " + label.padding(toLength: 44, withPad: " ", startingAt: 0) + String(format: "%9.1f ms", ms))
}

// MARK: - 测试数据（固定种子的 LCG，结果可复现）

struct LCG: RandomNumberGenerator {
    var state: UInt64 = 0x853c49e6748fea9b
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

struct SampleTask {
    let id = UUID()
    let title: String
    let note: String?
    let projectID: UUID?
    let status: String
    let dueDate: Date?
    let createdAt: Date
    let updatedAt: Date
    let sortIndex: Int
}

func makeSamples(count: Int, projects: [UUID]) -> [SampleTask] {
    var rng = LCG()
    let now = Date()
    return (0..<count).map { i in
        let due: Date? = (rng.next() % 10 < 7)
            ? now.addingTimeInterval(TimeInterval(Int(rng.next() % (14 * 24 * 3600)) - 3 * 24 * 3600))
            : nil
        return SampleTask(
            title: "Task #\(i) — 一些中文标题用于测试",
            note: rng.next() % 5 == 0 ? "备注内容 \(i)" : nil,
            projectID: rng.next() % 10 < 8 ? projects[Int(rng.next() % UInt64(projects.count))] : nil,
            status: rng.next() % 20 == 0 ? "completed" : "active",
            dueDate: due,
            createdAt: now,
            updatedAt: now,
            sortIndex: i
        )
    }
}

// MARK: - GRDB 基准

struct GTask: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "task"
    var id: UUID
    var title: String
    var note: String?
    var projectID: UUID?
    var parentID: UUID?
    var status: String
    var dueDate: Date?
    var createdAt: Date
    var updatedAt: Date
    var sortIndex: Int
}

@main
enum BenchMain {
    static func main() throws {
        let projects = (0..<50).map { _ in UUID() }
        let samples = makeSamples(count: 10_000, projects: projects)
        print("═══ Taskfold M0 存储基准（GRDB 7）：10,000 条任务 / 50 个项目 ═══")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("taskfold-bench-grdb.sqlite")
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
        }
        let db = try DatabaseQueue(path: url.path, configuration: config)

        try db.write { db in
            try db.create(table: "task") { t in
                t.primaryKey("id", .blob)
                t.column("title", .text).notNull()
                t.column("note", .text)
                t.column("projectID", .blob).indexed()
                t.column("parentID", .blob)
                t.column("status", .text).notNull().indexed()
                t.column("dueDate", .datetime).indexed()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("sortIndex", .integer).notNull()
            }
        }

        let rows = samples.map { s in
            GTask(id: s.id, title: s.title, note: s.note, projectID: s.projectID, parentID: nil,
                  status: s.status, dueDate: s.dueDate, createdAt: s.createdAt, updatedAt: s.updatedAt,
                  sortIndex: s.sortIndex)
        }

        try measure("insert 10k（单事务）") {
            try db.write { db in
                for r in rows { try r.insert(db) }
            }
        }
        try measure("查询: active 按截止排序") {
            let list = try db.read { db in
                try GTask.fetchAll(db, sql: """
                    SELECT * FROM task WHERE status = 'active'
                    ORDER BY dueDate IS NULL, dueDate
                    """)
            }
            consume(list.count)
        }
        try measure("计数: active 且 sortIndex<5000") {
            let n = try db.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task WHERE status = 'active' AND sortIndex < 5000")!
            }
            consume(n)
        }
        try measure("全量水合 10k 行") {
            let list = try db.read { try GTask.fetchAll($0) }
            consume(list.count)
        }
        try measure("更新 1000 行（单事务）") {
            try db.write { db in
                try db.execute(sql: "UPDATE task SET title = title || '✓' WHERE sortIndex < 1000")
            }
        }
        try measure("删除 1000 行（单事务）") {
            try db.write { db in
                try db.execute(sql: "DELETE FROM task WHERE sortIndex >= 9000")
            }
        }
        try measure("重开数据库后全量查询") {
            let db2 = try DatabaseQueue(path: url.path)
            let list = try db2.read { try GTask.fetchAll($0) }
            consume(list.count)
        }
        print("\n数据库文件大小：\(try fileSizeKB(url) + fileSizeKB(URL(fileURLWithPath: url.path + "-wal"))) KB")

        func fileSizeKB(_ u: URL) throws -> Int {
            guard FileManager.default.fileExists(atPath: u.path) else { return 0 }
            return (try FileManager.default.attributesOfItem(atPath: u.path)[.size] as! Int) / 1024
        }
    }
}
