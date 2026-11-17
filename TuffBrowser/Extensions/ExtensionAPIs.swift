import AppKit
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
            finish(HistoryStore.shared.topSites())

        // chrome.history
        case ("history", "search"):
            finish(HistoryStore.shared.chromeSearch(
                text: args["text"] as? String ?? "",
                startTime: args["startTime"] as? Double,
                endTime: args["endTime"] as? Double,
                maxResults: args["maxResults"] as? Int ?? 100
            ))
        case ("history", "getVisits"):
            finish(HistoryStore.shared.chromeVisits(for: try Self.url(args["url"])))
        case ("history", "addUrl"):
            HistoryStore.shared.record(url: try Self.url(args["url"]), title: "")
            finish(nil)
        case ("history", "deleteUrl"):
            HistoryStore.shared.deleteUrl(try Self.url(args["url"]))
            finish(nil)
        case ("history", "deleteRange"):
            guard let start = args["startTime"] as? Double, let end = args["endTime"] as? Double else {
                throw APIError("startTime and endTime are required.")
            }
            HistoryStore.shared.deleteRange(startTime: start, endTime: end)
            finish(nil)
        case ("history", "deleteAll"):
            HistoryStore.shared.clear()
            finish(nil)

        // chrome.browsingData
        case ("browsingData", "remove"):
            removeBrowsingData(types: args["dataToRemove"] as? [String: Any] ?? [:], since: args["since"] as? Double ?? 0, finish: finish)
        case ("browsingData", "removeCache"):
            removeBrowsingData(types: ["cache": true], since: args["since"] as? Double ?? 0, finish: finish)
        case ("browsingData", "removeCookies"):
            removeBrowsingData(types: ["cookies": true], since: args["since"] as? Double ?? 0, finish: finish)
        case ("browsingData", "removeLocalStorage"):
            removeBrowsingData(types: ["localStorage": true], since: args["since"] as? Double ?? 0, finish: finish)
        case ("browsingData", "removeHistory"):
            HistoryStore.shared.clear()
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
            finish([String]())
        case ("management", "setEnabled"):
            guard let id = args["id"] as? String, let enabled = args["enabled"] as? Bool else {
                throw APIError("id and enabled are required.")
            }
            extensions.setEnabled(enabled, id: id)
            finish(nil)

        // chrome.sessions
        case ("sessions", "getRecentlyClosed"):
            finish(browser.recentlyClosedSessions(maxResults: args["maxResults"] as? Int ?? 25))
        case ("sessions", "restore"):
            guard let restored = browser.restoreSession(id: args["sessionId"] as? String) else {
                throw APIError("No recently closed session to restore.")
            }
            finish(restored)
        case ("sessions", "getDevices"):
            finish([[String: Any]]())

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
            ExtensionNotifications.shared.clear(id: id, finish: finish)
        case ("notifications", "getAll"):
            ExtensionNotifications.shared.getAll(finish: finish)
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
        case ("downloads", "pause"), ("downloads", "resume"):
            ExtensionDownloads.shared.pauseResume(id: (args["id"] as? Int) ?? 0, fail: fail)

        // chrome.system / power / idle
        case ("system.cpu", "getInfo"):
            finish(ExtensionSystem.shared.cpuInfo())
        case ("system.memory", "getInfo"):
            finish(ExtensionSystem.shared.memoryInfo())
        case ("system.storage", "getInfo"):
            finish(ExtensionSystem.shared.storageInfo())
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

        // chrome.tts
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

        // chrome.search
        case ("search", "query"):
            guard let text = args["text"] as? String else { throw APIError("text is required.") }
            let url = AppSettings.shared.general.searchEngine.searchURL(for: text)
            if (args["disposition"] as? String) == "CURRENT_TAB", let tab = browser.selectedTab {
                tab.load(url)
            } else {
                browser.newTab(url: url)
            }
            finish(nil)

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
            // Fields WebKit's tab objects lack, per index: groupId, cookieStoreId.
            finish([
                "groupIds": ExtensionTabGroups.shared.groupIDs(),
                "cookieStoreIds": ExtensionContainers.shared.cookieStoreIDs(),
            ])

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

    // MARK: browsingData

    /// The data types Tuff can actually remove, for `browsingData.settings`.
    private static let removableDataTypes: [String: Bool] = [
        "cache": true, "cookies": true, "localStorage": true, "sessionStorage": true,
        "indexedDB": true, "webSQL": true, "serviceWorkers": true, "fileSystems": true, "history": true,
        "downloads": true, "formData": true, "passwords": true,
    ]

    private func removeBrowsingData(types: [String: Any], since: Double, finish: @escaping (Any?) -> Void) {
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
        if types["history"] as? Bool == true { HistoryStore.shared.clear() }
        // The downloads list (the files stay), as in Chrome.
        if types["downloads"] as? Bool == true { DownloadManager.shared.clearFinished(isPrivate: false, since: since > 0 ? Date(timeIntervalSince1970: since / 1000) : nil) }
        // Tuff saves no passwords or form entries, so there is nothing to remove for those.

        let date = since > 0 ? Date(timeIntervalSince1970: since / 1000) : .distantPast
        let stores = DataStores.all
        guard !dataTypes.isEmpty else { finish(nil); return }
        let group = DispatchGroup()
        for store in stores {
            group.enter()
            store.removeData(ofTypes: dataTypes, modifiedSince: date) { group.leave() }
        }
        group.notify(queue: .main) { finish(nil) }
    }

    // MARK: management

    func managementInfo(_ record: ExtensionRecord) -> [String: Any] {
        let context = extensions.contexts[record.id]
        var info: [String: Any] = [
            "id": record.id,
            "name": record.name,
            "version": record.version,
            "enabled": record.enabled,
            "type": "extension",
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