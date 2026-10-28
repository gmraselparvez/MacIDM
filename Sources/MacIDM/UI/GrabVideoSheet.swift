import AppKit
import MacIDMCore
import SwiftUI

/// Paste a page URL → see the available qualities → download through yt-dlp.
struct GrabVideoSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var urlString = ""
    @State private var info: MediaInfo?
    @State private var choice: MediaChoice = .best
    @State private var loading = false
    @State private var error: String?
    @State private var fetchTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Grab Video").font(.title2.bold())
            HStack {
                TextField("Page URL", text: $urlString, prompt: Text("https://www.youtube.com/watch?v=…"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(fetch)
                Button(loading ? "Fetching…" : "Fetch", action: fetch)
                    .disabled(loading || pageURL == nil || state.mediaTools.ytdlp == nil)
            }

            if state.mediaTools.ytdlp == nil {
                Label("yt-dlp isn't installed. See Settings › Media.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if loading { ProgressView().controlSize(.small) }
            if let error {
                Label(error, systemImage: "xmark.octagon").foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let info {
                HStack(alignment: .top, spacing: 12) {
                    AsyncImage(url: info.thumbnail) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle().fill(.quaternary)
                    }
                    .frame(width: 128, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(info.title).font(.headline).lineLimit(2)
                        Text([info.extractor, info.duration.map(Format.duration)].compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                    }
                }
                Picker("Quality", selection: $choice) {
                    ForEach(info.choices, id: \.self) { c in
                        Text(label(for: c, info: info)).tag(c)
                    }
                }
                if state.mediaTools.ffmpeg == nil {
                    Text("ffmpeg wasn't found, so high qualities that need merging and MP3/M4A conversion may fail.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Text("Works on sites yt-dlp supports. DRM-protected services (Netflix, Disney+, Spotify, etc.) aren't supported.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { fetchTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Download") {
                    guard let info, let url = pageURL else { return }
                    state.addMedia(url: url, choice: choice, title: info.title)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(info == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               URL(string: clip)?.host != nil, clip.lowercased().hasPrefix("http") {
                urlString = clip
            }
        }
        .onChange(of: urlString) { _ in info = nil; error = nil }
    }

    private var pageURL: URL? {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }

    private func label(for choice: MediaChoice, info: MediaInfo) -> String {
        guard let size = info.estimatedSize(for: choice) else { return choice.label }
        return "\(choice.label) — about \(Format.bytes(size))"
    }

    private func fetch() {
        guard let url = pageURL, let ytdlp = state.mediaTools.ytdlp else { return }
        loading = true
        error = nil
        info = nil
        fetchTask = Task {
            do {
                let result = try await YTDLPService.fetchInfo(url: url, ytdlp: ytdlp)
                info = result
                choice = .best
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}

struct MediaSettings: View {
    @EnvironmentObject private var state: AppState
    @State private var version: String?
    @State private var updating = false
    @State private var updateOutput: String?

    var body: some View {
        Form {
            Section("yt-dlp") {
                LabeledContent("Location", value: state.mediaTools.ytdlp?.path ?? "Not found")
                LabeledContent("Version", value: version ?? "—")
                HStack {
                    Button(updating ? "Updating…" : "Update yt-dlp", action: update)
                        .disabled(updating || state.mediaTools.ytdlp == nil)
                    if updating { ProgressView().controlSize(.small) }
                }
                if let updateOutput {
                    Text(updateOutput).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text("Sites change often; update yt-dlp if a video that used to work stops working.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("ffmpeg") {
                LabeledContent("Location", value: state.mediaTools.ffmpeg?.path ?? "Not found")
                Text("Used to merge separate video and audio streams and to convert to MP3/M4A. Install with Homebrew (brew install ffmpeg) if missing.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .task(id: state.mediaTools.ytdlp) { await loadVersion() }
    }

    private func loadVersion() async {
        guard let ytdlp = state.mediaTools.ytdlp else { version = nil; return }
        version = await YTDLPService.version(ytdlp)
    }

    private func update() {
        updating = true
        updateOutput = nil
        Task {
            do {
                updateOutput = try await YTDLPService.update(tools: state.mediaTools)
            } catch {
                updateOutput = error.localizedDescription
            }
            state.refreshMediaTools()
            await loadVersion()
            updating = false
        }
    }
}
