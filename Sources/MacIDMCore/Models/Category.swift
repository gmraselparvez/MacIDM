import Foundation

public enum Category: String, Codable, CaseIterable, Identifiable, Sendable {
    case video = "Video"
    case music = "Music"
    case documents = "Documents"
    case archives = "Archives"
    case programs = "Programs"
    case other = "Other"

    public var id: String { rawValue }

    public var symbolName: String {
        switch self {
        case .video: return "film"
        case .music: return "music.note"
        case .documents: return "doc.text"
        case .archives: return "archivebox"
        case .programs: return "app.badge"
        case .other: return "folder"
        }
    }

    private static let extensions: [Category: Set<String>] = [
        .video: ["mp4", "mkv", "mov", "avi", "webm", "m4v", "flv", "wmv", "mpg", "mpeg", "3gp", "ts"],
        .music: ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "wma", "aiff", "alac"],
        .documents: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "epub", "csv",
                     "pages", "numbers", "key", "odt", "md", "jpg", "jpeg", "png", "gif", "webp", "heic", "svg"],
        .archives: ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "iso", "img"],
        .programs: ["dmg", "pkg", "app", "exe", "msi", "deb", "rpm", "apk", "appimage", "jar"],
    ]

    public static func from(fileName: String) -> Category {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return .other }
        for (category, exts) in extensions where exts.contains(ext) {
            return category
        }
        return .other
    }
}
