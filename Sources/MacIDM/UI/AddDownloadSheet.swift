import AppKit
import MacIDMCore
import SwiftUI

struct AddDownloadSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.segments) private var defaultSegments = 8

    @State private var urlString = ""
    @State private var fileName = ""
    @State private var folder: URL?
    @State private var segments = 8
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Download").font(.title2.bold())
            Form {
                TextField("URL", text: $urlString, prompt: Text("https://example.com/file.zip"))
                TextField("File name", text: $fileName, prompt: Text("Automatic"))
                LabeledContent("Save to") {
                    HStack {
                        Text(folder?.path ?? "Auto (by category)")
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(folder == nil ? .secondary : .primary)
                        Spacer()
                        if folder != nil { Button("Reset") { folder = nil } }
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Stepper(value: $segments, in: 1...32) {
                    LabeledContent("Segments", value: "\(segments)")
                }
            }
            if invalid {
                Text("Enter a valid http or https URL.").foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add to Queue") { submit(startNow: false) }
                    .disabled(urlString.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Download") { submit(startNow: true) }.keyboardShortcut(.defaultAction)
                    .disabled(urlString.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            segments = defaultSegments
            if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let url = URL(string: clip), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
                urlString = clip
            }
        }
    }

    private func submit(startNow: Bool) {
        if state.add(urlString: urlString, fileName: fileName, folder: folder, segments: segments, startNow: startNow) {
            dismiss()
        } else {
            invalid = true
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK { folder = panel.url }
    }
}
