import Foundation
import Testing
@testable import MyFocusKit

@Suite
struct ModelsTests {
    var calendar: Calendar {
        Calendar(identifier: .gregorian)
    }

    /// 构造指定年月日时的时间
    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @Test func overdueDetection() {
        let now = date(2026, 9, 28, 12)
        let overdue = TaskItem(title: "逾期", dueDate: date(2026, 9, 27, 17))
        let upcoming = TaskItem(title: "未来", dueDate: date(2026, 9, 29, 17))
        let noDue = TaskItem(title: "无截止")
        let done = TaskItem(title: "已完成", status: .completed, dueDate: date(2026, 9, 27, 17))

        #expect(overdue.isOverdue(now: now))
        #expect(!upcoming.isOverdue(now: now))
        #expect(!noDue.isOverdue(now: now))
        #expect(!done.isOverdue(now: now), "已完成的任务即使过期也不算逾期")
    }

    @Test func todaySections() {
        let now = date(2026, 9, 28, 12)
        let overdue = TaskItem(title: "昨天截止", dueDate: date(2026, 9, 27, 17))
        let laterToday = TaskItem(title: "今天 20 点", dueDate: date(2026, 9, 28, 20))
        let tomorrow = TaskItem(title: "明天", dueDate: date(2026, 9, 29, 10))
        let in6Days = TaskItem(title: "6 天后", dueDate: date(2026, 10, 4, 10))
        let in8Days = TaskItem(title: "8 天后", dueDate: date(2026, 10, 6, 10))
        let noDue = TaskItem(title: "无截止")

        func section(_ t: TaskItem) -> TodaySection? {
            TodaySection.allCases.first { $0.contains(t, now: now, calendar: calendar) }
        }

        #expect(section(overdue) == .overdue)
        #expect(section(laterToday) == .today)
        #expect(section(tomorrow) == .next7Days)
        #expect(section(in6Days) == .next7Days)
        #expect(section(in8Days) == nil, "8 天后不属于未来 7 天")
        #expect(section(noDue) == nil, "无截止任务不进今天视图")
    }

    @Test func completedTaskNotInTodaySections() {
        let now = date(2026, 9, 28, 12)
        let done = TaskItem(title: "已完成", status: .completed, dueDate: date(2026, 9, 28, 20))
        for s in TodaySection.allCases {
            #expect(!s.contains(done, now: now, calendar: calendar))
        }
    }
}
