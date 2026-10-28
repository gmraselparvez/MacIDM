import Foundation

/// Token-bucket bandwidth throttle shared by every segment of every download.
/// Callers take bytes and, if the bucket goes into debt, sleep until it's paid back.
public actor SpeedLimiter {
    /// Bytes per second; 0 means unlimited.
    public private(set) var limit: Double = 0
    private var tokens: Double = 0
    private var last = Date()

    public init(bytesPerSecond: Int64 = 0) {
        limit = Double(max(0, bytesPerSecond))
        tokens = limit
    }

    public func setLimit(_ bytesPerSecond: Int64) {
        limit = Double(max(0, bytesPerSecond))
        tokens = limit // allow up to one second of burst
        last = Date()
    }

    public func acquire(_ bytes: Int) async {
        guard limit > 0 else { return }
        let now = Date()
        tokens = min(limit, tokens + now.timeIntervalSince(last) * limit)
        last = now
        tokens -= Double(bytes)
        if tokens < 0 {
            let wait = -tokens / limit
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }
}
