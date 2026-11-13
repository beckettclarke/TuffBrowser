import AppKit
import UserNotifications

/// Native `chrome.notifications` for extensions, on top of `UNUserNotificationCenter`. Method calls
/// are routed here by `ExtensionAPIBridge`. Click / close events still await the event-push mechanism
/// (see TODOS.md); for now a delivered notification is shown and its click is acknowledged.
final class ExtensionNotifications: NSObject {
    static let shared = ExtensionNotifications()

    private let center = UNUserNotificationCenter.current()
    /// Notification id -> the extension that created it, for routing clicks once events land.
    private var owners: [String: String] = [:]

    private override init() {
        super.init()
        center.delegate = self
    }

    private func error(_ message: String) -> Error {
        NSError(domain: "Tuff.Notifications", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Asks the user once, the first time an extension wants to show a notification.
    private func ensureAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            return false
        }
    }

    func create(
        id: String?, options: [String: Any], extensionID: String,
        finish: @escaping (Any?) -> Void, fail: @escaping (Error) -> Void
    ) {
        Task { @MainActor in
            guard await self.ensureAuthorized() else {
                fail(self.error("Notifications aren’t allowed for Tuff. Enable them in System Settings › Notifications."))
                return
            }
            let content = UNMutableNotificationContent()
            content.title = options["title"] as? String ?? ""
            content.body = options["message"] as? String ?? ""
            if options["silent"] as? Bool != true { content.sound = .default }
            let notificationID = (id?.isEmpty == false ? id! : UUID().uuidString)
            self.owners[notificationID] = extensionID
            let request = UNNotificationRequest(identifier: notificationID, content: content, trigger: nil)
            self.center.add(request) { error in
                Task { @MainActor in
                    if let error { fail(error) } else { finish(notificationID) }
                }
            }
        }
    }

    func clear(id: String, finish: @escaping (Any?) -> Void) {
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
        owners.removeValue(forKey: id)
        finish(true)
    }

    /// Chrome answers with an object whose keys are the active notification ids.
    func getAll(finish: @escaping (Any?) -> Void) {
        center.getDeliveredNotifications { notifications in
            let ids = notifications.reduce(into: [String: Bool]()) { $0[$1.request.identifier] = true }
            Task { @MainActor in finish(ids) }
        }
    }

    func getPermissionLevel(finish: @escaping (Any?) -> Void) {
        Task { @MainActor in
            let settings = await self.center.notificationSettings()
            let denied = settings.authorizationStatus == .denied
            finish(denied ? "denied" : "granted")
        }
    }
}

extension ExtensionNotifications: UNUserNotificationCenterDelegate {
    /// Show notifications even while Tuff is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.notification.request.identifier
        if let owner = owners[id] {
            if response.actionIdentifier == UNNotificationDismissActionIdentifier {
                ExtensionEventPush.shared.emit("notifications.onClosed", args: [id, true], to: owner)
            } else {
                ExtensionEventPush.shared.emit("notifications.onClicked", args: [id], to: owner)
            }
        }
        owners.removeValue(forKey: id)
        completionHandler()
    }
}