import AppKit
import ScreenCaptureKit

/// Owns the NSStatusItem and orchestrates UI ↔ RecordingEngine interactions.
@MainActor
final class MenuBarController: NSObject {

    // MARK: - Properties

    private var statusItem: NSStatusItem!
    private let recordingEngine = RecordingEngine()
    private var durationTimer: Timer?
    private var recordingStartDate: Date?
    private var isRecording = false
    private var pickerWindowController: SourcePickerWindowController?
    private var nativePickerObserverRegistered = false

    // MARK: - Init

    override init() {
        super.init()
        buildStatusItem()
    }

    // MARK: - Status bar setup

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusButton(recording: false)
        rebuildMenu()
    }

    private func updateStatusButton(recording: Bool) {
        guard let button = statusItem.button else { return }
        if recording {
            // Show duration text; icon is hidden while recording
            button.image = nil
        } else {
            button.title = ""
            button.image = NSImage(
                systemSymbolName: "record.circle",
                accessibilityDescription: "TabRecord"
            )
            button.image?.isTemplate = true
        }
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()

        if isRecording {
            let stopItem = NSMenuItem(
                title: "Stop Recording",
                action: #selector(handleStopRecording),
                keyEquivalent: ""
            )
            stopItem.target = self
            menu.addItem(stopItem)
        } else {
            let startItem = NSMenuItem(
                title: "Start Recording…",
                action: #selector(handleStartRecording),
                keyEquivalent: ""
            )
            startItem.target = self
            menu.addItem(startItem)
        }

        menu.addItem(.separator())

        let folderItem = NSMenuItem(
            title: "Open Recordings Folder",
            action: #selector(openRecordingsFolder),
            keyEquivalent: ""
        )
        folderItem.target = self
        menu.addItem(folderItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(
            title: "Quit TabRecord",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc private func handleStartRecording() {
        Task { await showSourcePicker() }
    }

    @objc private func handleStopRecording() {
        Task { await stopRecording() }
    }

    @objc private func openRecordingsFolder() {
        let dir = OutputFileNamer.recordingsDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    // MARK: - Source picker

    private func showSourcePicker() async {
        if #available(macOS 14.0, *) {
            showNativePicker()
        } else {
            await showCustomPicker()
        }
    }

    /// macOS 14+ — system-native picker (thumbnail overlay, same UX as Zoom/Teams).
    @available(macOS 14.0, *)
    private func showNativePicker() {
        let picker = SCContentSharingPicker.shared
        picker.isActive = true
        if !nativePickerObserverRegistered {
            picker.add(self)
            nativePickerObserverRegistered = true
        }
        picker.present()
    }

    /// macOS 13 — custom SwiftUI panel listing displays and windows.
    private func showCustomPicker() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            let controller = SourcePickerWindowController(content: content) { [weak self] source in
                Task { @MainActor in
                    await self?.startRecording(source: source)
                }
            }
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            pickerWindowController = controller
        } catch {
            presentError("Could not enumerate sources: \(error.localizedDescription)")
        }
    }

    // MARK: - Recording lifecycle

    private func startRecording(source: RecordingSource) async {
        guard !isRecording else { return }

        let outputURL = makeOutputURL()
        do {
            try await recordingEngine.startRecording(source: source, outputURL: outputURL)
        } catch {
            presentError("Failed to start recording: \(error.localizedDescription)")
            return
        }

        isRecording = true
        recordingStartDate = Date()
        startDurationTimer()
        updateStatusButton(recording: true)
        rebuildMenu()
    }

    private func stopRecording() async {
        guard isRecording else { return }

        await recordingEngine.stopRecording()

        isRecording = false
        stopDurationTimer()
        updateStatusButton(recording: false)
        rebuildMenu()
    }

    // MARK: - Duration timer

    private func startDurationTimer() {
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickDuration()
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
        recordingStartDate = nil
    }

    private func tickDuration() {
        guard let start = recordingStartDate else { return }
        let elapsed = Int(Date().timeIntervalSince(start))
        let h = elapsed / 3600
        let m = elapsed / 60 % 60
        let s = elapsed % 60
        let formatted = h > 0
            ? String(format: "⏺ %02d:%02d:%02d", h, m, s)
            : String(format: "⏺ %02d:%02d", m, s)
        statusItem.button?.title = formatted
    }

    // MARK: - Helpers

    private func makeOutputURL() -> URL {
        let dir = OutputFileNamer.recordingsDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return OutputFileNamer.makeURL()
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "TabRecord"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// MARK: - SCContentSharingPickerObserver (macOS 14+)

@available(macOS 14.0, *)
extension MenuBarController: @preconcurrency SCContentSharingPickerObserver {

    /// User confirmed a selection in the native system picker.
    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        Task {
            await startRecording(source: .filter(filter))
        }
    }

    /// User dismissed the native picker without choosing anything.
    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        // Nothing to do — recording hasn't started yet.
    }

    /// System picker failed to start.
    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor in
            self.presentError("Failed to open screen picker: \(error.localizedDescription)")
        }
    }
}
