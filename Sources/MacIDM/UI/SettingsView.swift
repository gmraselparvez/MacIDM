import AppKit
import MacIDMCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            ScheduleSettings().tabItem { Label("Schedule", systemImage: "clock") }
            BrowserSettings().tabItem { Label("Browser", systemImage: "globe") }
            MediaSettings().tabItem { Label("Video", systemImage: "play.rectangle") }
        }
        .frame(width: 540)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(SettingsKey.segments) private var segments = 8
    @AppStorage(SettingsKey.retries) private var retries = 5
    @AppStorage(SettingsKey.downloadFolder) private var downloadFolder = AppState.defaultDownloadFolder.path
    @AppStorage(SettingsKey.userAgent) private var userAgent = EngineConfig.safariUserAgent
    @AppStorage(SettingsKey.maxConcurrent) private var maxConcurrent = 3
    @AppStorage(SettingsKey.speedLimitEnabled) private var speedLimitEnabled = false
    @AppStorage(SettingsKey.speedLimitKBps) private var speedLimitKBps = 1024
    @AppStorage(SettingsKey.clipboardWatcher) private var clipboardWatcher = false
    @AppStorage(SettingsKey.notifications) private var notifications = true
    @AppStorage(SettingsKey.askBeforeDownload) private var askBeforeDownload = true
    @AppStorage(SettingsKey.showProgressWindow) private var showProgressWindow = true
    @State private var opensAtLogin = false
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Open MacIDM when I log in", isOn: $opensAtLogin)
                    .onChange(of: opensAtLogin) { on in
                        guard on != state.opensAtLogin else { return }
                        do { try state.setOpensAtLogin(on); loginError = nil } catch {
                            loginError = "macOS didn't allow it: \(error.localizedDescription). You can add MacIDM in System Settings › General › Login Items."
                            opensAtLogin = state.opensAtLogin
                        }
                    }
                Text("MacIDM then sits in the menu bar, ready for browser downloads and scheduled queues.")
                    .font(.caption).foregroundStyle(.secondary)
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
            Section("Downloads") {
                LabeledContent("Download folder") {
                    HStack {
                        Text(downloadFolder).lineLimit(1).truncationMode(.middle)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Text("Files are sorted into Video, Music, Documents, Archives, Programs and Other subfolders.")
                    .font(.caption).foregroundStyle(.secondary)
                NumberRow(title: "Connections per download", value: $segments, range: 1...32)
                NumberRow(title: "Retries per connection", value: $retries, range: 0...20)
                NumberRow(title: "Downloads at the same time", value: $maxConcurrent, range: 1...10)
            }
            Section("Speed limit") {
                Toggle("Limit total download speed", isOn: $speedLimitEnabled)
                LabeledContent("Maximum speed (all downloads)") {
                    SpeedField(kilobytesPerSecond: $speedLimitKBps)
                }
                .disabled(!speedLimitEnabled)
            }
            Section("Integration") {
                Toggle("Ask where to save downloads from the browser", isOn: $askBeforeDownload)
                Toggle("Show a progress window for each new download", isOn: $showProgressWindow)
                Toggle("Watch clipboard for download links", isOn: $clipboardWatcher)
                Toggle("Notify when downloads finish or fail", isOn: $notifications)
            }
            Section("Network") {
                TextField("User-Agent", text: $userAgent, axis: .vertical)
                    .lineLimit(2...4)
                Button("Reset to Safari") { userAgent = EngineConfig.safariUserAgent }
            }
        }
        .formStyle(.grouped)
        .onAppear { opensAtLogin = state.opensAtLogin }
        .onChange(of: segments) { _ in state.applySettings() }
        .onChange(of: retries) { _ in state.applySettings() }
        .onChange(of: downloadFolder) { _ in state.applySettings() }
        .onChange(of: userAgent) { _ in state.applySettings() }
        .onChange(of: maxConcurrent) { _ in state.applySettings() }
        .onChange(of: speedLimitEnabled) { _ in state.applySettings() }
        .onChange(of: speedLimitKBps) { _ in state.applySettings() }
        .onChange(of: clipboardWatcher) { _ in state.applySettings() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: downloadFolder)
        if panel.runModal() == .OK, let url = panel.url { downloadFolder = url.path }
    }
}

private struct ScheduleSettings: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(SettingsKey.scheduleEnabled) private var enabled = false
    @AppStorage(SettingsKey.scheduleStart) private var startMinute = 120
    @AppStorage(SettingsKey.scheduleStopEnabled) private var stopEnabled = false
    @AppStorage(SettingsKey.scheduleStop) private var stopMinute = 420
    @AppStorage(SettingsKey.sleepWhenDone) private var sleepWhenDone = false

    var body: some View {
        Form {
            Section {
                Toggle("Use scheduled queue", isOn: $enabled)
                Text("While on, queued downloads wait for the start time. Downloads you start yourself still begin right away.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Times") {
                DatePicker("Start at", selection: binding($startMinute), displayedComponents: .hourAndMinute)
                Toggle("Stop at", isOn: $stopEnabled)
                DatePicker("Stop time", selection: binding($stopMinute), displayedComponents: .hourAndMinute)
                    .disabled(!stopEnabled)
            }
            .disabled(!enabled)
            Section("When the queue finishes") {
                Toggle("Put the Mac to sleep", isOn: $sleepWhenDone)
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
        .onChange(of: enabled) { _ in state.applySettings() }
    }

    /// Bridges minutes-since-midnight storage to a Date for the time picker.
    private func binding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(byAdding: .minute, value: minutes.wrappedValue, to: Calendar.current.startOfDay(for: Date()))! },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                minutes.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            })
    }
}

/// Label on the left, value and stepper together on the right.
struct NumberRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField("", value: Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) }),
                          format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 52)
                Stepper("", value: $value, in: range).labelsHidden()
            }
        }
    }
}

/// A speed with a unit picker: KB/s, MB/s, GB/s or TB/s. Stored as kilobytes per second.
struct SpeedField: View {
    @Binding var kilobytesPerSecond: Int

    enum Unit: Int, CaseIterable, Identifiable {
        case kb = 0, mb, gb, tb
        var id: Int { rawValue }
        var label: String { ["KB/s", "MB/s", "GB/s", "TB/s"][rawValue] }
        var factor: Double { pow(1024, Double(rawValue)) }
    }

    @State private var amount: Double = 1
    @State private var unit: Unit = .mb

    var body: some View {
        HStack(spacing: 6) {
            TextField("", value: $amount, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 70)
            Picker("", selection: $unit) {
                ForEach(Unit.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        .onAppear(perform: load)
        .onChange(of: amount) { _ in save() }
        .onChange(of: unit) { _ in save() }
    }

    /// Shows the stored value in the largest unit that keeps it readable (e.g. 2048 KB/s → 2 MB/s).
    private func load() {
        let kb = Double(max(kilobytesPerSecond, 1))
        let best = Unit.allCases.last { kb / $0.factor >= 1 } ?? .kb
        unit = best
        amount = (kb / best.factor * 100).rounded() / 100
    }

    private func save() {
        let kb = Int((max(amount, 0.01) * unit.factor).rounded())
        if kb != kilobytesPerSecond { kilobytesPerSecond = max(1, kb) }
    }
}
