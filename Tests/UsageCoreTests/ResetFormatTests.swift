import Foundation
import Testing
@testable import UsageCore

@Suite struct ResetFormatTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    /// Tue 2026-11-03 01:00 local.
    private var now: Date { at(day: 3, hour: 1, minute: 0) }

    private func at(day: Int, hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    @Test(arguments: [
        (3, 4, 59, "4:59a"),
        (3, 4, 0, "4a"),
        (3, 13, 30, "1:30p"),
        (3, 12, 0, "12p"),
    ])
    func withinADayShowsTime(day: Int, hour: Int, minute: Int, expected: String) {
        #expect(ResetFormat.label(for: at(day: day, hour: hour, minute: minute), now: now, calendar: calendar) == expected)
    }

    @Test(arguments: [
        (4, 2, 59, "Wed 3a"),
        (4, 2, 29, "Wed 2a"),
        (4, 23, 45, "Thu 12a"),
    ])
    func furtherOutShowsWeekdayAndRoundedHour(day: Int, hour: Int, minute: Int, expected: String) {
        #expect(ResetFormat.label(for: at(day: day, hour: hour, minute: minute), now: now, calendar: calendar) == expected)
    }

    /// Under 24 h away but tomorrow: still names the day, so it can't be read as earlier today.
    @Test func tomorrowWithinADayNamesTheDay() {
        let morning = at(day: 3, hour: 6, minute: 13)
        #expect(ResetFormat.label(for: at(day: 4, hour: 2, minute: 59), now: morning, calendar: calendar) == "Wed 3a")
        #expect(ResetFormat.label(for: at(day: 3, hour: 23, minute: 50), now: morning, calendar: calendar) == "11:50p")
    }

    @Test func pastShowsNow() {
        #expect(ResetFormat.label(for: now.addingTimeInterval(-60), now: now, calendar: calendar) == "now")
        #expect(ResetFormat.label(for: now, now: now, calendar: calendar) == "now")
    }
}
