import Foundation

/// Daily start/stop times, stored as minutes since midnight.
public struct DailySchedule: Equatable, Sendable {
    public var startMinute: Int
    public var stopMinute: Int?

    public init(startMinute: Int, stopMinute: Int? = nil) {
        self.startMinute = startMinute
        self.stopMinute = stopMinute
    }

    /// True if a daily occurrence of `minute` falls in `(from, to]`. Works across midnight and long gaps (sleep).
    public static func crossed(minute: Int, from: Date, to: Date, calendar: Calendar = .current) -> Bool {
        guard to > from else { return false }
        var day = calendar.startOfDay(for: from)
        while day <= to {
            if let t = calendar.date(byAdding: .minute, value: minute, to: day), t > from, t <= to {
                return true
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return false }
            day = next
        }
        return false
    }

    public func startCrossed(from: Date, to: Date, calendar: Calendar = .current) -> Bool {
        Self.crossed(minute: startMinute, from: from, to: to, calendar: calendar)
    }

    public func stopCrossed(from: Date, to: Date, calendar: Calendar = .current) -> Bool {
        guard let stopMinute else { return false }
        return Self.crossed(minute: stopMinute, from: from, to: to, calendar: calendar)
    }
}
