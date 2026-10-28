import Foundation
import Testing
@testable import MacIDMCore

@Suite struct BrowserBridgeTests {
    @Test func validatesAndBuildsHeaders() throws {
        let r = BrowserRequest(url: "https://files.example.com/a.zip", referrer: "https://example.com/page",
                               cookies: "session=abc; theme=dark", userAgent: "UA/1.0", fileName: "../a.zip")
        let v = try #require(r.validated())
        #expect(v.url.host == "files.example.com")
        #expect(v.headers == ["Referer": "https://example.com/page", "Cookie": "session=abc; theme=dark", "User-Agent": "UA/1.0"])
        #expect(v.fileName == "a.zip")
    }

    @Test func rejectsUnsafeInput() {
        #expect(BrowserRequest(url: "file:///etc/passwd").validated() == nil)
        #expect(BrowserRequest(url: "javascript:alert(1)").validated() == nil)
        var bad = BrowserRequest(url: "https://e.com/a.zip")
        bad.type = "exec"
        #expect(bad.validated() == nil)
        // Header injection is dropped, the download itself is still allowed.
        let injected = BrowserRequest(url: "https://e.com/a.zip", referrer: "chrome://settings", cookies: "a=b\r\nX-Evil: 1")
        #expect(injected.validated()?.headers.isEmpty == true)
    }

    @Test func nativeMessagingFraming() {
        let json = Data(#"{"type":"ping"}"#.utf8)
        let framed = NativeMessaging.frame(json)
        #expect(framed.count == json.count + 4)
        #expect(Array(framed.prefix(4)) == [15, 0, 0, 0])
        #expect(NativeMessaging.length(of: framed.prefix(4)) == 15)
        #expect(NativeMessaging.length(of: Data([1, 2])) == nil)
    }

    @Test func inboxRoundTripWithPrivatePermissions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inbox = Inbox(dir: dir)
        try inbox.write(BrowserRequest(url: "https://e.com/1.zip", cookies: "s=1"))
        try inbox.write(BrowserRequest(url: "https://e.com/2.zip"))
        let file = try #require(try FileManager.default.contentsOfDirectory(atPath: dir.path).first { $0.hasSuffix(".json") })
        let perms = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(file).path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        let drained = inbox.drain()
        #expect(drained.map(\.url) == ["https://e.com/1.zip", "https://e.com/2.zip"])
        #expect(inbox.drain().isEmpty)
    }

    @Test func installerWritesManifestForPinnedExtension() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = NativeHostInstaller(applicationSupport: root)
        let chrome = NativeHostInstaller.browsers[0]
        let host = URL(fileURLWithPath: "/Applications/MacIDM.app/Contents/MacOS/MacIDMHost")
        #expect(!installer.isInstalled(chrome, hostPath: host))
        try installer.install(chrome, hostPath: host)
        #expect(installer.manifestURL(for: chrome).path.hasSuffix("Google/Chrome/NativeMessagingHosts/com.macidm.host.json"))
        #expect(installer.isInstalled(chrome, hostPath: host))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: installer.manifestURL(for: chrome))) as! [String: Any]
        #expect(json["allowed_origins"] as? [String] == ["chrome-extension://hmjonefkfhiehppllmijhjlmcnnhacnk/"])
        #expect(json["type"] as? String == "stdio")
        try installer.uninstall(chrome)
        #expect(!installer.isInstalled(chrome, hostPath: host))
    }

    @Test func extensionKeyMatchesPinnedID() throws {
        // The manifest "key" must hash to NativeHostInstaller.extensionID or Chrome will refuse the host.
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BrowserExtension/chrome/manifest.json")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        let der = try #require(Data(base64Encoded: manifest["key"] as! String))
        let id = try #require(chromeExtensionID(publicKeyDER: der))
        #expect(id == NativeHostInstaller.extensionID)
    }

    private func chromeExtensionID(publicKeyDER: Data) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        p.arguments = ["-a", "256"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        try? p.run()
        input.fileHandleForWriting.write(publicKeyDER)
        try? input.fileHandleForWriting.close()
        p.waitUntilExit()
        guard let hex = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.prefix(32) else { return nil }
        let map = Array("abcdefghijklmnop")
        return String(hex.compactMap { $0.hexDigitValue.map { map[$0] } })
    }
}

@Suite struct BrowserHeaderEngineTests {
    @Test func sendsBrowserCookiesOnEveryRequest() async throws {
        let payload = Data((0..<1_500_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        MockServer.register("cookie.mock", .init(payload: payload, requiredCookie: "session=xyz"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = DownloadEngine(config: EngineConfig(downloadsRoot: root, partsRoot: root.appendingPathComponent("p"),
                                                         minSplitSize: 64 * 1024),
                                    session: MockServer.session())
        var item = DownloadItem(url: URL(string: "https://cookie.mock/private.zip")!, requestedSegments: 4)
        item.headers = ["Cookie": "session=xyz", "Referer": "https://cookie.mock/"]
        await engine.start(item) { _ in }
        let result = try #require(await engine.wait(item.id))
        #expect(result.status == .completed, "\(result.errorMessage ?? "")")
        #expect(result.headers == nil)
        #expect(try Data(contentsOf: result.savedPath!) == payload)

        // Without the cookie the same server refuses.
        let anon = DownloadItem(url: URL(string: "https://cookie.mock/private.zip")!)
        await engine.start(anon) { _ in }
        #expect(await engine.wait(anon.id)?.status == .failed)
    }
}
