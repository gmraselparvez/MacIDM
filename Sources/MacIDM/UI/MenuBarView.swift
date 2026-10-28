import AppKit
import MacIDMCore
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("MacIDM").font(.headline)
                Spacer()
                if !state.activeItems.isEmpty {
                    Text(Format.speed(state.totalSpeed)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if state.activeItems.isEmpty {
                Text(state.queuedCount > 0 ? "\(state.queuedCount) queued" : "No active downloads")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(state.activeItems.prefix(6)) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(item.displayName).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(item.eta.map(Format.duration) ?? "").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        ProgressCell(item: item)
                    }
                }
                if state.activeItems.count > 6 {
                    Text("+\(state.activeItems.count - 6) more").font(.caption).foregroundStyle(.secondary)
                }
                if state.queuedCount > 0 {
                    Text("\(state.queuedCount) queued").font(.caption).foregroundStyle(.secondary)
                }
            }
            if state.scheduledRunActive {
                Label("Scheduled run in progress", systemImage: "clock").font(.caption)
            }
            Divider()
            HStack {
                Button("Open MacIDM") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button { state.resumeAll() } label: { Image(systemName: "play.fill") }.help("Resume all")
                Button { state.pauseAll() } label: { Image(systemName: "pause.fill") }.help("Pause all")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Quit")
            }
        }
        .padding(12)
        .frame(width: 320)
    }
}
