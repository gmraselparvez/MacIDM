import Foundation
import UniformTypeIdentifiers

public enum FileNaming {
    /// `Content-Disposition` → URL path → `download-<timestamp>`.
    public static func fileName(contentDisposition: String?, url: URL, mimeType: String? = nil, now: Date = Date()) -> String {
        if let cd = contentDisposition, let name = parseContentDisposition(cd).map(sanitize), !name.isEmpty {
            return name
        }
        let last = url.lastPathComponent
        if !last.isEmpty, last != "/" {
            var name = sanitize(last)
            if !name.isEmpty {
                if (name as NSString).pathExtension.isEmpty, let ext = mimeType.flatMap(fileExtension(forMIME:)) {
                    name += ".\(ext)"
                }
                return name
            }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var name = "download-\(formatter.string(from: now))"
        if let ext = mimeType.flatMap(fileExtension(forMIME:)) { name += ".\(ext)" }
        return name
    }

    /// Extracts the file name from a `Content-Disposition` header, preferring RFC 5987 `filename*`.
    public static func parseContentDisposition(_ value: String) -> String? {
        if let encoded = firstMatch(#"filename\*\s*=\s*([^']*)'[^']*'([^;]+)"#, in: value, group: 2) {
            let trimmed = encoded.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if let decoded = trimmed.removingPercentEncoding, !decoded.isEmpty { return decoded }
        }
        if let quoted = firstMatch(#"filename\s*=\s*"((?:[^"\\]|\\.)*)""#, in: value, group: 1) {
            return quoted.replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
        }
        if let bare = firstMatch(#"filename\s*=\s*([^;]+)"#, in: value, group: 1) {
            let name = bare.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        return nil
    }

    /// Removes path separators and control characters so the name is safe on disk.
    public static func sanitize(_ name: String) -> String {
        var cleaned = (name as NSString).lastPathComponent
        cleaned = cleaned.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        cleaned = String(cleaned.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.utf8.count > 255 {
            let ext = (cleaned as NSString).pathExtension
            let stem = (cleaned as NSString).deletingPathExtension
            cleaned = String(stem.prefix(200)) + (ext.isEmpty ? "" : ".\(ext)")
        }
        return cleaned
    }

    /// Returns `dir/name`, or `dir/name (1).ext`, `(2)`… if that already exists.
    public static func uniqueURL(for name: String, in dir: URL, fileManager: FileManager = .default) -> URL {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var candidate = dir.appendingPathComponent(name)
        var n = 1
        while fileManager.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            candidate = dir.appendingPathComponent(numbered)
            n += 1
        }
        return candidate
    }

    static func fileExtension(forMIME mime: String) -> String? {
        let base = mime.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? mime
        guard base != "application/octet-stream" else { return nil }
        return UTType(mimeType: base)?.preferredFilenameExtension
    }

    private static func firstMatch(_ pattern: String, in string: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              let range = Range(match.range(at: group), in: string) else { return nil }
        return String(string[range])
    }
}
