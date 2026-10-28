import Foundation

public enum BatchPatternError: Error, LocalizedError, Equatable {
    case invalidRange(String)
    case tooMany(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidRange(let r): return "“[\(r)]” isn't a valid range. Use [1-100], [001-100] or [a-z]."
        case .tooMany(let n): return "That pattern makes \(n) links; the limit is \(BatchPattern.maxURLs)."
        }
    }
}

/// Expands `file[001-100].jpg` style patterns. Zero padding follows the start value; several
/// ranges multiply out (`s[1-2]e[01-10]` gives 20 links). Letters work too: `[a-f]`.
public enum BatchPattern {
    public static let maxURLs = 10_000

    public static func expand(_ pattern: String) throws -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\[([^\[\]]+)\]"#),
              let match = regex.firstMatch(in: pattern, range: NSRange(pattern.startIndex..., in: pattern)),
              let whole = Range(match.range, in: pattern), let inner = Range(match.range(at: 1), in: pattern) else {
            return [pattern]
        }
        let values = try values(for: String(pattern[inner]))
        let head = String(pattern[..<whole.lowerBound])
        let tails = try expand(String(pattern[whole.upperBound...]))
        let total = values.count * tails.count
        guard total <= maxURLs else { throw BatchPatternError.tooMany(total) }
        return values.flatMap { v in tails.map { head + v + $0 } }
    }

    static func values(for range: String) throws -> [String] {
        let parts = range.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { throw BatchPatternError.invalidRange(range) }
        if let a = Int(parts[0]), let b = Int(parts[1]) {
            guard abs(b - a) < maxURLs else { throw BatchPatternError.tooMany(abs(b - a) + 1) }
            let width = parts[0].hasPrefix("0") && parts[0].count > 1 ? parts[0].count : 0
            let seq = a <= b ? Array(a...b) : Array((b...a).reversed())
            return seq.map { width > 0 ? String(format: "%0\(width)d", $0) : String($0) }
        }
        if parts[0].count == 1, parts[1].count == 1,
           let a = parts[0].unicodeScalars.first, let b = parts[1].unicodeScalars.first,
           a.properties.isAlphabetic, b.properties.isAlphabetic, a.value <= b.value {
            return (a.value...b.value).compactMap { Unicode.Scalar($0).map { String(Character($0)) } }
        }
        throw BatchPatternError.invalidRange(range)
    }

    /// Links from pasted text: one per line, each line may itself be a pattern. Keeps order, drops duplicates.
    public static func links(from text: String) throws -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            for s in try expand(trimmed) where seen.insert(s).inserted {
                if let url = URL(string: s), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
                    result.append(url)
                }
                guard result.count <= maxURLs else { throw BatchPatternError.tooMany(result.count) }
            }
        }
        return result
    }
}

/// Exports and imports the download list.
public enum ListTransfer {
    public struct ExportedItem: Codable, Equatable {
        public var url: String
        public var fileName: String?
        public var status: String
        public var savedPath: String?
        public var media: MediaRequest?
    }

    public struct ExportFile: Codable {
        public var app = "MacIDM"
        public var version = 1
        public var exportedAt: Date
        public var downloads: [ExportedItem]
    }

    /// JSON export. Never includes cookies or other request headers.
    public static func exportJSON(_ items: [DownloadItem], now: Date = Date()) throws -> Data {
        let file = ExportFile(exportedAt: now, downloads: items.map {
            ExportedItem(url: $0.url.absoluteString, fileName: $0.fileName.isEmpty ? nil : $0.fileName,
                         status: $0.status.rawValue, savedPath: $0.savedPath?.path, media: $0.media)
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(file)
    }

    public static func exportText(_ items: [DownloadItem]) -> String {
        items.map(\.url.absoluteString).joined(separator: "\n") + "\n"
    }

    /// Accepts a MacIDM JSON export or plain text with one link (or pattern) per line.
    /// Returns new items to queue; completed downloads are not re-downloaded.
    public static func importItems(from data: Data, requestedSegments: Int) throws -> [DownloadItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let file = try? decoder.decode(ExportFile.self, from: data) {
            return file.downloads.compactMap { e in
                guard e.status != DownloadStatus.completed.rawValue, let url = URL(string: e.url) else { return nil }
                var item = DownloadItem(url: url, fileName: FileNaming.sanitize(e.fileName ?? ""), requestedSegments: requestedSegments)
                item.media = e.media
                if let media = e.media { item.category = media.choice.isAudio ? .music : .video }
                return item
            }
        }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return try BatchPattern.links(from: text).map { DownloadItem(url: $0, requestedSegments: requestedSegments) }
    }
}
