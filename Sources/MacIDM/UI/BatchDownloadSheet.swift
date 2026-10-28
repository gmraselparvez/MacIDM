import MacIDMCore
import SwiftUI

/// Paste a list of links, or a numbered pattern like `file[001-100].jpg`.
struct BatchDownloadSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var parsed: Result<[URL], Error> { Result { try BatchPattern.links(from: text) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Batch Download").font(.title2.bold())
            Text("One link per line. Number ranges expand: `https://example.com/photo[001-120].jpg`, `ep[1-12].mp4`, `part[a-f].zip`.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            switch parsed {
            case .success(let urls):
                if let first = urls.first {
                    Text("\(urls.count) link\(urls.count == 1 ? "" : "s"): \(first.lastPathComponent)\(urls.count > 1 ? " … \(urls.last!.lastPathComponent)" : "")")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                } else {
                    Text("No links yet.").font(.callout).foregroundStyle(.secondary)
                }
            case .failure(let error):
                Text(error.localizedDescription).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add to Queue") { submit(startNow: false) }.disabled(count == 0)
                Button("Download All") { submit(startNow: true) }.keyboardShortcut(.defaultAction).disabled(count == 0)
            }
        }
        .padding(20)
        .frame(width: 600)
    }

    private var count: Int { (try? parsed.get())?.count ?? 0 }

    private func submit(startNow: Bool) {
        guard let urls = try? parsed.get() else { return }
        state.addBatch(urls, startNow: startNow)
        dismiss()
    }
}
