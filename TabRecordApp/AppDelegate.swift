import AppKit
import ScreenCaptureKit

class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Check and request screen recording permission proactively.
        // ScreenCaptureKit will also prompt on first use, but an early check
        // lets us guide the user before they try to record.
        checkScreenCapturePermission()

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
}
