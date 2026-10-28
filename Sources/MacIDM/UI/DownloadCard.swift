import MacIDMCore
import SwiftUI

extension MacIDMCore.Category {
    /// Accent for the category's icon tile.
    var tint: Color {
        switch self {
        case .video: return Color(red: 0.55, green: 0.36, blue: 0.96)
        case .music: return Color(red: 0.95, green: 0.32, blue: 0.52)
        case .documents: return Color(red: 0.20, green: 0.55, blue: 0.98)
        case .archives: return Color(red: 0.98, green: 0.60, blue: 0.20)
        case .programs: return Color(red: 0.24, green: 0.74, blue: 0.45)
        case .other: return Color(red: 0.55, green: 0.58, blue: 0.64)
        }
    }
}

/// Rounded, gradient icon tile used in the list and sidebar.
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 38

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.7)], startPoint: .top, endPoint: .bottom))
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.44, weight: .semibold)).foregroundStyle(.white))
            .frame(width: size, height: size)
            .shadow(color: tint.opacity(0.25), radius: 3, y: 1)
    }
}

/// One download in the main list: icon, name, status line, slim segment bar and quick actions.
struct DownloadCard: View {
    @EnvironmentObject private var state: AppState
    let item: DownloadItem
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(item.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                if showsBar {
                    SegmentBar(item: item, height: 5)
                }
                subtitle
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(.vertical, 6)
        .padding(.leading, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var showsBar: Bool {
        item.status != .completed && item.status != .cancelled && !(item.totalSize == nil && item.segments.isEmpty)
    }

    private var subtitle: some View {
        HStack(spacing: 6) {
            statusPill
            ForEach(details, id: \.self) { part in
                Text("·").foregroundStyle(.tertiary)
                Text(part)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
    }

    private var details: [String] {
        var parts: [String] = []
        switch item.status {
        case .downloading, .merging:
            if let total = item.totalSize { parts.append("\(Format.bytes(item.downloadedBytes)) of \(Format.bytes(total))") }
            else { parts.append(Format.bytes(item.downloadedBytes)) }
            if item.speed > 0 { parts.append(Format.speed(item.speed)) }
            if let eta = item.eta { parts.append("\(Format.duration(eta)) left") }
        case .completed:
            if let total = item.totalSize { parts.append(Format.bytes(total)) }
            if let date = item.dateCompleted { parts.append(date.formatted(.relative(presentation: .named))) }
        case .failed:
            if let e = item.errorMessage { parts.append(e) }
        default:
            if let total = item.totalSize, let p = item.progress {
                parts.append("\(Int(p * 100))% of \(Format.bytes(total))")
            }
        }
        return parts
    }

    private var statusPill: some View {
        let (text, color): (String, Color) = {
            switch item.status {
            case .queued: return ("Queued", .gray)
            case .probing: return ("Connecting", .blue)
            case .downloading: return (item.progress.map { "\(Int($0 * 100))%" } ?? "Downloading", .blue)
            case .merging: return ("Finishing", .blue)
            case .paused: return (item.errorMessage == nil ? "Paused" : "Needs attention", item.errorMessage == nil ? .orange : .red)
            case .completed: return ("Done", .green)
            case .failed: return ("Failed", .red)
            case .cancelled: return ("Stopped", .gray)
            }
        }()
        return Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 4) {
            switch item.status {
            case .completed:
                circleButton("magnifyingglass", "Show in Finder") { state.reveal(item.id) }
                circleButton("arrow.up.forward.app", "Open") { state.open(item.id) }
            case .downloading, .probing, .merging, .queued:
                circleButton("pause.fill", "Pause") { state.pause([item.id]) }
                circleButton("info", "Details") { state.showProgressWindow(item.id) }
            default:
                circleButton("play.fill", "Resume") { state.resume([item.id]) }
                circleButton("info", "Details") { state.showProgressWindow(item.id) }
            }
        }
        .opacity(hovering || item.status.isActive ? 1 : 0.35)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private func circleButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 26, height: 26)
                .background(.quaternary, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Shown when the current view has no downloads.
struct EmptyDownloadsView: View {
    let filtered: Bool
    let add: () -> Void
    let grab: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            IconTile(symbol: "arrow.down", tint: .accentColor, size: 64)
            Text(filtered ? "Nothing here" : "No downloads yet")
                .font(.title2.weight(.semibold))
            Text(filtered ? "Downloads in this list will show up here."
                          : "Paste a link, grab a video, or drop links onto this window.\nDownloads from your browser appear here too.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if !filtered {
                HStack {
                    Button(action: add) { Label("Add URL", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                    Button(action: grab) { Label("Grab Video", systemImage: "play.rectangle") }
                }
                .controlSize(.large)
                .padding(.top, 4)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Bottom bar: live totals across all downloads.
struct StatusBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 14) {
            let active = state.activeItems.count
            Label(active == 0 ? "Idle" : "\(active) downloading", systemImage: active == 0 ? "moon.zzz" : "arrow.down.circle.fill")
                .foregroundStyle(active == 0 ? Color.secondary : Color.accentColor)
            if active > 0 {
                Text(Format.speed(state.totalSpeed)).monospacedDigit().fontWeight(.medium)
            }
            if state.queuedCount > 0 {
                Label("\(state.queuedCount) queued", systemImage: "clock").foregroundStyle(.secondary)
            }
            Spacer()
            if state.scheduledRunActive {
                Label("Scheduled run", systemImage: "calendar.badge.clock").foregroundStyle(.secondary)
            }
            Text("\(state.items.filter { $0.status == .completed }.count) completed").foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
