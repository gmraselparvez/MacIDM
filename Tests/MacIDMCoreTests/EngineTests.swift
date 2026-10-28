import Foundation
import Testing
@testable import MacIDMCore

/// In-process fake HTTP server. Each test uses its own host so tests can run in parallel.
final class MockServer: URLProtocol, @unchecked Sendable {
    struct Config {
        var payload: Data
        var supportsRanges = true
        var advertiseRanges = true
        var etag = "\"v1\""
        var contentDisposition: String?
        var failFirstRequests = 0
        var chunkDelay: TimeInterval = 0
        var requiredCookie: String?
    }

    nonisolated(unsafe) private static var configs: [String: Config] = [:]
    nonisolated(unsafe) private static var requestCounts: [String: Int] = [:]
    private static let lock = NSLock()
    private var stopped = false

    static func register(_ host: String, _ config: Config) {
        lock.lock(); configs[host] = config; requestCounts[host] = 0; lock.unlock()
    }
    static func update(_ host: String, _ change: (inout Config) -> Void) {
        lock.lock(); change(&configs[host]!); lock.unlock()
    }

    static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockServer.self]
        return URLSession(configuration: cfg)
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".mock") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { stopped = true }

    override func startLoading() {
        let url = request.url!
        let host = url.host!
        Self.lock.lock()
        let config = Self.configs[host]!
        let n = Self.requestCounts[host]!
        Self.requestCounts[host] = n + 1
        Self.lock.unlock()

        if request.httpMethod != "HEAD" && n < config.failFirstRequests + 1 && n > 0 {
            respond(url, 503, [:], Data())
            return
        }

        if let cookie = config.requiredCookie, request.value(forHTTPHeaderField: "Cookie") != cookie {
            respond(url, 403, [:], Data())
            return
        }
        let total = Int64(config.payload.count)
        var headers = ["ETag": config.etag, "Content-Type": "application/octet-stream"]
        if config.advertiseRanges { headers["Accept-Ranges"] = "bytes" }
        if let cd = config.contentDisposition { headers["Content-Disposition"] = cd }

        var status = 200
        var body = config.payload
        if config.supportsRanges, let range = request.value(forHTTPHeaderField: "Range"),
           let (s, e) = Self.parse(range, total: total) {
            status = 206
            body = config.payload.subdata(in: Int(s)..<Int(e + 1))
            headers["Content-Range"] = "bytes \(s)-\(e)/\(total)"
        }
        headers["Content-Length"] = String(body.count)
        respond(url, status, headers, request.httpMethod == "HEAD" ? Data() : body, delay: config.chunkDelay)
    }

    private func respond(_ url: URL, _ status: Int, _ headers: [String: String], _ body: Data, delay: TimeInterval = 0) {
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        var offset = 0
        let step = 64 * 1024
        while offset < body.count {
            if stopped { return }
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            let end = min(offset + step, body.count)
            client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    static func parse(_ header: String, total: Int64) -> (Int64, Int64)? {
        let spec = header.replacingOccurrences(of: "bytes=", with: "")
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let s = Int64(parts[0]) else { return nil }
        let e = Int64(parts[1]).map { min($0, total - 1) } ?? total - 1
        return s <= e ? (s, e) : nil
    }
}

private func makePayload(_ size: Int) -> Data {
    var data = Data(count: size)
    data.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
        for i in 0..<size { buf[i] = UInt8(truncatingIfNeeded: (i &* 31) ^ (i >> 8)) }
    }
    return data
}

private func makeEngine() -> (DownloadEngine, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("macidm-tests-\(UUID().uuidString)")
    let config = EngineConfig(retries: 3, downloadsRoot: root.appendingPathComponent("Downloads"),
                              partsRoot: root.appendingPathComponent("parts"), minSplitSize: 64 * 1024,
                              bufferSize: 32 * 1024)
    return (DownloadEngine(config: config, session: MockServer.session()), root)
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}

