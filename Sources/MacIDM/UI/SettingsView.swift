import AppKit
import MacIDMCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            ScheduleSettings().tabItem { Label("Schedule", systemImage: "clock") }
            BrowserSettings().tabItem { Label("Browser", systemImage: "globe") }
            MediaSettings().tabItem { Label("Media", systemImage: "film") }
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

    var body: some View {
        Form {
            Section("Downloads") {
                LabeledContent("Download folder") {
                    HStack {
                        Text(downloadFolder).lineLimit(1).truncationMode(.middle)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Text("Files are sorted into Video, Music, Documents, Archives, Programs and Other subfolders.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper(value: $segments, in: 1...32) {
                    LabeledContent("Segments per download", value: "\(segments)")
                }
                Stepper(value: $retries, in: 0...20) {
                    LabeledContent("Retries per segment", value: "\(retries)")
                }
                Stepper(value: $maxConcurrent, in: 1...10) {
                    LabeledContent("Max concurrent downloads", value: "\(maxConcurrent)")
                }
            }
            Section("Speed limit") {
                Toggle("Limit total download speed", isOn: $speedLimitEnabled)
                HStack {
                    TextField("KB/s", value: $speedLimitKBps, format: .number)
                        .frame(width: 90)
                    Text("KB/s across all downloads")
                }
                .disabled(!speedLimitEnabled)
            }
            Section("Integration") {
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
