import Foundation

/// Saves and restores the download list (including per-segment progress) as JSON.
public final class DownloadStore: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL = DownloadStore.appSupportDir.appendingPathComponent("downloads.json")) {
        self.fileURL = fileURL
    }

    public static var appSupportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacIDM", isDirectory: true)
    }

    /// Items that were mid-download when the app quit come back as paused.
    public func load() -> [DownloadItem] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var items = try? decoder.decode([DownloadItem].self, from: data) else { return [] }
        for i in items.indices where items[i].status.isActive {
            items[i].status = .paused
        }
        return items
    }

    public func save(_ items: [DownloadItem]) throws {
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(items)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
