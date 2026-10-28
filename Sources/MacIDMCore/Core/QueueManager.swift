import Foundation

public enum QueueManager {
    /// Queued items to start now, oldest first, filling the free slots under `maxConcurrent`.
    public static func idsToStart(_ items: [DownloadItem], maxConcurrent: Int,
                                  eligible: (DownloadItem) -> Bool = { _ in true }) -> [UUID] {
        let active = items.filter { $0.status.isActive }.count
        let slots = max(0, maxConcurrent - active)
        guard slots > 0 else { return [] }
        return items
            .filter { $0.status == .queued && eligible($0) }
            .sorted { $0.dateAdded < $1.dateAdded }
            .prefix(slots)
            .map(\.id)
    }

    /// True for http(s) links that look like a file download rather than a web page.
    public static func isLikelyDownload(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return false }
        return Category.from(fileName: url.lastPathComponent) != .other
            || ["bin", "dat"].contains(url.pathExtension.lowercased())
    }
}