@Suite struct EngineTests {
    @Test func segmentedDownloadProducesIdenticalFile() async throws {
        let payload = makePayload(3_000_000 + 17)
        MockServer.register("ranges.mock", .init(payload: payload, contentDisposition: #"attachment; filename="data.bin""#))
        let (engine, root) = makeEngine()
        defer { try? FileManager.default.removeItem(at: root) }

        let item = DownloadItem(url: URL(string: "https://ranges.mock/x")!, requestedSegments: 8)
        await engine.start(item) { _ in }
        let result = try #require(await engine.wait(item.id))

        #expect(result.status == .completed, "\(result.errorMessage ?? "")")
        #expect(result.fileName == "data.bin")
        #expect(result.segments.count >= 8)
        let saved = try #require(result.savedPath)
        #expect(saved.deletingLastPathComponent().lastPathComponent == "Other")
        #expect(try Data(contentsOf: saved) == payload)
    }

    @Test func fallsBackToSingleStreamWhenRangeIgnored() async throws {
        let payload = makePayload(2_000_000)
        // Advertises ranges but always answers 200 with the whole body.
        MockServer.register("liar.mock", .init(payload: payload, supportsRanges: false, advertiseRanges: true))
        let (engine, root) = makeEngine()
        defer { try? FileManager.default.removeItem(at: root) }

        let item = DownloadItem(url: URL(string: "https://liar.mock/file.zip")!, requestedSegments: 8)
        await engine.start(item) { _ in }
        let result = try #require(await engine.wait(item.id))
        #expect(result.status == .completed, "\(result.errorMessage ?? "")")
        #expect(result.segments.count == 1)
        #expect(!result.acceptsRanges)
        #expect(try Data(contentsOf: result.savedPath!) == payload)
        #expect(result.savedPath!.deletingLastPathComponent().lastPathComponent == "Archives")
    }

    @Test func retriesTransientServerErrors() async throws {
        let payload = makePayload(1_000_000)
        MockServer.register("flaky.mock", .init(payload: payload, failFirstRequests: 2))
        let (engine, root) = makeEngine()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = DownloadItem(url: URL(string: "https://flaky.mock/a.mp4")!, requestedSegments: 4)
        await engine.start(item) { _ in }
        let result = try #require(await engine.wait(item.id))
        #expect(result.status == .completed, "\(result.errorMessage ?? "")")
        #expect(try Data(contentsOf: result.savedPath!) == payload)
    }

    @Test func pauseThenResumeKeepsProgress() async throws {
        let payload = makePayload(4_000_000)
        MockServer.register("slow.mock", .init(payload: payload, chunkDelay: 0.01))
        let (engine, root) = makeEngine()
        defer { try? FileManager.default.removeItem(at: root) }

        let latest = Box<DownloadItem?>(nil)
        let item = DownloadItem(url: URL(string: "https://slow.mock/big.iso")!, requestedSegments: 4)
        await engine.start(item) { latest.set($0) }
        try await Task.sleep(nanoseconds: 400_000_000)
        await engine.pause(item.id)
        let paused = try #require(latest.get())
        #expect(paused.status == .paused)
        let partial = paused.downloadedBytes
        #expect(partial > 0 && partial < Int64(payload.count))

        MockServer.update("slow.mock") { $0.chunkDelay = 0 }
        await engine.start(paused) { latest.set($0) }
        let result = try #require(await engine.wait(item.id))
        #expect(result.status == .completed, "\(result.errorMessage ?? "")")
        #expect(try Data(contentsOf: result.savedPath!) == payload)
    }

    @Test func restartsWhenETagChanges() async throws {
        let original = makePayload(2_000_000)
        MockServer.register("etag.mock", .init(payload: original, chunkDelay: 0.01))
        let (engine, root) = makeEngine()
        defer { try? FileManager.default.removeItem(at: root) }

        let latest = Box<DownloadItem?>(nil)
        let item = DownloadItem(url: URL(string: "https://etag.mock/f.bin")!, requestedSegments: 4)
        await engine.start(item) { latest.set($0) }
        try await Task.sleep(nanoseconds: 300_000_000)
        await engine.pause(item.id)
        let paused = try #require(latest.get())
        #expect(paused.status == .paused)

        var changed = original
        changed.replaceSubrange(0..<4, with: Data([9, 9, 9, 9]))
        MockServer.update("etag.mock") { $0.payload = changed; $0.etag = "\"v2\""; $0.chunkDelay = 0 }
        await engine.start(paused) { _ in }
        let result = try #require(await engine.wait(item.id))
        #expect(result.status == .completed)
        #expect(result.etag == "\"v2\"")
        #expect(try Data(contentsOf: result.savedPath!) == changed)
    }

    @Test func emptyFileDownloads() async throws {
        MockServer.register("empty.mock", .init(payload: Data()))
        let (engine, root) = makeEngine()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = DownloadItem(url: URL(string: "https://empty.mock/empty.txt")!)
        await engine.start(item) { _ in }
        let result = try #require(await engine.wait(item.id))
        #expect(result.status == .completed)
        #expect(try Data(contentsOf: result.savedPath!).isEmpty)
    }
}
