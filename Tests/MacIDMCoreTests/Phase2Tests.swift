import Foundation
import Testing
@testable import MacIDMCore

@Suite struct QueueTests {
    private func item(_ status: DownloadStatus, addedAt t: TimeInterval) -> DownloadItem {
        var i = DownloadItem(url: URL(string: "https://e.com/\(t).zip")!)
        i.status = status
        i.dateAdded = Date(timeIntervalSince1970: t)
        return i
    }

    @Test func fillsFreeSlotsOldestFirst() {
        let items = [item(.queued, addedAt: 3), item(.downloading, addedAt: 0), item(.queued, addedAt: 1),
                     item(.queued, addedAt: 2), item(.paused, addedAt: 0.5)]
        let ids = QueueManager.idsToStart(items, maxConcurrent: 3)
        #expect(ids == [items[2].id, items[3].id])
    }

    @Test func noSlotsWhenFull() {
        let items = [item(.downloading, addedAt: 0), item(.probing, addedAt: 1), item(.queued, addedAt: 2)]
        #expect(QueueManager.idsToStart(items, maxConcurrent: 2).isEmpty)
    }

    @Test func respectsEligibility() {
        let items = [item(.queued, addedAt: 0), item(.queued, addedAt: 1)]
        let ids = QueueManager.idsToStart(items, maxConcurrent: 5) { $0.id == items[1].id }
        #expect(ids == [items[1].id])
    }

    @Test func detectsDownloadLinks() {
        #expect(QueueManager.isLikelyDownload("https://example.com/files/app.dmg"))
        #expect(QueueManager.isLikelyDownload(" http://e.com/a/movie.mp4?token=1 "))
        #expect(!QueueManager.isLikelyDownload("https://example.com/about"))
        #expect(!QueueManager.isLikelyDownload("ftp://e.com/a.zip"))
        #expect(!QueueManager.isLikelyDownload("see https://e.com/a.zip here"))
    }
}

@Suite struct ScheduleTests {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    func at(_ day: Int, _ h: Int, _ m: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 1, day: day, hour: h, minute: m))!
    }

    @Test func detectsCrossingWithinADay() {
        let s = DailySchedule(startMinute: 2 * 60, stopMinute: 6 * 60)
        #expect(s.startCrossed(from: at(1, 1, 59), to: at(1, 2, 0), calendar: cal))
        #expect(!s.startCrossed(from: at(1, 2, 0), to: at(1, 2, 1), calendar: cal))
        #expect(s.stopCrossed(from: at(1, 5, 30), to: at(1, 6, 15), calendar: cal))
    }

    @Test func detectsCrossingOverMidnightAndLongGaps() {
        let s = DailySchedule(startMinute: 30)  // 00:30
        #expect(s.startCrossed(from: at(1, 23, 50), to: at(2, 0, 40), calendar: cal))
        #expect(s.startCrossed(from: at(1, 1, 0), to: at(3, 0, 10), calendar: cal)) // Mac slept 2 days
        #expect(!s.startCrossed(from: at(1, 1, 0), to: at(1, 23, 0), calendar: cal))
        #expect(!s.stopCrossed(from: at(1, 0, 0), to: at(5, 0, 0), calendar: cal))  // no stop time
    }
}

@Suite struct SpeedLimiterTests {
    @Test func throttlesToRate() async {
        let limiter = SpeedLimiter(bytesPerSecond: 1_000_000)
        let start = Date()
        // 1 MB burst is free, the next 1.5 MB must take ~1.5 s.
        for _ in 0..<40 { await limiter.acquire(62_500) }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed > 1.3 && elapsed < 2.5, "elapsed \(elapsed)")
    }

    @Test func unlimitedDoesNotWait() async {
        let limiter = SpeedLimiter()
        let start = Date()
        for _ in 0..<100 { await limiter.acquire(10_000_000) }
        #expect(Date().timeIntervalSince(start) < 0.2)
    }
}
