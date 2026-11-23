import AppKit
import NaturalLanguage
import WebKit

/// Native implementations of WebExtension APIs that WebKit does not provide, exposed to the
/// compatibility shim through the same private-URL bridge the side panel uses: the shim calls
/// `tabs.create({url: 'tuff-api://<namespace>/<method>/?d=<json>'})`, Tuff intercepts it before a
/// tab is made, and the answer travels back as JSON carried in the call's error (see
/// `ExtensionCompat`). `tabs.create` is the one browser call every extension context can make
/// without a permission, service workers included.
///
/// Unlike the side-panel bridge this one is asynchronous: a handler may take time (clearing website
/// data, say) and calls `completion` when it has an answer; the shim's `tabs.create` promise settles
/// then. Methods that WebKit itself implements are never routed here — the shim only supplies the
/// namespaces the engine lacks.
enum ExtensionAPIPermissions {
    private static let namespaces = [
        "topSites": "topSites", "history": "history", "browsingData": "browsingData",
        "management": "management", "sessions": "sessions", "notifications": "notifications",
        "offscreen": "offscreen", "identity": "identity", "downloads": "downloads",
        "system.cpu": "system.cpu", "system.memory": "system.memory", "system.storage": "system.storage",
        "power": "power", "idle": "idle", "tts": "tts", "ttsEngine": "ttsEngine", "search": "search",
        "userScripts": "userScripts", "tabGroups": "tabGroups", "contextualIdentities": "contextualIdentities",
        "contentSettings": "contentSettings", "clipboard": "clipboardWrite", "find": "find",
        "omnibox": "omnibox", "theme": "theme", "bookmarks": "bookmarks", "readingList": "readingList",
        "declarativeContent": "declarativeContent", "captivePortal": "captivePortal",
        "system.display": "system.display", "dns": "dns", "pageCapture": "pageCapture", "debugger": "debugger",
        "webAuthenticationProxy": "webAuthenticationProxy",
        "pkcs11": "pkcs11", "proxy": "proxy", "storage.managed": "storage",
    ]

    static func setting(_ path: String) -> String? {
        if path.hasPrefix("privacy.") { return "privacy" }
        if path.hasPrefix("proxy.") { return "proxy" }
        if path.hasPrefix("fontSettings.") { return "fontSettings" }
        if path.hasPrefix("browserSettings.") { return "browserSettings" }
        return nil
    }

    static func event(_ name: String) -> String? {
        if name.hasPrefix("settings.onChange.") { return setting(String(name.dropFirst("settings.onChange.".count))) }
        if name == "storage.managed.onChanged" { return "storage" }
        let parts = name.split(separator: ".")
        // system.cpu, system.storage…: the namespace is the first two parts.
        let namespace = parts.prefix(parts.first == "system" ? 2 : 1).joined(separator: ".")
        return namespaces[namespace]
    }

    static func required(namespace: String, method: String, args: [String: Any] = [:]) -> String? {
        if namespace == "__events" { return (args["event"] as? String).map(event) ?? nil }
        if namespace == "settings" { return (args["path"] as? String).flatMap(setting) }
        if namespace == "tabs" {
            if ["group", "ungroup"].contains(method) { return "tabGroups" }
            if ["hide", "show"].contains(method) { return "tabHide" }
            return nil
        }
        if namespace == "cookies" { return "cookies" }
        if namespace == "userScripts", ["replyMessage", "portMessage", "portDisconnect"].contains(method) { return nil }
        if namespace == "menus" { return nil }
        return namespaces[namespace]
    }
}

final class ExtensionAPIBridge {
    static let shared = ExtensionAPIBridge()

    static let scheme = "tuff-api"
    /// Prefix of the error message that carries a reply back to the shim.
    static let replyMarker = "__tuff_api__:"

    private var browser: BrowserState { .shared }
    private var extensions: ExtensionManager { .shared }

