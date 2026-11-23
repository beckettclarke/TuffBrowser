import AppKit
import UserNotifications

/// Native `chrome.notifications` for extensions, on top of `UNUserNotificationCenter`.
final class ExtensionNotifications: NSObject {
    static let shared = ExtensionNotifications()

    private let center = UNUserNotificationCenter.current()
    private var owners: [String: String] = [:]
    private var lastPermissionLevel: String?
    private var monitoringPermission = false
    private static let storagePrefix = "tuff.extension."

    static func storageID(_ id: String, extensionID: String) -> String {
        storagePrefix + extensionID + "." + id
    }

    static func parse(storageID: String) -> (id: String, extensionID: String)? {
        guard storageID.hasPrefix(storagePrefix) else { return nil }
        let rest = storageID.dropFirst(storagePrefix.count)
        guard let separator = rest.firstIndex(of: "."), separator != rest.startIndex else { return nil }
        let extensionID = String(rest[..<separator])
        let id = String(rest[rest.index(after: separator)...])
        guard !id.isEmpty else { return nil }
        return (id, extensionID)
    }

    private override init() {
        super.init()
        center.delegate = self
    }

    private func error(_ message: String) -> Error {
        NSError(domain: "Tuff.Notifications", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func ensureAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            updatePermissionLevel("granted")
            return true
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            updatePermissionLevel(granted ? "granted" : "denied")
            return granted
        default:
            updatePermissionLevel("denied")
            return false
        }
    }

