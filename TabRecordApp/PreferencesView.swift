import AppKit
import SwiftUI
import UserNotifications

// MARK: - PreferencesView

/// Preferences panel with a Transcription tab.
/// Opened via "Preferences…" in the menu bar menu (macOS 14+).
@available(macOS 14.0, *)
struct PreferencesView: View {

    @ObservedObject var preferences: TranscriptionPreferences
    @ObservedObject private var modelState = ModelStateViewModel()

    var body: some View {
        TabView {
            TranscriptionTab(preferences: preferences, modelState: modelState)
                .tabItem { Label("Transcription", systemImage: "waveform") }
        }
        .frame(width: 460, height: 380)
        .padding()
    }
}

// MARK: - TranscriptionTab

@available(macOS 14.0, *)
private struct TranscriptionTab: View {

    @ObservedObject var preferences: TranscriptionPreferences
    @ObservedObject var modelState: ModelStateViewModel

    var body: some View {
        Form {
            Section {
                Toggle("Auto-transcribe after recording", isOn: $preferences.enabled)
            }

            Section("Model") {
                Picker("Model:", selection: Binding(
                    get: { preferences.model },
                    set: { preferences.model = $0 }
                )) {
                    ForEach(WhisperModelVariant.allCases) { variant in
                        Text("\(variant.displayName) — \(String(format: "%.1f", variant.approximateSizeGB)) GB")
                            .tag(variant)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!preferences.enabled)
            }

            Section("Language") {
                HStack {
                    Text("Language:")
                    TextField("Auto-detect", text: $preferences.language)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                    Text("(ISO 639-1, e.g. \"en\", \"fr\", or leave blank)")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .disabled(!preferences.enabled)

                HStack {
                    Text("Speakers:")
                    Stepper(
                        value: $preferences.numSpeakers,
                        in: 0...8,
                        label: {
                            Text(preferences.numSpeakers == 0
                                 ? "Auto-detect"
                                 : "\(preferences.numSpeakers)")
                        }
                    )
                }
                .disabled(!preferences.enabled)
            }

            Section("Audio Source") {
                Picker("Source:", selection: Binding(
                    get: { preferences.audioSource },
                    set: { preferences.audioSource = $0 }
                )) {
                    ForEach(AudioSource.allCases) { src in
                        Text(src.displayName).tag(src)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!preferences.enabled)
            }

            Section("Output Formats") {
                Toggle("Plain text (.txt)", isOn: $preferences.writeTxt)
                Toggle("JSON with timestamps (.json)", isOn: $preferences.writeJson)
                Toggle("Subtitles (.srt)", isOn: $preferences.writeSrt)
            }
            .disabled(!preferences.enabled)

            Section("Models on Disk") {
                HStack {
                    Text(modelState.installedSummary)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if modelState.isDownloading {
                        ProgressView(value: modelState.downloadProgress)
                            .frame(width: 100)
                        Text("\(Int(modelState.downloadProgress * 100))%")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    } else {
                        Button("Download \(preferences.model.displayName)") {
                            modelState.downloadWhisperModel(preferences.model)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - ModelStateViewModel

/// Lightweight view model exposing model download state to the preferences UI.
@available(macOS 14.0, *)
@MainActor
final class ModelStateViewModel: ObservableObject {

    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0.0
    @Published var installedSummary: String = "Calculating…"

    private let manager = ModelManager()

    init() {
        Task { await refreshInstalled() }
    }

    func downloadWhisperModel(_ variant: WhisperModelVariant) {
        guard !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0.0
        Task {
            do {
                _ = try await manager.ensureWhisperModel(variant)
                await refreshInstalled()
            } catch {
                // Surface download errors via a notification (AppDelegate handles display).
                let content = UNMutableNotificationContent()
                content.title = "Model Download Failed"
                content.body = error.localizedDescription
                try? await UNUserNotificationCenter.current().add(
                    UNNotificationRequest(
                        identifier: "model-download-failed-\(UUID().uuidString)",
                        content: content,
                        trigger: nil
                    )
                )
            }
            isDownloading = false
        }
    }

    private func refreshInstalled() async {
        let installed = await manager.installedModels
        let totalBytes = await manager.totalInstalledSizeBytes
        let formatted = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        if installed.isEmpty {
            installedSummary = "No models downloaded yet"
        } else {
            installedSummary = "\(installed.count) model(s) — \(formatted) used"
        }
    }
}

// MARK: - PreferencesWindowController

/// Singleton NSWindowController hosting the SwiftUI PreferencesView.
@available(macOS 14.0, *)
final class PreferencesWindowController: NSWindowController {

    static let shared = PreferencesWindowController()

    private init() {
        let prefs = TranscriptionPreferences()
        let view = PreferencesView(preferences: prefs)
        let hostingController = NSHostingController(rootView: view)
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TabRecord Preferences"
        window.contentViewController = hostingController
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