    private struct APIError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Answers one shim call. Always completes with an error whose message carries `{value}` or
    /// `{error}` as JSON after `replyMarker`; the shim unpacks it.
    func handle(_ url: URL, context: WKWebExtensionContext, completion: @escaping (Error) -> Void) {
        let namespace = url.host ?? ""
        let method = url.pathComponents.dropFirst().first ?? ""
        var args: [String: Any] = [:]
        if let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "d" })?.value,
           let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            args = object
        }
        extensions.trace("api \(namespace).\(method)")

        let finish: (Any?) -> Void = { value in completion(Self.reply(["value": value ?? NSNull()])) }
        let fail: (Error) -> Void = { error in completion(Self.reply(["error": error.localizedDescription])) }
        do {
            if let permission = ExtensionAPIPermissions.required(namespace: namespace, method: method, args: args),
               !context.currentPermissions.contains(WKWebExtension.Permission(rawValue: permission)) {
                throw APIError("This extension does not have the \(permission) permission.")
            }
            try perform(namespace: namespace, method: method, args: args, context: context, finish: finish, fail: fail)
        } catch {
            fail(error)
        }
    }

    private static func reply(_ object: [String: Any]) -> Error {
        let json = (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return NSError(domain: "Tuff.API", code: 0, userInfo: [NSLocalizedDescriptionKey: replyMarker + json])
    }

    // MARK: Routing

    private func perform(
        namespace: String, method: String, args: [String: Any], context: WKWebExtensionContext,
        finish: @escaping (Any?) -> Void, fail: @escaping (Error) -> Void
    ) throws {
        switch (namespace, method) {
        // chrome.topSites
        case ("topSites", "get"):
            finish(HistoryStore.shared.topSites(profileID: browser.currentProfile.id))

        // chrome.history
        case ("history", "search"):
            finish(HistoryStore.shared.chromeSearch(
                text: args["text"] as? String ?? "",
                startTime: args["startTime"] as? Double,
                endTime: args["endTime"] as? Double,
                maxResults: args["maxResults"] as? Int ?? 100,
                profileID: browser.currentProfile.id
            ))
        case ("history", "getVisits"):
            finish(HistoryStore.shared.chromeVisits(for: try Self.url(args["url"]), profileID: browser.currentProfile.id))
        case ("history", "addUrl"):
            HistoryStore.shared.record(url: try Self.url(args["url"]), title: "", profileID: browser.currentProfile.id)
            finish(nil)
        case ("history", "deleteUrl"):
            HistoryStore.shared.deleteUrl(try Self.url(args["url"]), profileID: browser.currentProfile.id)
            finish(nil)
        case ("history", "deleteRange"):
            guard let start = args["startTime"] as? Double, let end = args["endTime"] as? Double else {
                throw APIError("startTime and endTime are required.")
            }
            HistoryStore.shared.deleteRange(startTime: start, endTime: end, profileID: browser.currentProfile.id)
            finish(nil)
        case ("history", "deleteAll"):
            HistoryStore.shared.clear(profileID: browser.currentProfile.id)
            finish(nil)

        // chrome.browsingData
        case ("browsingData", "remove"):
            removeBrowsingData(
                types: args["dataToRemove"] as? [String: Any] ?? [:],
                since: args["since"] as? Double ?? 0,
                origins: args["origins"] as? [String],
                excludeOrigins: args["excludeOrigins"] as? [String],
                finish: finish
            )
        case ("browsingData", "removeCache"):
            removeBrowsingData(types: ["cache": true], since: args["since"] as? Double ?? 0, finish: finish)
        case ("browsingData", "removeCookies"):
            removeBrowsingData(types: ["cookies": true], since: args["since"] as? Double ?? 0, finish: finish)
        case ("browsingData", "removeLocalStorage"):
            removeBrowsingData(types: ["localStorage": true], since: args["since"] as? Double ?? 0, finish: finish)
        case ("browsingData", "removeHistory"):
            let since = args["since"] as? Double ?? 0
            if since > 0 {
                HistoryStore.shared.deleteRange(startTime: since, endTime: Date().timeIntervalSince1970 * 1000)
            } else {
                HistoryStore.shared.clear()
            }
            finish(nil)
        case ("browsingData", "settings"):
            finish([
                "options": ["since": 0],
                "dataToRemove": Self.removableDataTypes,
                "dataRemovalPermitted": Self.removableDataTypes,
            ])

        // chrome.management
        case ("management", "getAll"):
            finish(extensions.records.map(managementInfo))
        case ("management", "get"):
            guard let id = args["id"] as? String, let record = extensions.records.first(where: { $0.id == id }) else {
                throw APIError("No extension with id: \(args["id"] ?? "?").")
            }
            finish(managementInfo(record))
        case ("management", "getSelf"):
            guard let record = extensions.records.first(where: { $0.id == context.uniqueIdentifier }) else {
                throw APIError("Unknown extension.")
            }
            finish(managementInfo(record))
        case ("management", "getPermissionWarningsById"):
            guard let id = args["id"] as? String, let other = extensions.contexts[id] else {
                throw APIError("No extension with id: \(args["id"] ?? "?").")
            }
            finish(ExtensionManager.permissionSummary(other.webExtension.manifest).map(\.text))
        case ("management", "getPermissionWarningsByManifest"):
            guard let text = args["manifest"] as? String,
                  let manifest = (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.json5Allowed])) as? [String: Any] else {
                throw APIError("Manifest is not valid JSON.")
            }
            finish(ExtensionManager.permissionSummary(manifest).map(\.text))
        case ("management", "uninstall"):
            guard let id = args["id"] as? String, extensions.records.contains(where: { $0.id == id }) else {
                throw APIError("No extension with id: \(args["id"] ?? "?").")
            }
            // Removing another extension always asks, whatever the caller passes.
            Task { @MainActor in
                if await self.extensions.confirmUninstall(id: id) {
                    finish(nil)
                } else {
                    fail(APIError("User cancelled uninstall request."))
                }
            }
        case ("management", "setEnabled"):
            guard let id = args["id"] as? String, let enabled = args["enabled"] as? Bool else {
                throw APIError("id and enabled are required.")
            }
            extensions.setEnabled(enabled, id: id)
            finish(nil)
        case ("management", "uninstallSelf"):
            let id = context.uniqueIdentifier
            Task { @MainActor in
                if await self.extensions.confirmUninstall(id: id) {
                    finish(nil)
                } else {
                    fail(APIError("The extension wasn’t removed."))
                }
            }
        case ("management", "install"):
            let themeURL = try Self.url(args["url"])
            let hash = args["hash"] as? String
            Task { @MainActor in
                do {
                    let id = try await self.extensions.installTheme(url: themeURL, hash: hash)
                    finish(["id": id])
                } catch {
                    fail(error)
                }
            }

        // chrome.sessions
        case ("sessions", "getRecentlyClosed"):
            finish(browser.recentlyClosedSessions(maxResults: args["maxResults"] as? Int ?? 25))
        case ("sessions", "restore"):
            // A tab from another device (getDevices): open it here.
            if let id = args["sessionId"] as? String, let remote = MainActor.assumeIsolated({ Self.syncedTab(sessionID: id) }) {
                browser.newTab(url: remote.url)
                finish(nil)
                break
            }
            guard let restored = browser.restoreSession(id: args["sessionId"] as? String) else {
                throw APIError("No recently closed session to restore.")
            }
            finish(restored)
        case ("sessions", "getDevices"):
            finish(MainActor.assumeIsolated { Self.syncedDevices(maxResults: args["maxResults"] as? Int ?? 25) })
        case ("sessions", "forgetClosedTab"):
            guard browser.forgetClosedTab(id: try Self.string(args["sessionId"])) else {
                throw APIError("Could not find closed tab using sessionId \(args["sessionId"] ?? "").")
            }
            finish(nil)
        case ("sessions", "forgetClosedWindow"):
            // Tuff has the one window, so there are never closed windows to forget.
            throw APIError("Could not find closed window using sessionId \(args["sessionId"] ?? "").")
        // Firefox's tab and window values (ExtensionSessionValues). No tab means the window.
        case ("sessions", "getValue"):
            let tab = args["tabIndex"] != nil ? try ExtensionFind.tab(args["tabIndex"]) : nil
            finish(ExtensionSessionValues.shared.get(try Self.string(args["key"]), tab: tab, extensionID: context.uniqueIdentifier))
        case ("sessions", "setValue"):
            let tab = args["tabIndex"] != nil ? try ExtensionFind.tab(args["tabIndex"]) : nil
            ExtensionSessionValues.shared.set(try Self.string(args["key"]), value: args["value"] ?? NSNull(), tab: tab, extensionID: context.uniqueIdentifier)
            finish(nil)
        case ("sessions", "removeValue"):
            let tab = args["tabIndex"] != nil ? try ExtensionFind.tab(args["tabIndex"]) : nil
            ExtensionSessionValues.shared.remove(try Self.string(args["key"]), tab: tab, extensionID: context.uniqueIdentifier)
            finish(nil)

        // chrome.notifications
        case ("notifications", "create"):
            ExtensionNotifications.shared.create(
                id: args["notificationId"] as? String,
                options: args["options"] as? [String: Any] ?? [:],
                extensionID: context.uniqueIdentifier,
                finish: finish, fail: fail
            )
        case ("notifications", "clear"):
            guard let id = args["notificationId"] as? String else { throw APIError("notificationId is required.") }
            ExtensionNotifications.shared.clear(id: id, extensionID: context.uniqueIdentifier, finish: finish)
        case ("notifications", "update"):
            guard let id = args["notificationId"] as? String else { throw APIError("notificationId is required.") }
            ExtensionNotifications.shared.update(
                id: id, options: args["options"] as? [String: Any] ?? [:], extensionID: context.uniqueIdentifier,
                finish: finish, fail: fail
            )
        case ("notifications", "getAll"):
            ExtensionNotifications.shared.getAll(extensionID: context.uniqueIdentifier, finish: finish)
        case ("notifications", "getPermissionLevel"):
            ExtensionNotifications.shared.getPermissionLevel(finish: finish)

        // chrome.offscreen (MV3)
        case ("offscreen", "createDocument"):
            guard let path = args["url"] as? String,
                  let url = URL(string: path, relativeTo: context.baseURL)?.absoluteURL else {
                throw APIError("url is required.")
            }
            ExtensionOffscreen.shared.create(url: url, context: context, finish: finish, fail: fail)
        case ("offscreen", "closeDocument"):
            ExtensionOffscreen.shared.close(id: context.uniqueIdentifier, finish: finish, fail: fail)
        case ("offscreen", "hasDocument"):
            ExtensionOffscreen.shared.has(id: context.uniqueIdentifier, finish: finish)

        // chrome.identity (OAuth)
        case ("identity", "launchWebAuthFlow"):
            guard let urlString = args["url"] as? String, let url = URL(string: urlString) else {
                throw APIError("url is required.")
            }
            ExtensionIdentity.shared.launchWebAuthFlow(
                url: url, interactive: args["interactive"] as? Bool ?? false,
                extensionID: context.uniqueIdentifier, finish: finish, fail: fail
            )

        // chrome.downloads
        case ("downloads", "download"):
            ExtensionDownloads.shared.download(options: args, finish: finish, fail: fail)
        case ("downloads", "search"):
            ExtensionDownloads.shared.search(query: args, finish: finish)
        case ("downloads", "erase"):
            ExtensionDownloads.shared.erase(query: args, finish: finish, fail: fail)
        case ("downloads", "cancel"):
            ExtensionDownloads.shared.cancel(id: try Self.int(args["id"]), finish: finish, fail: fail)
        case ("downloads", "open"):
            ExtensionDownloads.shared.open(id: try Self.int(args["id"]), finish: finish, fail: fail)
        case ("downloads", "show"):
            ExtensionDownloads.shared.show(id: try Self.int(args["id"]), finish: finish, fail: fail)
        case ("downloads", "pause"):
            ExtensionDownloads.shared.pause(id: try Self.int(args["id"]), finish: finish, fail: fail)
        case ("downloads", "resume"):
            ExtensionDownloads.shared.resume(id: try Self.int(args["id"]), finish: finish, fail: fail)
        case ("downloads", "removeFile"):
            ExtensionDownloads.shared.removeFile(id: try Self.int(args["id"]), finish: finish, fail: fail)
        case ("downloads", "getFileIcon"):
            ExtensionDownloads.shared.fileIcon(id: try Self.int(args["id"]), size: args["size"] as? Int ?? 32, finish: finish, fail: fail)
        case ("downloads", "showDefaultFolder"):
            NSWorkspace.shared.open(DownloadManager.downloadsFolder())
            finish(nil)
        case ("downloads", "drag"):
            ExtensionDownloads.shared.drag(id: try Self.int(args["id"]), finish: finish, fail: fail)
        case ("downloads", "suggestFilename"):
            ExtensionDownloads.shared.suggestFilename(
                requestID: try Self.int(args["requestId"]),
                extensionID: context.uniqueIdentifier,
                filename: args["filename"] as? String,
                conflictAction: args["conflictAction"] as? String
            )
            finish(nil)

        // chrome.system / power / idle
        case ("system.cpu", "getInfo"):
            finish(ExtensionSystem.shared.cpuInfo())
        case ("system.memory", "getInfo"):
            finish(ExtensionSystem.shared.memoryInfo())
        case ("system.storage", "getInfo"):
            finish(ExtensionSystem.shared.storageInfo())
        case ("system.storage", "getAvailableCapacity"):
            finish(try ExtensionSystem.shared.availableCapacity(id: try Self.string(args["id"])))
        case ("system.storage", "ejectDevice"):
            ExtensionSystem.shared.ejectDevice(id: try Self.string(args["id"]), finish: finish)
        case ("dns", "resolve"):
            let hostname = try Self.string(args["hostname"])
            guard !hostname.isEmpty else { throw APIError("A hostname is required.") }
            ExtensionSystem.shared.resolve(hostname, flags: args["flags"] as? [String] ?? [], finish: finish, fail: fail)
        case ("power", "requestKeepAwake"):
            ExtensionSystem.shared.requestKeepAwake(level: args["level"] as? String ?? "system", extensionID: context.uniqueIdentifier)
            finish(nil)
        case ("power", "releaseKeepAwake"):
            ExtensionSystem.shared.releaseKeepAwake(extensionID: context.uniqueIdentifier)
            finish(nil)
        case ("idle", "queryState"):
            finish(ExtensionSystem.shared.queryState(interval: args["detectionIntervalInSeconds"] as? Int ?? 60))
        case ("idle", "setDetectionInterval"):
            ExtensionSystem.shared.setDetectionInterval(args["intervalInSeconds"] as? Int ?? 60)
            finish(nil)

        // chrome.tts / chrome.ttsEngine
        case ("tts", "speak"):
            ExtensionTTS.shared.speak(options: args, extensionID: context.uniqueIdentifier, finish: finish, fail: fail)
        case ("tts", "stop"):
            ExtensionTTS.shared.stop(finish: finish)
        case ("tts", "pause"):
            ExtensionTTS.shared.pause(finish: finish)
        case ("tts", "resume"):
            ExtensionTTS.shared.resume(finish: finish)
        case ("tts", "isSpeaking"):
            ExtensionTTS.shared.isSpeaking(finish: finish)
        case ("tts", "getVoices"):
            ExtensionTTS.shared.getVoices(finish: finish)
        case ("ttsEngine", "updateVoices"):
            ExtensionTTS.shared.updateVoices(args["voices"] as? [[String: Any]] ?? [], extensionID: context.uniqueIdentifier)
            finish(nil)
        case ("ttsEngine", "sendTtsEvent"):
            try ExtensionTTS.shared.sendTtsEvent(
                requestID: try Self.int(args["requestId"]),
                event: args["event"] as? [String: Any] ?? [:],
                from: context.uniqueIdentifier
            )
            finish(nil)

        // Firefox browser.captivePortal
        case ("captivePortal", "getState"):
            ExtensionCaptivePortal.shared.getState(finish: finish)
        case ("captivePortal", "getLastChecked"):
            finish(ExtensionCaptivePortal.shared.getLastChecked())

        // chrome.search / Firefox browser.search
        case ("search", "query"):
            guard let text = args["text"] as? String else { throw APIError("text is required.") }
            let url = AppSettings.shared.general.searchEngine.searchURL(for: text)
            // The current tab unless asked otherwise, as in Chrome and Firefox.
            let disposition = args["disposition"] as? String ?? "CURRENT_TAB"
            if disposition == "CURRENT_TAB", let tab = args["tabIndex"] != nil ? try ExtensionFind.tab(args["tabIndex"]) : browser.selectedTab {
                tab.load(url)
            } else {
                browser.newTab(url: url)
            }
            finish(nil)
        case ("search", "get"):
            let engine = AppSettings.shared.general.searchEngine
            let name = engine == .custom ? "Custom" : engine.label
            let marker = "TUFF_SEARCH_TERMS"
            let searchURL = engine.searchURL(for: marker).absoluteString.replacingOccurrences(of: marker, with: "{searchTerms}")
            let suggestURL: Any = engine.suggestURL(for: marker)?.absoluteString.replacingOccurrences(of: marker, with: "{searchTerms}") ?? NSNull()
            finish([[
                "name": name,
                "isDefault": true,
                "searchUrl": searchURL,
                "suggestUrl": suggestURL,
            ]])

        // Firefox contentScripts / userScripts (MV2) and Chrome userScripts (MV3), with inline code.
        case ("contentScripts", "register"), ("userScripts", "registerLegacy"):
            let id = try ExtensionContentScripts.shared.register(
                args, extensionID: context.uniqueIdentifier,
                resources: extensions.resourcesDirectory(forID: context.uniqueIdentifier),
                defaultWorld: namespace == "userScripts" ? "USER_SCRIPT" : "ISOLATED")
            finish(id)
        case ("contentScripts", "unregister"):
            ExtensionContentScripts.shared.unregister(handle: args["id"] as? String ?? "")
            finish(nil)
        case ("userScripts", "register"):
            try ExtensionContentScripts.shared.registerUserScripts(
                args["scripts"] as? [[String: Any]] ?? [], extensionID: context.uniqueIdentifier,
                resources: extensions.resourcesDirectory(forID: context.uniqueIdentifier))
            finish(nil)
        case ("userScripts", "update"):
            try ExtensionContentScripts.shared.updateUserScripts(
                args["scripts"] as? [[String: Any]] ?? [], extensionID: context.uniqueIdentifier,
                resources: extensions.resourcesDirectory(forID: context.uniqueIdentifier))
            finish(nil)
        case ("userScripts", "unregister"):
            ExtensionContentScripts.shared.unregisterUserScripts(ids: args["ids"] as? [String], extensionID: context.uniqueIdentifier)
            finish(nil)
        case ("userScripts", "getScripts"):
            finish(ExtensionContentScripts.shared.userScripts(ids: args["ids"] as? [String], extensionID: context.uniqueIdentifier))
        case ("userScripts", "configureWorld"):
            try ExtensionContentScripts.shared.configureWorld(args["properties"] as? [String: Any] ?? args, extensionID: context.uniqueIdentifier)
            finish(nil)
        case ("userScripts", "resetWorldConfiguration"):
            try ExtensionContentScripts.shared.resetWorldConfiguration(worldID: args["worldId"], extensionID: context.uniqueIdentifier)
            finish(nil)
        case ("userScripts", "getWorldConfigurations"):
            finish(ExtensionContentScripts.shared.getWorldConfigurations(extensionID: context.uniqueIdentifier))
        case ("userScripts", "execute"):
            ExtensionContentScripts.shared.execute(
                args, context: context, extensionID: context.uniqueIdentifier,
                resources: extensions.resourcesDirectory(forID: context.uniqueIdentifier),
                finish: finish, fail: fail
            )
        case ("userScripts", "replyMessage"):
            ExtensionContentScripts.shared.replyToUserScriptMessage(
                requestID: try Self.int(args["requestId"]),
                response: args["response"],
                error: args["error"] as? String
            )
            finish(nil)
        case ("userScripts", "portMessage"):
            ExtensionContentScripts.shared.sendToUserScriptPort(
                portID: try Self.string(args["portId"]),
                message: args["message"],
                extensionID: context.uniqueIdentifier
            )
            finish(nil)
        case ("userScripts", "portDisconnect"):
            ExtensionContentScripts.shared.disconnectUserScriptPort(
                portID: try Self.string(args["portId"]),
                extensionID: context.uniqueIdentifier
            )
            finish(nil)

        // chrome.tabGroups and tabs.group / ungroup, on folders (ExtensionGroups). Tabs come as
        // indexes in the window; the shim converts ids.
        case ("tabGroups", "get"):
            finish(try ExtensionTabGroups.shared.get(args))
        case ("tabGroups", "query"):
            finish(ExtensionTabGroups.shared.query(args))
        case ("tabGroups", "update"):
            finish(try ExtensionTabGroups.shared.update(args))
        case ("tabGroups", "move"):
            finish(try ExtensionTabGroups.shared.move(args))
        case ("tabs", "group"):
            finish(try ExtensionTabGroups.shared.group(args))
        case ("tabs", "ungroup"):
            try ExtensionTabGroups.shared.ungroup(args)
            finish(nil)
        case ("tabs", "extras"):
            // Fields WebKit's tab objects lack, per index: groupId, cookieStoreId, hidden.
            finish([
                "groupIds": ExtensionTabGroups.shared.groupIDs(),
                "cookieStoreIds": ExtensionContainers.shared.cookieStoreIDs(),
                "hidden": ExtensionTabs.shared.hiddenFlags(),
            ])
        case ("tabs", "hide"):
            finish(ExtensionTabs.shared.hide(indexes: args["tabs"] as? [Int] ?? [], extensionID: context.uniqueIdentifier))
        case ("tabs", "show"):
            ExtensionTabs.shared.show(indexes: args["tabs"] as? [Int] ?? [])
            finish(nil)
        case ("tabs", "moveInSuccession"):
            try ExtensionTabs.shared.moveInSuccession(
                tabIndexes: args["tabs"] as? [Int] ?? [],
                targetIndex: args["targetIndex"] as? Int,
                append: args["append"] as? Bool ?? false,
                insert: args["insert"] as? Bool ?? false
            )
            finish(nil)

        // Firefox contextualIdentities, on profiles.
        case ("contextualIdentities", "query"):
            finish(ExtensionContainers.shared.query(args))
        case ("contextualIdentities", "get"):
            finish(try ExtensionContainers.shared.get(args))
        case ("contextualIdentities", "create"):
            finish(try ExtensionContainers.shared.create(args))
        case ("contextualIdentities", "update"):
            finish(try ExtensionContainers.shared.update(args))
        case ("contextualIdentities", "remove"):
            ExtensionContainers.shared.remove(
                args, extensionName: context.webExtension.displayName ?? "An extension", finish: finish, fail: fail)
        case ("contextualIdentities", "move"):
            try ExtensionContainers.shared.move(args)
            finish(nil)
        case ("contextualIdentities", "openTab"):
            finish(try ExtensionContainers.shared.openTab(args))

        // ChromeSetting-shaped settings: chrome.privacy, chrome.proxy.settings, Firefox
        // browserSettings, and fontSettings (ExtensionSettings).
        case ("settings", "get"):
            finish(try ExtensionSettings.shared.get(try Self.string(args["path"]), extensionID: context.uniqueIdentifier))
        case ("settings", "set"):
            try ExtensionSettings.shared.set(try Self.string(args["path"]), value: args["value"] ?? NSNull(), extensionID: context.uniqueIdentifier)
            finish(nil)
        case ("settings", "clear"):
            try ExtensionSettings.shared.clear(try Self.string(args["path"]), extensionID: context.uniqueIdentifier)
            finish(nil)
        case ("fontSettings", "getFontList"):
            finish(ExtensionSettings.shared.fontList())

        // chrome.contentSettings
        case ("contentSettings", "get"):
            finish(try ExtensionContentSettings.shared.get(type: try Self.string(args["type"]), args: args))
        case ("contentSettings", "set"):
            try ExtensionContentSettings.shared.set(type: try Self.string(args["type"]), args: args, extensionID: context.uniqueIdentifier)
            finish(nil)
        case ("contentSettings", "clear"):
            ExtensionContentSettings.shared.clear(type: try Self.string(args["type"]), extensionID: context.uniqueIdentifier)
            finish(nil)

        // Firefox theme, clipboard and find.
        case ("theme", "getCurrent"):
            finish(ExtensionTheme.shared.current())
        case ("theme", "update"):
            try ExtensionTheme.shared.update(args["theme"] as? [String: Any] ?? [:], extensionID: context.uniqueIdentifier)
            finish(nil)
        case ("theme", "reset"):
            ExtensionTheme.shared.reset(extensionID: context.uniqueIdentifier)
            finish(nil)
        case ("clipboard", "setImageData"):
            try ExtensionClipboard.setImageData(base64: try Self.string(args["data"]), type: try Self.string(args["imageType"]))
            finish(nil)
        case ("find", "find"):
            ExtensionFind.find(args, finish: finish, fail: fail)
        case ("find", "highlightResults"):
            ExtensionFind.highlight(args, finish: finish, fail: fail)
        case ("find", "removeHighlighting"):
            ExtensionFind.removeHighlighting(args, finish: finish, fail: fail)

        // chrome.omnibox (the command bar asks; see ExtensionOmnibox).
        case ("omnibox", "setDefaultSuggestion"):
            ExtensionOmnibox.shared.setDefaultSuggestion(
                (args["suggestion"] as? [String: Any])?["description"] as? String ?? "", extensionID: context.uniqueIdentifier)
            finish(nil)
        case ("omnibox", "suggest"):
            ExtensionOmnibox.shared.suggest(request: try Self.int(args["request"]), results: args["suggestions"] as? [[String: Any]] ?? [])
            finish(nil)

        // chrome.bookmarks (ExtensionBookmarks)
        case ("bookmarks", "get"):
            let ids = (args["ids"] as? [Any] ?? []).map { "\($0)" }
            finish(try ExtensionBookmarks.shared.get(ids))
        case ("bookmarks", "getChildren"):
            finish(try ExtensionBookmarks.shared.getChildren(try Self.string(args["id"])))
        case ("bookmarks", "getRecent"):
            finish(try ExtensionBookmarks.shared.getRecent(args["numberOfItems"] as? Int ?? 0))
        case ("bookmarks", "getTree"):
            finish(try ExtensionBookmarks.shared.getTree())
        case ("bookmarks", "getSubTree"):
            finish(try ExtensionBookmarks.shared.getSubTree(try Self.string(args["id"])))
        case ("bookmarks", "search"):
            finish(try ExtensionBookmarks.shared.search(args["query"]))
        case ("bookmarks", "create"):
            finish(try ExtensionBookmarks.shared.create(args["bookmark"] as? [String: Any] ?? [:]))
        case ("bookmarks", "update"):
            finish(try ExtensionBookmarks.shared.update(try Self.string(args["id"]), changes: args["changes"] as? [String: Any] ?? [:]))
        case ("bookmarks", "move"):
            finish(try ExtensionBookmarks.shared.move(try Self.string(args["id"]), destination: args["destination"] as? [String: Any] ?? [:]))
        case ("bookmarks", "remove"), ("bookmarks", "removeTree"):
            try ExtensionBookmarks.shared.remove(try Self.string(args["id"]), recursive: method == "removeTree")
            finish(nil)

        // chrome.readingList (ExtensionReadingList)
        case ("readingList", "addEntry"):
            try ExtensionReadingList.shared.addEntry(args)
            finish(nil)
        case ("readingList", "removeEntry"):
            try ExtensionReadingList.shared.removeEntry(args)
            finish(nil)
        case ("readingList", "updateEntry"):
            try ExtensionReadingList.shared.updateEntry(args)
            finish(nil)
        case ("readingList", "query"):
            finish(try ExtensionReadingList.shared.query(args))

        // chrome.declarativeContent (ExtensionDeclarativeContent)
        case ("declarativeContent", "addRules"):
            finish(try ExtensionDeclarativeContent.shared.addRules(args["rules"] as? [[String: Any]] ?? [], extensionID: context.uniqueIdentifier))
        case ("declarativeContent", "removeRules"):
            ExtensionDeclarativeContent.shared.removeRules(args["ids"] as? [String], extensionID: context.uniqueIdentifier)
            finish(nil)
        case ("declarativeContent", "getRules"):
            finish(ExtensionDeclarativeContent.shared.getRules(args["ids"] as? [String], extensionID: context.uniqueIdentifier))

        // Badge colours & user settings (Tuff draws the badge and pins buttons).
        case ("action", "setBadgeColor"):
            let tab = args["tabIndex"] != nil ? try ExtensionFind.tab(args["tabIndex"]) : nil
            try ExtensionBadgeColors.shared.set(try Self.string(args["kind"]), value: args["color"], tab: tab, extensionID: context.uniqueIdentifier)
            finish(nil)
        case ("action", "getBadgeTextColor"):
            let tab = args["tabIndex"] != nil ? try ExtensionFind.tab(args["tabIndex"]) : nil
            finish(ExtensionBadgeColors.shared.textColor(for: context.uniqueIdentifier, tab: tab))
        case ("action", "getUserSettings"):
            let pinned = extensions.records.first(where: { $0.id == context.uniqueIdentifier })?.isPinned ?? false
            finish(["isOnToolbar": pinned])

        // chrome.cookies gaps
        case ("cookies", "getPartitionKey"):
            let tab = args["tabIndex"] != nil ? try ExtensionFind.tab(args["tabIndex"]) : browser.selectedTab
            finish(ExtensionCookies.partitionKey(for: tab?.url, frameID: args["frameId"] as? Int))

        // chrome.declarativeNetRequest gaps (ExtensionDNR)
        case ("declarativeNetRequest", "getAvailableStaticRuleCount"):
            let perms = context.currentPermissions
            guard perms.contains(.declarativeNetRequest) || perms.contains(.declarativeNetRequestWithHostAccess) else {
                throw APIError("This extension does not have the declarativeNetRequest permission.")
            }
            finish(ExtensionDNR.availableStaticRuleCount(
                manifest: context.webExtension.manifest,
                resources: extensions.resourcesDirectory(forID: context.uniqueIdentifier),
                enabledRulesetIDs: args["enabledRulesetIds"] as? [String],
                disabledByRuleset: ExtensionDNR.shared.disabledMap(for: context.uniqueIdentifier)
            ))
        case ("declarativeNetRequest", "testMatchOutcome"):
            let perms = context.currentPermissions
            guard perms.contains(.declarativeNetRequest) || perms.contains(.declarativeNetRequestWithHostAccess) || perms.contains(.declarativeNetRequestFeedback) else {
                throw APIError("This extension does not have the declarativeNetRequest permission.")
            }
            finish(try ExtensionDNR.testMatchOutcome(
                request: args["request"] as? [String: Any] ?? [:],
                manifest: context.webExtension.manifest,
                resources: extensions.resourcesDirectory(forID: context.uniqueIdentifier),
                enabledRulesetIDs: args["enabledRulesetIds"] as? [String],
                dynamicRules: args["dynamicRules"] as? [[String: Any]] ?? [],
                sessionRules: args["sessionRules"] as? [[String: Any]] ?? [],
                disabledByRuleset: ExtensionDNR.shared.disabledMap(for: context.uniqueIdentifier)
            ))
        case ("declarativeNetRequest", "updateStaticRules"):
            let perms = context.currentPermissions
            guard perms.contains(.declarativeNetRequest) || perms.contains(.declarativeNetRequestWithHostAccess) else {
                throw APIError("This extension does not have the declarativeNetRequest permission.")
            }
            try ExtensionDNR.shared.updateStaticRules(
                rulesetID: try Self.string(args["rulesetId"]),
                disableRuleIDs: args["disableRuleIds"] as? [Int] ?? [],
                enableRuleIDs: args["enableRuleIds"] as? [Int] ?? [],
                extensionID: context.uniqueIdentifier,
                manifest: context.webExtension.manifest,
                resources: extensions.resourcesDirectory(forID: context.uniqueIdentifier)
            )
            finish(nil)
        case ("declarativeNetRequest", "getDisabledRuleIds"):
            let perms = context.currentPermissions
            guard perms.contains(.declarativeNetRequest) || perms.contains(.declarativeNetRequestWithHostAccess) else {
                throw APIError("This extension does not have the declarativeNetRequest permission.")
            }
            finish(try ExtensionDNR.shared.disabledRuleIDs(
                rulesetID: try Self.string(args["rulesetId"]),
                extensionID: context.uniqueIdentifier,
                manifest: context.webExtension.manifest
            ))

        // Firefox menus.overrideContext & custom tab/bookmark menu items
        case ("menus", "overrideContext"):
            try ExtensionMenus.shared.overrideContext(args, extensionID: context.uniqueIdentifier)
            finish(nil)
        case ("menus", "registerItem"):
            ExtensionMenus.shared.registerItem(args, extensionID: context.uniqueIdentifier)
            finish(nil)
        case ("menus", "removeItem"):
            ExtensionMenus.shared.removeItem(id: args["id"] as? String, extensionID: context.uniqueIdentifier)
            finish(nil)

        // chrome.storage.managed / browser.storage.managed
        case ("storage.managed", "get"):
            finish(ExtensionManagedStorage.shared.get(
                keys: args["keys"],
                extensionID: context.uniqueIdentifier,
                manifest: context.webExtension.manifest
            ))
        case ("storage.managed", "getKeys"):
            finish(ExtensionManagedStorage.shared.getKeys(
                extensionID: context.uniqueIdentifier,
                manifest: context.webExtension.manifest
            ))
        case ("storage.managed", "getBytesInUse"):
            finish(ExtensionManagedStorage.shared.getBytesInUse(
                keys: args["keys"],
                extensionID: context.uniqueIdentifier,
                manifest: context.webExtension.manifest
            ))

        // Firefox browser.pkcs11
        case ("pkcs11", "installModule"):
            try ExtensionPKCS11.shared.installModule(
                name: try Self.string(args["name"]),
                flags: args["flags"] as? Int ?? 0,
                extensionID: context.uniqueIdentifier,
                manifest: context.webExtension.manifest
            )
            finish(nil)
        case ("pkcs11", "uninstallModule"):
            try ExtensionPKCS11.shared.uninstallModule(
                name: try Self.string(args["name"]),
                extensionID: context.uniqueIdentifier,
                manifest: context.webExtension.manifest
            )
            finish(nil)
        case ("pkcs11", "isModuleInstalled"):
            finish(try ExtensionPKCS11.shared.isModuleInstalled(
                name: try Self.string(args["name"]),
                extensionID: context.uniqueIdentifier,
                manifest: context.webExtension.manifest
            ))
        case ("pkcs11", "getModuleSlots"):
            finish(try ExtensionPKCS11.shared.getModuleSlots(
                name: try Self.string(args["name"]),
                extensionID: context.uniqueIdentifier,
                manifest: context.webExtension.manifest
            ))

        // Firefox proxy.onRequest
        case ("proxy", "registerOnRequest"):
            ExtensionProxyRelay.shared.registerOnRequest(
                extensionID: context.uniqueIdentifier,
                urls: args["urls"] as? [String] ?? []
            )
            finish(nil)
        case ("proxy", "unregisterOnRequest"):
            ExtensionProxyRelay.shared.unregisterOnRequest(extensionID: context.uniqueIdentifier)
            finish(nil)
        case ("proxy", "replyOnRequest"):
            ExtensionProxyRelay.shared.replyOnRequest(
                requestID: try Self.int(args["requestId"]),
                result: args["result"],
                error: args["error"] as? String
            )
            finish(nil)

        // chrome.webAuthenticationProxy (ExtensionWebAuthn)
        case ("webAuthenticationProxy", "attach"):
            try ExtensionWebAuthn.shared.attach(extensionID: context.uniqueIdentifier)
            finish(nil)
        case ("webAuthenticationProxy", "detach"):
            try ExtensionWebAuthn.shared.detach(extensionID: context.uniqueIdentifier)
            finish(nil)
        case ("webAuthenticationProxy", "completeCreateRequest"):
            try ExtensionWebAuthn.shared.completeCreateRequest(args, extensionID: context.uniqueIdentifier)
            finish(nil)
        case ("webAuthenticationProxy", "completeGetRequest"):
            try ExtensionWebAuthn.shared.completeGetRequest(args, extensionID: context.uniqueIdentifier)
            finish(nil)
        case ("webAuthenticationProxy", "completeIsUvpaaRequest"):
            try ExtensionWebAuthn.shared.completeIsUvpaaRequest(args, extensionID: context.uniqueIdentifier)
            finish(nil)

        // Gaps in namespaces WebKit has.
        case ("i18n", "detectLanguage"):
            finish(Self.detectLanguage(args["text"] as? String ?? ""))
        case ("system.display", "getInfo"):
            finish(ExtensionSystem.shared.displayInfo())
        case ("system.display", "getDisplayLayout"):
            finish(ExtensionSystem.shared.displayLayout())
        case ("tabs", "discard"):
            let tab = try ExtensionFind.tab(args["tabIndex"])
            guard !browser.isOnScreen(tab) else { throw APIError("Cannot discard the active tab.") }
            tab.sleep()
            finish(nil)
        case ("tabs", "highlight"):
            let indexes = (args["tabs"] as? [Int]) ?? (args["tabs"] as? Int).map { [$0] } ?? []
            guard let first = indexes.first else { throw APIError("No highlighted tab.") }
            browser.select(try ExtensionFind.tab(first))
            finish(nil)
        case ("tabs", "zoomSettings"):
            let tab = args["tabIndex"] != nil ? try ExtensionFind.tab(args["tabIndex"]) : browser.selectedTab
            finish(tab?.zoomSettingsDictionary ?? ["mode": "automatic", "scope": "per-origin", "defaultZoomFactor": SiteZoom.defaultZoom])
        case ("tabs", "setZoomSettings"):
            let tab = try ExtensionFind.tab(args["tabIndex"])
            try tab.setZoomSettings(mode: args["mode"] as? String, scope: args["scope"] as? String)
            finish(nil)
        case ("tabs", "print"):
            AppDelegate.shared?.printPage(nil)
            finish(nil)
        case ("tabs", "captureTab"):
            ExtensionPageCapture.captureTab(args, context: context, finish: finish, fail: fail)
        case ("tabs", "saveAsPDF"):
            ExtensionPageCapture.saveAsPDF(args, finish: finish, fail: fail)
        case ("pageCapture", "saveAsMHTML"):
            ExtensionPageCapture.saveAsMHTML(args, finish: finish, fail: fail)
        case ("runtime", "getContexts"):
            finish(extensionContexts(context))
        case ("runtime", "getBrowserInfo"):
            let info = Bundle.main.infoDictionary ?? [:]
            finish([
                "name": "Tuff", "vendor": "Tuff",
                "version": info["CFBundleShortVersionString"] as? String ?? "",
                "buildID": info["CFBundleVersion"] as? String ?? "",
            ])
        case ("runtime", "requestUpdateCheck"):
            guard let record = extensions.records.first(where: { $0.id == context.uniqueIdentifier }), record.source != .unpacked else {
                finish(["status": "no_update"])
                break
            }
            Task { @MainActor in
                guard let latest = await ExtensionManager.latestVersion(of: record),
                      ExtensionManager.isVersion(latest, newerThan: record.version) else {
                    finish(["status": "no_update"])
                    return
                }
                finish(["status": "update_available", "version": latest])
                // Straight away, unless the extension listens for onUpdateAvailable.
                if !self.extensions.offerUpdate(record, version: latest) { self.extensions.updateFromStore(id: record.id) }
            }
        case ("runtime", "installWaitingUpdate"):
            finish(extensions.installWaitingUpdate(id: context.uniqueIdentifier))
        case ("runtime", "packageStat"):
            finish(try Self.packageStat(path: args["path"] as? String ?? "/", in: extensions.resourcesDirectory(forID: context.uniqueIdentifier)))
        case ("runtime", "packageList"):
            finish(try Self.packageList(path: args["path"] as? String ?? "/", in: extensions.resourcesDirectory(forID: context.uniqueIdentifier)))
        // chrome.debugger (ExtensionDebugger)
        case ("debugger", "attach"):
            try ExtensionDebugger.shared.attach(args, context: context)
            finish(nil)
        case ("debugger", "detach"):
            try ExtensionDebugger.shared.detach(args, context: context)
            finish(nil)
        case ("debugger", "sendCommand"):
            try ExtensionDebugger.shared.sendCommand(args, context: context, finish: finish, fail: fail)
        case ("debugger", "getTargets"):
            finish(ExtensionDebugger.shared.targets())

        case ("commands", "update"):
            try ExtensionCommands.shared.update(args["detail"] as? [String: Any] ?? [:], context: context, id: context.uniqueIdentifier)
            finish(nil)
        case ("commands", "reset"):
            try ExtensionCommands.shared.reset(args["name"] as? String ?? "", context: context, id: context.uniqueIdentifier)
            finish(nil)
        case ("commands", "descriptions"):
            finish(ExtensionCommands.shared.descriptions(id: context.uniqueIdentifier))
        case ("commands", "openShortcutSettings"):
            AppDelegate.shared?.showSettings(tab: .extensions)
            finish(nil)

        // Internal permission calls for native-only names WebKit rejects in permissions.*.
        case ("__permissions", "contains"):
            let names = args["permissions"] as? [String] ?? []
            finish(names.allSatisfy { context.currentPermissions.contains(WKWebExtension.Permission(rawValue: $0)) })
        case ("__permissions", "request"):
            extensions.requestNativePermissions(args["permissions"] as? [String] ?? [], context: context, completion: finish)
        case ("__permissions", "remove"):
            let names = args["permissions"] as? [String] ?? []
            let optional = Set(context.webExtension.manifest["optional_permissions"] as? [String] ?? [])
            guard !names.isEmpty, Set(names).isSubset(of: optional) else { finish(false); break }
            for name in names {
                context.setPermissionStatus(.unknown, for: WKWebExtension.Permission(rawValue: name))
            }
            finish(true)

        // Event subscriptions from the shim (see ExtensionEventPush).
        case ("__events", "subscribe"):
            if let event = args["event"] as? String {
                ExtensionEventPush.shared.subscribe(extensionID: context.uniqueIdentifier, event: event, context: context)
            }
            finish(nil)
        case ("__events", "unsubscribe"):
            if let event = args["event"] as? String {
                ExtensionEventPush.shared.unsubscribe(extensionID: context.uniqueIdentifier, event: event)
            }
            finish(nil)

        default:
            throw APIError("Unsupported API call: \(namespace).\(method)")
        }
    }

    private static func url(_ value: Any?) throws -> URL {
        guard let string = value as? String, let url = URL(string: string) else { throw APIError("Invalid url.") }
        return url
    }

    private static func string(_ value: Any?) throws -> String {
        guard let string = value as? String else { throw APIError("A string argument is missing.") }
        return string
    }

    private static func int(_ value: Any?) throws -> Int {
        guard let id = value as? Int else { throw APIError("id is required.") }
        return id
    }

    // MARK: sessions on other devices

    /// Open tabs on the other devices of the Firefox account (Settings → Sync), as Chrome's
    /// `sessions.Device`: each device has one window holding its tabs, most recent first.
    @MainActor
    private static func syncedDevices(maxResults: Int) -> [[String: Any]] {
        SyncManager.shared.devices.map { device in
            let tabs: [[String: Any]] = device.tabs.prefix(max(1, maxResults)).enumerated().map { index, tab in
                [
                    "index": index, "windowId": -1, "url": tab.url.absoluteString, "title": tab.title,
                    "active": index == 0, "highlighted": index == 0, "selected": index == 0, "pinned": false,
                    "incognito": false, "discarded": false, "autoDiscardable": true, "groupId": -1,
                    "sessionId": "\(device.id):\(index)",
                ]
            }
            return [
                "deviceName": device.name,
                "sessions": [[
                    "lastModified": Int(device.tabs.first?.lastUsed.timeIntervalSince1970 ?? 0),
                    "window": [
                        "id": -1, "focused": false, "incognito": false, "alwaysOnTop": false,
                        "type": "normal", "state": "normal", "sessionId": device.id, "tabs": tabs,
                    ],
                ]],
            ]
        }
    }

    /// The synced tab a `sessionId` from `syncedDevices` names.
    @MainActor
    private static func syncedTab(sessionID: String) -> SyncDevice.OpenTab? {
        let parts = sessionID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2, let index = Int(parts.last!) else { return nil }
        let deviceID = parts.dropLast().joined(separator: ":")
        guard let device = SyncManager.shared.devices.first(where: { $0.id == deviceID }), device.tabs.indices.contains(index) else { return nil }
        return device.tabs[index]
    }

    // MARK: i18n.detectLanguage

    /// Chrome's answer shape: up to three languages with a percentage each.
    private static func detectLanguage(_ text: String) -> [String: Any] {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3).sorted { $0.value > $1.value }
        let languages = hypotheses.map { ["language": $0.key.rawValue, "percentage": Int(($0.value * 100).rounded())] }
        return ["isReliable": (hypotheses.first?.value ?? 0) >= 0.8, "languages": languages.isEmpty ? [["language": "und", "percentage": 100]] : languages]
    }

    // MARK: browsingData

    /// The data types Tuff can actually remove, for `browsingData.settings`.
    private static let removableDataTypes: [String: Bool] = [
        "cache": true, "cookies": true, "localStorage": true, "sessionStorage": true,
        "indexedDB": true, "webSQL": true, "serviceWorkers": true, "fileSystems": true, "history": true,
        "cacheStorage": true, "appcache": true,
        "downloads": true, "formData": true, "passwords": true,
    ]

    private func removeBrowsingData(
        types: [String: Any], since: Double, origins: [String]? = nil, excludeOrigins: [String]? = nil,
        finish: @escaping (Any?) -> Void
    ) {
        var dataTypes = Set<String>()
        if types["cache"] as? Bool == true {
            dataTypes.formUnion([WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache])
        }
        if types["cookies"] as? Bool == true { dataTypes.insert(WKWebsiteDataTypeCookies) }
        if types["localStorage"] as? Bool == true { dataTypes.insert(WKWebsiteDataTypeLocalStorage) }
        if types["sessionStorage"] as? Bool == true { dataTypes.insert(WKWebsiteDataTypeSessionStorage) }
        if types["indexedDB"] as? Bool == true { dataTypes.insert(WKWebsiteDataTypeIndexedDBDatabases) }
        if types["webSQL"] as? Bool == true { dataTypes.insert(WKWebsiteDataTypeWebSQLDatabases) }
        if types["serviceWorkers"] as? Bool == true { dataTypes.insert(WKWebsiteDataTypeServiceWorkerRegistrations) }
        if types["fileSystems"] as? Bool == true { dataTypes.insert(WKWebsiteDataTypeFileSystem) }
        if types["cacheStorage"] as? Bool == true { dataTypes.insert(WKWebsiteDataTypeFetchCache) }
        if types["appcache"] as? Bool == true { dataTypes.insert(WKWebsiteDataTypeOfflineWebApplicationCache) }
        if types["history"] as? Bool == true {
            if since > 0 {
                HistoryStore.shared.deleteRange(startTime: since, endTime: Date().timeIntervalSince1970 * 1000)
            } else {
                HistoryStore.shared.clear()
            }
        }
        // The downloads list (the files stay), as in Chrome.
        if types["downloads"] as? Bool == true { DownloadManager.shared.clearFinished(isPrivate: false, since: since > 0 ? Date(timeIntervalSince1970: since / 1000) : nil) }
        if types["passwords"] as? Bool == true {
            PasswordStore.shared.remove(
                since: since > 0 ? Date(timeIntervalSince1970: since / 1000) : nil,
                origins: origins.map(Set.init),
                excludeOrigins: excludeOrigins.map(Set.init)
            )
        }
        // Tuff saves no form-autofill entries, so there is nothing to remove for formData.

        let date = since > 0 ? Date(timeIntervalSince1970: since / 1000) : .distantPast
        let stores = DataStores.all
        guard !dataTypes.isEmpty else { finish(nil); return }
        // Exclude installed extensions' own origins so removing Fetch caches / service workers
        // never terminates the calling extension's own service worker.
        let protectedHosts = Set(extensions.records.map { $0.id.lowercased() })
        let originHosts = origins.map { Set($0.compactMap { URL(string: $0)?.host?.lowercased() }) }
        let excludedHosts = excludeOrigins.map { Set($0.compactMap { URL(string: $0)?.host?.lowercased() }) }
        let group = DispatchGroup()
        for store in stores {
            group.enter()
            store.fetchDataRecords(ofTypes: dataTypes) { records in
                let targets = records.filter { record in
                    let name = record.displayName.lowercased()
                    if protectedHosts.contains(name) || name.hasSuffix("-extension") { return false }
                    if let originHosts, !originHosts.contains(where: { $0 == name || $0.hasSuffix("." + name) || name.hasSuffix("." + $0) }) {
                        return false
                    }
                    if let excludedHosts, excludedHosts.contains(where: { $0 == name || $0.hasSuffix("." + name) || name.hasSuffix("." + $0) }) {
                        return false
                    }
                    return true
                }
                if targets.isEmpty {
                    group.leave()
                } else if originHosts == nil && excludedHosts == nil && protectedHosts.isEmpty {
                    store.removeData(ofTypes: dataTypes, modifiedSince: date) { group.leave() }
                } else {
                    store.removeData(ofTypes: dataTypes, for: targets) { group.leave() }
                }
            }
        }
        group.notify(queue: .main) { finish(nil) }
    }

    // MARK: runtime.getContexts

    /// The extension's open pages and background, in Chrome's `ExtensionContext` shape. Tabs go
    /// by their index in the window (`tabIndex`, -1 for none); the shim swaps in tab and window ids.
    /// Popups aren't listed: WebKit shows them, and doesn't say when one is open.
    private func extensionContexts(_ context: WKWebExtensionContext) -> [[String: Any]] {
        let id = context.uniqueIdentifier
        var origin = context.baseURL.absoluteString
        if origin.hasSuffix("/") { origin.removeLast() }
        func item(_ type: String, key: String, url: URL?, frameID: Int = 0, tabIndex: Int = -1) -> [String: Any] {
            var item: [String: Any] = [
                "contextType": type, "contextId": key, "tabIndex": tabIndex, "frameId": frameID, "incognito": false,
                "documentOrigin": origin,
            ]
            if let url { item["documentUrl"] = url.absoluteString }
            if frameID >= 0 { item["documentId"] = key }
            return item
        }
        var list: [[String: Any]] = []
        let manifest = context.webExtension.manifest
        if context.webExtension.hasBackgroundContent {
            let background = manifest["background"] as? [String: Any] ?? [:]
            if let worker = background["service_worker"] as? String {
                list.append(item("BACKGROUND", key: "\(id):background", url: URL(string: worker, relativeTo: context.baseURL)?.absoluteURL, frameID: -1))
            } else {
                let page = background["page"] as? String ?? "_generated_background_page.html"
                list.append(item("BACKGROUND", key: "\(id):background", url: URL(string: page, relativeTo: context.baseURL)?.absoluteURL))
            }
        }
        for (index, tab) in browser.allTabs.enumerated() where tab.url != nil && extensions.context(forPage: tab.url) === context {
            list.append(item("TAB", key: tab.id.uuidString, url: tab.url, tabIndex: index))
        }
        if let host = SidePanelManager.shared.host, host.extensionID == id {
            list.append(item("SIDE_PANEL", key: "\(id):side-panel", url: host.requestedURL))
        }
        if let popup = extensions.openPopup(for: id) {
            list.append(item("POPUP", key: "\(id):popup", url: popup.popupWebView?.url))
        }
        if let url = ExtensionOffscreen.shared.url(id: id) {
            list.append(item("OFFSCREEN_DOCUMENT", key: "\(id):offscreen", url: url))
        }
        return list
    }

    // MARK: runtime.getPackageDirectoryEntry

    static func resolvePackageURL(_ rawPath: String, in root: URL?) throws -> (url: URL, fullPath: String) {
        guard let root else { throw APIError("Extension package directory is unavailable.") }
        let base = root.standardizedFileURL
        let trimmed = rawPath.trimmingCharacters(in: .whitespaces)
        let components = trimmed.split(separator: "/").map(String.init)
        var resolved: [String] = []
        for part in components {
            if part.isEmpty || part == "." { continue }
            if part == ".." {
                if !resolved.isEmpty { resolved.removeLast() }
                continue
            }
            resolved.append(part)
        }
        let target = resolved.reduce(base) { $0.appendingPathComponent($1) }.standardizedFileURL
        guard target.path == base.path || target.path.hasPrefix(base.path + "/") else {
            throw APIError("Path is outside the extension package.")
        }
        let fullPath = resolved.isEmpty ? "/" : "/" + resolved.joined(separator: "/")
        return (target, fullPath)
    }

    static func packageStat(path: String, in root: URL?) throws -> [String: Any] {
        let (target, fullPath) = try resolvePackageURL(path, in: root)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir) else {
            throw APIError("NotFoundError: Entry not found.")
        }
        if target.lastPathComponent.hasPrefix("__tuff_") {
            throw APIError("NotFoundError: Entry not found.")
        }
        let attrs = (try? FileManager.default.attributesOfItem(atPath: target.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = ((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000
        return [
            "name": fullPath == "/" ? "" : target.lastPathComponent,
            "fullPath": fullPath,
            "isDirectory": isDir.boolValue,
            "isFile": !isDir.boolValue,
            "size": size,
            "modificationTime": mtime,
        ]
    }

    static func packageList(path: String, in root: URL?) throws -> [[String: Any]] {
        let (target, fullPath) = try resolvePackageURL(path, in: root)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue else {
            throw APIError("NotFoundError: Directory not found.")
        }
        let items = (try? FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        return items.compactMap { item -> [String: Any]? in
            let name = item.lastPathComponent
            if name.hasPrefix("__tuff_") { return nil }
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let dir = values?.isDirectory ?? false
            let entryPath = fullPath == "/" ? "/\(name)" : "\(fullPath)/\(name)"
            return [
                "name": name,
                "fullPath": entryPath,
                "isDirectory": dir,
                "isFile": !dir,
                "size": values?.fileSize ?? 0,
                "modificationTime": (values?.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000,
            ]
        }.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
    }

    // MARK: management

    func managementInfo(_ record: ExtensionRecord) -> [String: Any] {
        let context = extensions.contexts[record.id]
        var info: [String: Any] = [
            "id": record.id,
            "name": record.name,
            "version": record.version,
            "enabled": record.enabled,
            "type": record.isStaticTheme ? "theme" : "extension",
            "installType": record.source == .unpacked ? "development" : "normal",
            "mayDisable": true,
            "isApp": false,
            "disabledReason": record.enabled ? "unknown" : "user",
        ]
        if let optionsURL = context?.optionsPageURL { info["optionsUrl"] = optionsURL.absoluteString }
        if let homepage = context?.webExtension.manifest["homepage_url"] as? String { info["homepageUrl"] = homepage }
        return info
    }
}