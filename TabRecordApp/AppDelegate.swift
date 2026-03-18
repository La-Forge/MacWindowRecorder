import AppKit
import AVFoundation
import ScreenCaptureKit

class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Check and request screen recording permission proactively.
        // ScreenCaptureKit will also prompt on first use, but an early check
        // lets us guide the user before they try to record.
        checkScreenCapturePermission()

        // Request microphone access at launch so the TCC prompt appears before
        // the user starts recording. Without this the prompt may be suppressed
        // or the mic tap may start silently producing empty buffers.
        checkMicrophonePermission()

        menuBarController = MenuBarController()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Picker window can close without quitting the app.
        return false
    }

    // MARK: - Permissions

    private func checkScreenCapturePermission() {
        // CGPreflightScreenCaptureAccess returns true if we already have access.
        // If not, requesting it here surfaces the system prompt once at launch.
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    private func checkMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        default:
            break
        }
    }
}
