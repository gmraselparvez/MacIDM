import MacIDMCore
import SwiftUI

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func speed(_ bps: Double) -> String {
        bps > 0 ? bytes(Int64(bps)) + "/s" : "—"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "—" }
        let s = Int(seconds.rounded())
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// IDM-style bar: each segment's downloaded range drawn at its position in the file.
struct SegmentBar: View {
    let item: DownloadItem
    var height: CGFloat = 8

    private static let palette: [Color] = [.blue, .teal, .indigo, .cyan]

    var body: some View {
        Canvas { context, size in
            let bg = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 2)
            context.fill(bg, with: .color(.secondary.opacity(0.2)))
            guard let total = item.totalSize, total > 0 else { return }
            let scale = size.width / CGFloat(total)
            if item.status == .completed {
                context.fill(bg, with: .color(.green))
                return
            }
            for seg in item.segments where seg.downloaded > 0 {
                let rect = CGRect(x: CGFloat(seg.start) * scale, y: 0,
                                  width: max(1, CGFloat(seg.downloaded) * scale), height: size.height)
                let color = Self.palette[seg.index % Self.palette.count]
                context.fill(Path(rect), with: .color(item.status == .failed ? .red : color))
            }
            // Thin separators at segment boundaries.
            for seg in item.segments where seg.start > 0 {
                let x = CGFloat(seg.start) * scale
                context.fill(Path(CGRect(x: x, y: 0, width: 0.5, height: size.height)), with: .color(.primary.opacity(0.25)))
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}

struct ProgressCell: View {
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 6) {
            if item.totalSize == nil && item.status == .downloading {
                ProgressView().progressViewStyle(.linear)
                Text(Format.bytes(item.downloadedBytes)).font(.caption).monospacedDigit()
            } else {
                SegmentBar(item: item)
                Text(item.progress.map { String(format: "%.0f%%", $0 * 100) } ?? "")
                    .font(.caption).monospacedDigit().frame(width: 34, alignment: .trailing)
            }
        }
    }
}

struct StatusLabel: View {
    let item: DownloadItem

    var body: some View {
        switch item.status {
        case .queued: Text("Queued").foregroundStyle(.secondary)
        case .probing: Text("Connecting…").foregroundStyle(.secondary)
        case .downloading: Text("Downloading")
        case .merging: Text("Merging…")
        case .paused: Text(item.errorMessage == nil ? "Paused" : "Paused (error)").foregroundStyle(item.errorMessage == nil ? .orange : .red)
        case .completed: Text("Completed").foregroundStyle(.green)
        case .failed: Text("Failed").foregroundStyle(.red).help(item.errorMessage ?? "")
        case .cancelled: Text("Stopped").foregroundStyle(.secondary)
        }
    }
}

/// Bottom panel for the selected download: URL, path, segment map and connections.
struct DownloadDetail: View {
    @EnvironmentObject private var state: AppState
    let item: DownloadItem
    @State private var newURL = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.displayName).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("\(Format.bytes(item.downloadedBytes)) of \(item.totalSize.map(Format.bytes) ?? "unknown")")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            SegmentBar(item: item, height: 16)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text("URL").foregroundStyle(.secondary)
                    Text(item.url.absoluteString).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                if let saved = item.savedPath {
                    GridRow {
                        Text("Saved to").foregroundStyle(.secondary)
                        Text(saved.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                }
                GridRow {
                    Text("Connections").foregroundStyle(.secondary)
                    Text(connectionsText)
                }
                if let error = item.errorMessage {
                    GridRow {
                        Text("Error").foregroundStyle(.secondary)
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .font(.callout)
            if item.status == .failed || (item.status == .paused && item.errorMessage != nil) {
                HStack {
                    TextField("Paste a refreshed URL to continue", text: $newURL)
                        .textFieldStyle(.roundedBorder)
                    Button("Update URL & Resume") { state.updateURL(item.id, to: newURL); newURL = "" }
                        .disabled(URL(string: newURL)?.host == nil)
                    Button("Retry") { state.retry([item.id]) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private var connectionsText: String {
        let total = item.segments.count
        let done = item.segments.filter(\.isComplete).count
        if total == 0 { return "—" }
        let mode = item.acceptsRanges ? "segmented" : "single stream (resume not guaranteed)"
        return "\(done)/\(total) segments complete · \(mode)"
    }
}
