import Foundation
import MacIDMCore

/// Sample downloads for screenshots: run with MACIDM_DEMO=1. Nothing is saved and nothing downloads.
enum DemoData {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["MACIDM_DEMO"] == "1" }

    static func items() -> [DownloadItem] {
        func item(_ name: String, _ url: String, size: Int64, done: Double, status: DownloadStatus,
                  speed: Double = 0, segments n: Int = 8, ago: TimeInterval = 0) -> DownloadItem {
            var i = DownloadItem(url: URL(string: url)!, fileName: name)
            i.totalSize = size
            i.acceptsRanges = true
            i.status = status
            i.speed = speed
            var plan = SegmentPlanner.plan(totalSize: size, acceptsRanges: true, requested: n)
            for k in plan.indices {
                let len = plan[k].length ?? 0
                // Uneven progress per connection looks like a real transfer.
                let share = min(1, done * (0.75 + 0.5 * Double((k * 37) % 10) / 10))
                plan[k].downloaded = status == .completed ? len : Int64(Double(len) * share)
            }
            i.segments = plan
            i.dateAdded = Date().addingTimeInterval(-ago - 60)
            if status == .completed { i.dateCompleted = Date().addingTimeInterval(-ago) }
            return i
        }
        return [
            item("ubuntu-24.04.1-desktop-amd64.iso", "https://releases.ubuntu.com/24.04/ubuntu-24.04.1-desktop-amd64.iso",
                 size: 6_114_656_256, done: 0.62, status: .downloading, speed: 38_400_000, segments: 16),
            item("Big Buck Bunny [aqz-KE-bpKQ].mp4", "https://www.youtube.com/watch?v=aqz-KE-bpKQ",
                 size: 276_824_064, done: 0.34, status: .downloading, speed: 9_800_000),
            item("Xcode_16.4.xip", "https://download.developer.apple.com/Developer_Tools/Xcode_16.4/Xcode_16.4.xip",
                 size: 3_221_225_472, done: 0.18, status: .paused),
            item("linux-6.6.tar.xz", "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.tar.xz",
                 size: 140_064_536, done: 1, status: .completed, ago: 600),
            item("Lo-fi Beats Mix.mp3", "https://www.youtube.com/watch?v=jfKfPfyJRdk",
                 size: 89_128_960, done: 1, status: .completed, ago: 3_600),
            item("Annual-Report-2026.pdf", "https://example.com/files/Annual-Report-2026.pdf",
                 size: 18_874_368, done: 1, status: .completed, ago: 86_400),
            item("Blender-4.5-macos-arm64.dmg", "https://download.blender.org/release/Blender4.5/blender-4.5-macos-arm64.dmg",
                 size: 412_090_368, done: 0, status: .queued),
        ]
    }
}
