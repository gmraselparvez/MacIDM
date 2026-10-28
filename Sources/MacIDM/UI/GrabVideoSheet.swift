import AppKit
import MacIDMCore
import SwiftUI

/// Paste a page URL → see the available qualities → download through yt-dlp.
struct GrabVideoSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var urlString: String
    @State private var folder: URL?
    let headers: [String: String]
    let autoFetch: Bool
    /// Set when shown as a standalone window (from the browser); nil when shown as a sheet.
    let onClose: (() -> Void)?

    init(initialURL: String = "", headers: [String: String] = [:], autoFetch: Bool = false, onClose: (() -> Void)? = nil) {
        _urlString = State(initialValue: initialURL)
        self.headers = headers
        self.autoFetch = autoFetch
        self.onClose = onClose
    }

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
                LabeledContent("Save to") {
                    HStack {
                        Text((folder ?? AppState.categoryFolder(choice.isAudio ? .music : .video)).path)
                            .lineLimit(1).truncationMode(.head)
                        Spacer()
                        if folder != nil { Button("Reset") { folder = nil } }
                        Button("Choose…", action: chooseFolder)
                    }
                }
                if state.mediaTools.ffmpeg == nil {
                    Text("ffmpeg wasn't found, so high qualities that need merging and MP3/M4A conversion may fail.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { fetchTask?.cancel(); finish() }.keyboardShortcut(.cancelAction)
                Button("Download") {
                    guard let info, let url = pageURL else { return }
                    let id = state.addMedia(url: url, choice: choice, title: info.title, folder: folder, headers: headers)
                    finish()
                    state.showProgressWindowIfEnabled(id)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(info == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            if autoFetch { fetch(); return }
            guard urlString.isEmpty else { return }
            if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               URL(string: clip)?.host != nil, clip.lowercased().hasPrefix("http") {
                urlString = clip
            }
        }
        .onChange(of: urlString) { _ in info = nil; error = nil }
    }

    private func finish() {
        if let onClose { onClose() } else { dismiss() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        if panel.runModal() == .OK { folder = panel.url }
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
                let result = try await YTDLPService.fetchInfo(url: url, ytdlp: ytdlp, headers: headers,
                                                             jsRuntime: state.mediaTools.jsRuntime)
                info = result
                choice = .best
            } catch MediaError.unsupported where ["", "/"].contains(url.path) {
                self.error = "That's the site's home page, not a video. Open the video itself (click its date or title) and try again."
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}

struct MediaSettings: View {
    @EnvironmentObject private var state: AppState
    @State private var showPaths = false

    var body: some View {
        Form {
            Section {
                Text("MacIDM can download videos and music from YouTube and over a thousand other sites. Use File › Grab Video, or the “Download this video” button the browser extension adds to videos.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Video sites") {
                statusRow(ok: state.mediaTools.ytdlp != nil,
                          title: "Video site support",
                          detail: state.mediaTools.ytdlp == nil ? "Missing — reinstall MacIDM" : versionText)
                HStack {
                    Button(state.updatingYtdlp ? "Checking…" : "Check for Updates") { state.updateYtdlp() }
                        .disabled(state.updatingYtdlp || state.mediaTools.ytdlp == nil)
                    if state.updatingYtdlp { ProgressView().controlSize(.small) }
                    if let message = state.ytdlpUpdateMessage {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Text("Sites change often. If a video that used to work stops working, check for updates.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Converting") {
                statusRow(ok: state.mediaTools.ffmpeg != nil,
                          title: "Video & audio converter",
                          detail: state.mediaTools.ffmpeg == nil ? "Not installed" : "Installed")
                Text(state.mediaTools.ffmpeg == nil
                     ? "Needed for HD video (which arrives as separate picture and sound) and for MP3/M4A. Install it with Homebrew: brew install ffmpeg, then reopen MacIDM."
                     : "Joins HD video with its sound and converts audio to MP3 or M4A.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                DisclosureGroup("Technical details", isExpanded: $showPaths) {
                    LabeledContent("yt-dlp", value: state.mediaTools.ytdlp?.path ?? "not found")
                    LabeledContent("ffmpeg", value: state.mediaTools.ffmpeg?.path ?? "not found")
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
    }

    private var versionText: String {
        if let v = state.ytdlpVersion { return "Installed · version \(v)" }
        return state.checkingYtdlpVersion ? "Installed · checking version…" : "Installed"
    }

    private func statusRow(ok: Bool, title: String, detail: String) -> some View {
        LabeledContent {
            Text(detail).foregroundStyle(ok ? Color.secondary : Color.orange)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? Color.green : Color.orange)
                Text(title)
            }
        }
    }
}
