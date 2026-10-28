import Foundation

/// A download handed over by the browser extension.
public struct BrowserRequest: Codable, Equatable, Sendable {
    public var type: String
    public var url: String
    public var referrer: String?
    /// `Cookie` header value for `url` only, as the browser would send it.
    public var cookies: String?
    public var userAgent: String?
    public var fileName: String?
    /// For "media": a MediaChoice code picked from the on-page quality menu ("video:720", "audio:mp3").
    public var choice: String?
    /// For "formats": the helper waits for the app's answer under this id.
    public var requestID: String?
    /// For "batch": many files (e.g. images picked on a page); `url` is the page they came from.
    public var urls: [String]?

    public init(url: String, referrer: String? = nil, cookies: String? = nil, userAgent: String? = nil, fileName: String? = nil) {
        self.type = "download"
        self.url = url
        self.referrer = referrer
        self.cookies = cookies
        self.userAgent = userAgent
        self.fileName = fileName
    }

    /// A video page (YouTube etc.) for the video grabber rather than a direct file.
    public var isMedia: Bool { type == "media" }

    /// For "batch": the http(s) links, de-duplicated, at most 5,000.
    public var batchURLs: [URL] {
        var seen = Set<String>()
        return (urls ?? []).compactMap { s -> URL? in
            guard seen.insert(s).inserted, let u = URL(string: s), ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
                  u.host != nil else { return nil }
            return u
        }.prefix(5_000).map { $0 }
    }

    /// Validates the request and turns it into extra HTTP headers. Returns nil for anything unsafe.
    public func validated() -> (url: URL, headers: [String: String], fileName: String)? {
        guard ["download", "media", "formats", "batch", "pinterest"].contains(type), let url = URL(string: url),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { return nil }
        var headers: [String: String] = [:]
        func add(_ name: String, _ value: String?) {
            guard let value, !value.isEmpty, value.count < 16_384,
                  // Check scalars, not Characters: "\r\n" is a single Character in Swift.
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return }
            headers[name] = value
        }
        if let ref = referrer, let refURL = URL(string: ref), ["http", "https"].contains(refURL.scheme?.lowercased() ?? "") {
            add("Referer", ref)
        }
        add("Cookie", cookies)
        add("User-Agent", userAgent)
        return (url, headers, FileNaming.sanitize(fileName ?? ""))
    }
}

/// Chrome native messaging framing: 4-byte native-endian (little-endian on Mac) length, then UTF-8 JSON.
public enum NativeMessaging {
    public static let maxIncoming = 1024 * 1024

    public static func frame(_ json: Data) -> Data {
        var length = UInt32(json.count).littleEndian
        return Data(bytes: &length, count: 4) + json
    }

    /// Length of the message whose 4-byte header is `header`.
    public static func length(of header: Data) -> Int? {
        guard header.count == 4 else { return nil }
        let value = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return Int(UInt32(littleEndian: value))
    }
}

/// Folder where the native host drops requests for the app to pick up (works even if the app isn't running yet).
public struct Inbox: Sendable {
    public static let notificationName = "com.macidm.app.inbox"
    public let dir: URL

    public init(dir: URL = DownloadStore.appSupportDir.appendingPathComponent("Inbox", isDirectory: true)) {
        self.dir = dir
    }