    /// Starts watching for changes to macOS's notification authorization (e.g. toggled in System Settings).
    func startPermissionMonitoring() {
        guard !monitoringPermission else { return }
        monitoringPermission = true
        checkPermissionLevel()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.checkPermissionLevel()
        }
    }

    private func checkPermissionLevel() {
        Task { @MainActor in
            let settings = await self.center.notificationSettings()
            self.updatePermissionLevel(settings.authorizationStatus == .denied ? "denied" : "granted")
        }
    }

    private func updatePermissionLevel(_ level: String) {
        let previous = lastPermissionLevel
        lastPermissionLevel = level
        if let previous, previous != level {
            ExtensionEventPush.shared.emit("notifications.onPermissionLevelChanged", args: [level])
        }
    }

    private func existing() async -> [UNNotificationRequest] {
        async let delivered = center.deliveredNotifications()
        async let pending = center.pendingNotificationRequests()
        return await delivered.map(\.request) + pending
    }

    private func remove(_ identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        identifiers.forEach { owners.removeValue(forKey: $0) }
    }

    private func makeContent(
        options: [String: Any], extensionID: String, storageID: String, old: UNNotificationContent? = nil
    ) async -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = options["title"] as? String ?? old?.title ?? ""
        content.body = options["message"] as? String ?? old?.body ?? ""
        if let silent = options["silent"] as? Bool {
            content.sound = silent ? nil : .default
        } else {
            content.sound = old?.sound ?? .default
        }

        if let buttons = options["buttons"] as? [[String: Any]] {
            let actions = buttons.prefix(2).enumerated().compactMap { index, button -> UNNotificationAction? in
                guard let title = button["title"] as? String, !title.isEmpty else { return nil }
                return UNNotificationAction(identifier: Self.buttonActionPrefix + "\(index)", title: title)
            }
            if actions.isEmpty {
                content.categoryIdentifier = ""
            } else {
                content.categoryIdentifier = storageID
                let category = UNNotificationCategory(identifier: storageID, actions: actions, intentIdentifiers: [])
                var categories = await center.notificationCategories()
                categories = Set(categories.filter { $0.identifier != storageID })
                categories.insert(category)
                center.setNotificationCategories(categories)
            }
        } else {
            content.categoryIdentifier = old?.categoryIdentifier ?? ""
        }

        if options["iconUrl"] != nil {
            if let attachment = await iconAttachment(options["iconUrl"], extensionID: extensionID) {
                content.attachments = [attachment]
            }
        } else {
            content.attachments = old?.attachments ?? []
        }
        return content
    }

    private static let buttonActionPrefix = "tuff.extension.button."

    private func iconAttachment(_ value: Any?, extensionID: String) async -> UNNotificationAttachment? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        let resources = ExtensionManager.shared.resourcesDirectory(forID: extensionID)
        let remote = URL(string: string)
        var source: URL?
        if let scheme = remote?.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieAcceptPolicy = .never
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            guard let (temporary, response) = try? await URLSession(configuration: configuration).download(for: URLRequest(url: remote!)) else { return nil }
            let ext = response.suggestedFilename.flatMap { URL(fileURLWithPath: $0).pathExtension.isEmpty ? nil : URL(fileURLWithPath: $0).pathExtension }
                ?? remote?.pathExtension
            let named = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext?.isEmpty == false ? ext! : "png")
            guard (try? FileManager.default.moveItem(at: temporary, to: named)) != nil else { return nil }
            source = named
        } else if let remote, let scheme = remote.scheme?.lowercased(), scheme.hasSuffix("-extension") {
            guard remote.host == extensionID, let resources else { return nil }
            let path = remote.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let local = resources.appendingPathComponent(path).standardizedFileURL
            guard local.path.hasPrefix(resources.standardizedFileURL.path + "/") else { return nil }
            source = local
        } else if let remote, remote.isFileURL {
            source = remote
        } else if let resources {
            let path = string.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let local = resources.appendingPathComponent(path).standardizedFileURL
            guard local.path.hasPrefix(resources.standardizedFileURL.path + "/") else { return nil }
            source = local
        }
        guard let source else { return nil }
        let ext = source.pathExtension
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext.isEmpty ? "png" : ext)
        guard (try? FileManager.default.copyItem(at: source, to: local)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: UUID().uuidString, url: local)
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
            let notificationID = id?.isEmpty == false ? id! : UUID().uuidString
            let storageID = Self.storageID(notificationID, extensionID: extensionID)
            let content = await self.makeContent(options: options, extensionID: extensionID, storageID: storageID)
            self.remove([storageID])
            do {
                try await self.center.add(UNNotificationRequest(identifier: storageID, content: content, trigger: nil))
                self.owners[storageID] = extensionID
                finish(notificationID)
            } catch {
                fail(error)
            }
        }
    }

    func update(id: String, options: [String: Any], extensionID: String, finish: @escaping (Any?) -> Void, fail: @escaping (Error) -> Void) {
        Task { @MainActor in
            let storageID = Self.storageID(id, extensionID: extensionID)
            let requests = await self.existing()
            guard let old = requests.first(where: { $0.identifier == storageID }) else { finish(false); return }
            let content = await self.makeContent(options: options, extensionID: extensionID, storageID: storageID, old: old.content)
            self.remove([storageID])
            do {
                try await self.center.add(UNNotificationRequest(identifier: storageID, content: content, trigger: nil))
                self.owners[storageID] = extensionID
                finish(true)
            } catch {
                fail(error)
            }
        }
    }

    func clear(id: String, extensionID: String, finish: @escaping (Any?) -> Void) {
        Task { @MainActor in
            let storageID = Self.storageID(id, extensionID: extensionID)
            let requests = await self.existing()
            guard requests.contains(where: { $0.identifier == storageID }) else { finish(false); return }
            self.remove([storageID])
            finish(true)
        }
    }

    func getAll(extensionID: String, finish: @escaping (Any?) -> Void) {
        Task { @MainActor in
            let requests = await self.existing()
            let ids = requests.compactMap { request -> (String, Bool)? in
                guard let parsed = Self.parse(storageID: request.identifier), parsed.extensionID == extensionID else { return nil }
                return (parsed.id, true)
            }
            finish(Dictionary(ids, uniquingKeysWith: { _, last in last }))
        }
    }

    func getPermissionLevel(finish: @escaping (Any?) -> Void) {
        Task { @MainActor in
            let settings = await self.center.notificationSettings()
            finish(settings.authorizationStatus == .denied ? "denied" : "granted")
        }
    }

    func extensionUnloaded(_ extensionID: String) {
        Task { @MainActor in
            let requests = await self.existing()
            let identifiers = requests.map(\.identifier).filter {
                Self.parse(storageID: $0)?.extensionID == extensionID
            }
            self.remove(identifiers)
        }
    }
}

extension ExtensionNotifications: UNUserNotificationCenterDelegate {
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
        let storageID = response.notification.request.identifier
        if WebNotifications.isWebNotification(storageID) {
            MainActor.assumeIsolated { WebNotifications.shared.handle(response) }
            completionHandler()
            return
        }
        guard let parsed = ExtensionNotifications.parse(storageID: storageID) else {
            completionHandler()
            return
        }
        let owner = owners[storageID] ?? parsed.extensionID
        if owner == parsed.extensionID, ExtensionManager.shared.contexts[owner] != nil {
            if response.actionIdentifier == UNNotificationDismissActionIdentifier {
                ExtensionEventPush.shared.emit("notifications.onClosed", args: [parsed.id, true], to: owner)
            } else if response.actionIdentifier.hasPrefix(ExtensionNotifications.buttonActionPrefix),
                      let index = Int(response.actionIdentifier.dropFirst(ExtensionNotifications.buttonActionPrefix.count)) {
                ExtensionEventPush.shared.emit("notifications.onButtonClicked", args: [parsed.id, index], to: owner)
            } else {
                ExtensionEventPush.shared.emit("notifications.onClicked", args: [parsed.id], to: owner)
            }
        }
        owners.removeValue(forKey: storageID)
        completionHandler()
    }
}
