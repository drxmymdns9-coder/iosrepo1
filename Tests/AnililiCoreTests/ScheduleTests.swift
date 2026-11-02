import Foundation
import Testing
@testable import AnililiCore

struct ScheduleTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2 // Monday, as most of Europe draws it
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test func monthGridIsWholeWeeksFromTheConfiguredFirstDay() {
        // October 2026 starts on a Thursday: three days of September lead in from Monday.
        let grid = ScheduleService.monthGrid(containing: date(2026, 10, 15), calendar: utc)
        #expect(grid.count % 7 == 0)
        #expect(grid.first == date(2026, 9, 28))
        #expect(grid.last == date(2026, 11, 1))
    }

    @Test func aDayOnAMonthEdgeReadsBothFiles() {
        let window = DateInterval(start: date(2026, 9, 30, 20), duration: 8 * 3600)
        #expect(ScheduleService.monthKeys(covering: window) == ["2026-09", "2026-10"])
        #expect(ScheduleService.monthKeys(covering: DateInterval(start: date(2026, 10, 5), duration: 86_400)) == ["2026-10"])
    }

    @Test func readsTheIndexAndFallsBackPerMonth() async throws {
        let october = """
        [{"id":21,"episode":1180,"airingAt":\(Int(date(2026, 10, 11, 1).timeIntervalSince1970)),"english":"ONE PIECE","cover":"https://x/y.jpg","format":"TV","year":1999},
         {"id":9,"episode":3,"airingAt":\(Int(date(2026, 10, 11, 9).timeIntervalSince1970)),"romaji":"Ecchi","adult":true},
         {"id":21,"episode":1180,"airingAt":\(Int(date(2026, 10, 11, 1).timeIntervalSince1970)),"english":"ONE PIECE"},
         {"id":5,"episode":2,"airingAt":\(Int(date(2026, 10, 12, 1).timeIntervalSince1970)),"english":"Tomorrow"}]
        """
        let service = ScheduleService { url in
            url.lastPathComponent == "2026-10.json" ? Data(october.utf8) : nil
        }
        let day = try await service.day(date(2026, 10, 11, 12), calendar: utc, hideAdult: true)
        #expect(day.map(\.media.id) == [21])
        #expect(day.first?.media.title.preferred == "ONE PIECE")
        #expect(day.first?.media.coverImage?.large == "https://x/y.jpg")
        let counts = await service.counts([date(2026, 10, 11), date(2026, 10, 12)], calendar: utc, hideAdult: false)
        #expect(counts[date(2026, 10, 11)] == 2)
        #expect(counts[date(2026, 10, 12)] == 1)
    }
}
