import AppKit
import AVFoundation
import ScreenCaptureKit
import UserNotifications

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

        // Request notification permission so transcription completion/failure
        // notifications can be delivered.
        requestNotificationPermission()

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

    private func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // Register action categories.
        let showAction = UNNotificationAction(
            identifier: NotificationAction.showInFinder,
            title: "Show in Finder",
            options: .foreground
        )
        let retryAction = UNNotificationAction(
            identifier: NotificationAction.retry,
            title: "Retry",
            options: .foreground
        )

        let completeCategory = UNNotificationCategory(
            identifier: NotificationCategory.transcriptionComplete,
            actions: [showAction],
            intentIdentifiers: []
        )
        let failedCategory = UNNotificationCategory(
            identifier: NotificationCategory.transcriptionFailed,
            actions: [retryAction],
            intentIdentifiers: []
        )
        center.setNotificationCategories([completeCategory, failedCategory])

        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate: UNUserNotificationCenterDelegate {

    /// Deliver notifications even when the app is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Handle taps on notification actions.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        switch response.actionIdentifier {
        case NotificationAction.showInFinder, UNNotificationDefaultActionIdentifier:
            // Tap on "Show in Finder" or the notification body itself.
            if let pathsString = response.notification.request.content.userInfo["urls"] as? String {
                let paths = pathsString.components(separatedBy: "\n")
                // Reveal the first transcript file in Finder.
                if let firstPath = paths.first, !firstPath.isEmpty {
                    NSWorkspace.shared.selectFile(firstPath, inFileViewerRootedAtPath: "")
                }
            }

        case NotificationAction.retry:
            // Post a notification so MenuBarController can retry via its coordinator.
            NotificationCenter.default.post(name: .transcriptionRetryRequested, object: nil)

        default:
            break
        }
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let transcriptionRetryRequested = Notification.Name("TabRecordTranscriptionRetryRequested")
}
