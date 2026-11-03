import Foundation

/// Short reset labels for the popover: `4:59a` later today, `Wed 3a` on another day, `now` once
/// passed.
public enum ResetFormat {
    public static func label(for resetsAt: Date, now: Date, calendar: Calendar = .current) -> String {
        let remaining = resetsAt.timeIntervalSince(now)
        if remaining <= 0 { return "now" }

        if calendar.isDate(resetsAt, inSameDayAs: now) {
            let parts = calendar.dateComponents([.hour, .minute], from: resetsAt)
            return clock(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
        }

        // Another day: name it, and round to the nearest hour.
        let rounded = resetsAt.addingTimeInterval(30 * 60)
        let parts = calendar.dateComponents([.weekday, .hour], from: rounded)
        let weekday = calendar.shortWeekdaySymbols[(parts.weekday ?? 1) - 1]
        return "\(weekday) \(clock(hour: parts.hour ?? 0, minute: 0))"
    }

    private static func clock(hour: Int, minute: Int) -> String {
        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        let suffix = hour < 12 ? "a" : "p"
        return minute == 0 ? "\(hour12)\(suffix)" : String(format: "%d:%02d%@", hour12, minute, suffix)
    }
}