    public func write(_ request: BrowserRequest) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(request)
        let tmp = dir.appendingPathComponent(".\(UUID().uuidString).tmp")
        // Owner-only: the file may carry cookies.
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.moveItem(at: tmp, to: dir.appendingPathComponent("\(Date().timeIntervalSince1970)-\(UUID().uuidString).json"))
    }

    private var responsesDir: URL { dir.appendingPathComponent("responses", isDirectory: true) }

    public func writeResponse(_ data: Data, id: String) throws {
        try FileManager.default.createDirectory(at: responsesDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let tmp = responsesDir.appendingPathComponent(".\(id).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let final = responsesDir.appendingPathComponent("\(Self.safe(id)).json")
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: tmp, to: final)
    }

    /// Returns and deletes the response for `id`, if the app has written it.
    public func takeResponse(id: String) -> Data? {
        let file = responsesDir.appendingPathComponent("\(Self.safe(id)).json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        try? FileManager.default.removeItem(at: file)
        return data
    }

    static func safe(_ id: String) -> String { String(id.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(64)) }

    /// Reads and deletes all pending requests, oldest first.
    public func drain() -> [BrowserRequest] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return files.compactMap { file in
            defer { try? FileManager.default.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? JSONDecoder().decode(BrowserRequest.self, from: data)
        }
    }
}

/// Registers the native messaging host with Chromium-based browsers.
public struct NativeHostInstaller: Sendable {
    public static let hostName = "com.macidm.host"
    /// Fixed by the `key` in BrowserExtension/chrome/manifest.json.
    public static let extensionID = "hmjonefkfhiehppllmijhjlmcnnhacnk"

    public struct Browser: Identifiable, Hashable, Sendable {
        public let name: String
        /// Path under ~/Library/Application Support.
        public let supportPath: String
        public var id: String { name }
    }

    public static let browsers = [
        Browser(name: "Google Chrome", supportPath: "Google/Chrome"),
        Browser(name: "Microsoft Edge", supportPath: "Microsoft Edge"),
        Browser(name: "Brave", supportPath: "BraveSoftware/Brave-Browser"),
        Browser(name: "Chromium", supportPath: "Chromium"),
    ]

    public let applicationSupport: URL

    public init(applicationSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) {
        self.applicationSupport = applicationSupport
    }

    public func manifestURL(for browser: Browser) -> URL {
        applicationSupport.appendingPathComponent(browser.supportPath)
            .appendingPathComponent("NativeMessagingHosts/\(Self.hostName).json")
    }

    public func isBrowserPresent(_ browser: Browser) -> Bool {
        FileManager.default.fileExists(atPath: applicationSupport.appendingPathComponent(browser.supportPath).path)
    }

    public func isInstalled(_ browser: Browser, hostPath: URL) -> Bool {
        guard let data = try? Data(contentsOf: manifestURL(for: browser)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return json["path"] as? String == hostPath.path
    }

    public static func manifest(hostPath: URL) throws -> Data {
        let object: [String: Any] = [
            "name": hostName,
            "description": "MacIDM download manager",
            "path": hostPath.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"],
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    public func install(_ browser: Browser, hostPath: URL) throws {
        let url = manifestURL(for: browser)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.manifest(hostPath: hostPath).write(to: url, options: .atomic)
    }

    /// True if the MacIDM extension appears in any profile of this browser.
    public func isExtensionInstalled(_ browser: Browser) -> Bool {
        let root = applicationSupport.appendingPathComponent(browser.supportPath)
        guard let profiles = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return false }
        let needle = Data(Self.extensionID.utf8)
        return profiles.contains { profile in
            ["Secure Preferences", "Preferences"].contains { name in
                (try? Data(contentsOf: profile.appendingPathComponent(name)))?.range(of: needle) != nil
            }
        }
    }

    /// Re-points existing registrations at `hostPath` (e.g. after the app moved). Returns browsers updated.
    @discardableResult
    public func refreshInstalled(hostPath: URL) -> [Browser] {
        Self.browsers.filter { b in
            FileManager.default.fileExists(atPath: manifestURL(for: b).path) && !isInstalled(b, hostPath: hostPath)
                && (try? install(b, hostPath: hostPath)) != nil
        }
    }

    public func uninstall(_ browser: Browser) throws {
        let url = manifestURL(for: browser)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

/// Records when the extension last checked in from each browser. The extension sends "hello"
/// when it's installed or the browser starts; browsers' own profile data is off-limits to other apps.
public struct ExtensionHeartbeat: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = DownloadStore.appSupportDir.appendingPathComponent("extension-seen.json")) {
        self.fileURL = fileURL
    }

    public func all() -> [String: Date] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: Date].self, from: data)) ?? [:]
    }

    public func lastSeen(_ browser: String) -> Date? { all()[browser] }

    public func record(_ browser: String, at date: Date = Date()) throws {
        var seen = all()
        seen[browser] = date
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(seen).write(to: fileURL, options: .atomic)
    }

    /// Which browser launched the host, from its executable path.
    public static func browserName(forProcessPath path: String) -> String? {
        let names: [(String, String)] = [("Microsoft Edge", "Microsoft Edge"), ("Brave Browser", "Brave"),
                                         ("Chromium", "Chromium"), ("Google Chrome", "Google Chrome")]
        return names.first { path.contains($0.0) }?.1
    }
}
