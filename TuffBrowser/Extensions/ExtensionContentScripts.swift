import Foundation
import WebKit

/// Content scripts that an extension registers at run time with *code* rather than files:
/// Firefox's `contentScripts.register` and `userScripts.register`, and Chrome's MV3
/// `userScripts` API (`register`, `update`, `unregister`, `getScripts`, `execute`,
/// `configureWorld`, `resetWorldConfiguration`, `getWorldConfigurations`, and user-script
/// messaging for `runtime.onUserScriptMessage` / `runtime.onUserScriptConnect`).
///
/// Scripts in the page's world use `WKContentWorld.page`. User scripts run in an isolated
/// `WKContentWorld` per `(extensionID, worldId)`. When `configureWorld({ messaging: true })` is
/// set for a world, Tuff installs a `WKScriptMessageHandlerWithReply` bridge in that world so
/// user scripts can call `chrome.runtime.sendMessage` and `chrome.runtime.connect`.
final class ExtensionContentScripts {
    static let shared = ExtensionContentScripts()

    struct WorldConfig: Equatable {
        var worldID: String
        var csp: String?
        var messaging: Bool

        var dictionary: [String: Any] {
            var dict: [String: Any] = ["messaging": messaging]
            if !worldID.isEmpty { dict["worldId"] = worldID }
            if let csp { dict["csp"] = csp }
            return dict
        }
    }

    private struct Registration {
        let id: String
        let extensionID: String
        /// Chrome `userScripts` id (unique per extension), or nil for handle-based Firefox calls.
        let userScriptID: String?
        /// What the extension passed in, returned by `userScripts.getScripts`.
        let details: [String: Any]
        let scripts: [WKUserScript]
    }

    private struct WorldKey: Hashable {
        let extensionID: String
        let worldID: String
    }

    private struct MessagingBridge {
        let world: WKContentWorld
        let script: WKUserScript
        let handler: UserScriptMessageHandler
    }

    private struct UserScriptPort {
        let extensionID: String
        let world: WKContentWorld
        weak var webView: WKWebView?
        let frame: WKFrameInfo
    }

    /// In registration order: user scripts are injected in the order they were added.
    private var registrations: [Registration] = []
    /// Configured `USER_SCRIPT` worlds per extension (worldID "" = default world).
    private var worldConfigs: [String: [String: WorldConfig]] = [:]
    /// Active messaging bridges for worlds with `messaging: true`.
    private var messagingBridges: [WorldKey: MessagingBridge] = [:]
    /// Pending `chrome.runtime.sendMessage` replies from user scripts.
    private var pendingReplies: [Int: (Any?, String?) -> Void] = [:]
    private var nextReplyID = 1
    /// Open `chrome.runtime.connect` ports from user scripts.
    private var ports: [String: UserScriptPort] = [:]
    /// Firefox MV2 `user_scripts.api_script` user scripts injected before registered user scripts.
    private var apiScripts: [String: WKUserScript] = [:]
    /// Every tab's content controller (each web view configuration has its own).
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private var nextID = 1

    private static let messageHandlerName = "__tuffUserScript"

    struct RegistrationError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    // MARK: Tabs

    /// Gives a new tab's configuration every script and messaging bridge registered so far.
    func attach(_ controller: WKUserContentController) {
        controllers.add(controller)
        for bridge in messagingBridges.values {
            installBridge(bridge, into: controller)
        }
        for apiScript in apiScripts.values {
            controller.addUserScript(apiScript)
        }
        for registration in registrations {
            for script in registration.scripts { controller.addUserScript(script) }
        }
    }

    /// Installs Firefox MV2 `manifest.user_scripts.api_script` so `browser.userScripts.onBeforeScript`
    /// listeners run in the user-script world right before each registered user script executes.
    func extensionLoaded(_ extensionID: String, manifest: [String: Any], resources: URL?) {
        guard let us = manifest["user_scripts"] as? [String: Any],
              let path = us["api_script"] as? String, !path.isEmpty,
              let code = try? Self.text(of: ["file": path], in: resources) else { return }
        let world = userScriptWorld(extensionID: extensionID, worldID: nil)
        let source = Self.beforeScriptBootstrap + "\n" + code
        let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)
        apiScripts[extensionID] = script
        for controller in controllers.allObjects {
            controller.addUserScript(script)
        }
    }

    private static let beforeScriptBootstrap = #"""
    (() => {
      if (window.__tuffBeforeUserScriptListeners) return;
      const listeners = new Set();
      window.__tuffBeforeUserScriptListeners = listeners;
      window.__tuffRunBeforeUserScript = (metadata) => {
        const userScript = {
          metadata: metadata,
          defineGlobals: (exportObject) => {
            if (!exportObject || typeof exportObject !== 'object') return;
            for (const key of Object.keys(exportObject)) {
              try {
                Object.defineProperty(globalThis, key, {
                  value: exportObject[key],
                  writable: true,
                  configurable: true,
                  enumerable: true,
                });
              } catch (e) {
                try { globalThis[key] = exportObject[key]; } catch (e2) {}
              }
            }
          },
        };
        for (const fn of [...listeners]) {
          try { fn(userScript); } catch (e) {}
        }
      };
      const onBeforeScript = {
        addListener: (fn) => { if (typeof fn === 'function') listeners.add(fn); },
        removeListener: (fn) => { listeners.delete(fn); },
        hasListener: (fn) => listeners.has(fn),
        hasListeners: () => listeners.size > 0,
      };
      for (const rootName of ['browser', 'chrome']) {
        if (!window[rootName]) window[rootName] = {};
        if (!window[rootName].userScripts) window[rootName].userScripts = {};
        window[rootName].userScripts.onBeforeScript = onBeforeScript;
      }
    })();
    """#

    // MARK: World configuration

    func userScriptWorld(extensionID: String, worldID: String?) -> WKContentWorld {
        if let worldID, !worldID.isEmpty {
            return .world(name: "Tuff user scripts \(extensionID):\(worldID)")
        }
        return .world(name: "Tuff user scripts \(extensionID)")
    }

    private static func validatedWorldID(_ value: Any?) throws -> String {
        guard let raw = value else { return "" }
        guard let id = raw as? String else { throw RegistrationError("worldId must be a string.") }
        if id.hasPrefix("_") { throw RegistrationError("World IDs beginning with '_' are reserved.") }
        return id
    }

    func configureWorld(_ properties: [String: Any], extensionID: String) throws {
        let worldID = try Self.validatedWorldID(properties["worldId"])
        let csp = properties["csp"] as? String
        let messaging = properties["messaging"] as? Bool ?? false
        let config = WorldConfig(worldID: worldID, csp: csp, messaging: messaging)
        worldConfigs[extensionID, default: [:]][worldID] = config
        let key = WorldKey(extensionID: extensionID, worldID: worldID)
        if messaging {
            enableMessaging(for: key)
        } else {
            disableMessaging(for: key)
        }
    }

    func resetWorldConfiguration(worldID raw: Any?, extensionID: String) throws {
        let worldID = try Self.validatedWorldID(raw)
        worldConfigs[extensionID]?.removeValue(forKey: worldID)
        if worldConfigs[extensionID]?.isEmpty == true { worldConfigs[extensionID] = nil }
        disableMessaging(for: WorldKey(extensionID: extensionID, worldID: worldID))
    }

    func getWorldConfigurations(extensionID: String) -> [[String: Any]] {
        (worldConfigs[extensionID] ?? [:])
            .values
            .sorted { $0.worldID < $1.worldID }
            .map(\.dictionary)
    }

    private func enableMessaging(for key: WorldKey) {
        guard messagingBridges[key] == nil else { return }
        let world = userScriptWorld(extensionID: key.extensionID, worldID: key.worldID)
        let handler = UserScriptMessageHandler(extensionID: key.extensionID, world: world)
        let script = WKUserScript(
            source: Self.messagingBootstrap(extensionID: key.extensionID),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: world
        )
        let bridge = MessagingBridge(world: world, script: script, handler: handler)
        messagingBridges[key] = bridge
        for controller in controllers.allObjects {
            installBridge(bridge, into: controller)
        }
    }

    private func disableMessaging(for key: WorldKey) {
        guard let bridge = messagingBridges.removeValue(forKey: key) else { return }
        for controller in controllers.allObjects {
            controller.removeScriptMessageHandler(forName: Self.messageHandlerName, contentWorld: bridge.world)
            if controller.responds(to: Self.removeSelector) {
                controller.perform(Self.removeSelector, with: bridge.script)
            }
        }
    }

    private func installBridge(_ bridge: MessagingBridge, into controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: Self.messageHandlerName, contentWorld: bridge.world)
        controller.addScriptMessageHandler(bridge.handler, contentWorld: bridge.world, name: Self.messageHandlerName)
        controller.addUserScript(bridge.script)
    }

    // MARK: userScripts.execute

    func execute(
        _ details: [String: Any], context: WKWebExtensionContext?, extensionID: String, resources: URL?,
        finish: @escaping (Any?) -> Void, fail: @escaping (Error) -> Void
    ) {
        do {
            guard let target = details["target"] as? [String: Any] else {
                throw RegistrationError("target is required.")
            }
            let tab = try ExtensionFind.tab(target["tabIndex"])
            execute(in: tab, details: details, context: context, extensionID: extensionID, resources: resources, finish: finish, fail: fail)
        } catch {
            fail(error)
        }
    }

    func execute(
        in tab: Tab, details: [String: Any], context: WKWebExtensionContext?, extensionID: String, resources: URL?,
        finish: @escaping (Any?) -> Void, fail: @escaping (Error) -> Void
    ) {
        do {
            if let context, let url = tab.url, !context.hasAccess(to: url, in: tab) {
                throw RegistrationError("Cannot access contents of the page. Extension manifest must request permission to access the respective host.")
            }
            guard let webView = tab.webView else {
                throw RegistrationError("Tab is not loaded.")
            }
            let jsEntries = details["js"] as? [[String: Any]] ?? []
            guard !jsEntries.isEmpty else { throw RegistrationError("js is required.") }
            let sources = try jsEntries.map { try Self.text(of: $0, in: resources) }
            let combined = sources.joined(separator: "\n;\n")

            let worldName = (details["world"] as? String ?? "USER_SCRIPT").uppercased()
            let worldID = try Self.validatedWorldID(details["worldId"])
            let world: WKContentWorld = worldName == "MAIN" ? .page : userScriptWorld(extensionID: extensionID, worldID: worldID)

            let runExecution = {
                webView.evaluateJavaScript(combined, in: nil, in: world) { result in
                    switch result {
                    case .success(let value):
                        let sanitized = Self.jsonSafe(value)
                        finish([["frameId": 0, "result": sanitized]])
                    case .failure(let error):
                        finish([["frameId": 0, "error": error.localizedDescription]])
                    }
                }
            }

            // If messaging was enabled after the page already loaded, inject the bootstrap into this
            // page's user script world before running the script.
            if worldName != "MAIN", worldConfigs[extensionID]?[worldID]?.messaging == true {
                let bootstrap = Self.messagingBootstrap(extensionID: extensionID)
                webView.evaluateJavaScript(bootstrap, in: nil, in: world) { _ in runExecution() }
            } else {
                runExecution()
            }
        } catch {
            fail(error)
        }
    }

    private static func jsonSafe(_ value: Any?) -> Any {
        guard let value, !(value is NSNull) else { return NSNull() }
        if value is String || value is NSNumber || value is Bool { return value }
        if JSONSerialization.isValidJSONObject(value) { return value }
        return NSNull()
    }

    // MARK: User script messaging (runtime.onUserScriptMessage / onUserScriptConnect)

    fileprivate func handleUserScriptMessage(
        extensionID: String, world: WKContentWorld, message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else {
            replyHandler(nil, "Invalid user script message.")
            return
        }
        let sender = Self.senderInfo(extensionID: extensionID, message: message)
        switch op {
        case "sendMessage":
            guard ExtensionEventPush.shared.isListening(extensionID: extensionID, to: "runtime.__userScriptMessage") else {
                replyHandler(["noListener": true], nil)
                return
            }
            let requestID = nextReplyID
            nextReplyID += 1
            pendingReplies[requestID] = replyHandler
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                if let pending = self?.pendingReplies.removeValue(forKey: requestID) {
                    pending(["response": NSNull()], nil)
                }
            }
            var extra: [String: Any] = ["userScriptReply": requestID]
            if let tabIndex = sender.tabIndex { extra["senderTabIndex"] = tabIndex }
            ExtensionEventPush.shared.emit(
                "runtime.__userScriptMessage",
                args: [body["message"] ?? NSNull(), sender.dict],
                extra: extra,
                to: extensionID
            )

        case "connect":
            guard let portID = body["portId"] as? String else {
                replyHandler(nil, "portId is required.")
                return
            }
            let name = body["name"] as? String ?? ""
            ports[portID] = UserScriptPort(extensionID: extensionID, world: world, webView: message.webView, frame: message.frameInfo)
            var extra: [String: Any] = [:]
            if let tabIndex = sender.tabIndex { extra["senderTabIndex"] = tabIndex }
            ExtensionEventPush.shared.emit(
                "runtime.__userScriptConnect",
                args: [portID, name, sender.dict],
                extra: extra,
                to: extensionID
            )
            replyHandler(["ok": true], nil)

        case "portMessage":
            guard let portID = body["portId"] as? String else { replyHandler(nil, nil); return }
            ExtensionEventPush.shared.emit(
                "runtime.__userScriptPortMessage",
                args: [portID, body["message"] ?? NSNull()],
                to: extensionID
            )
            replyHandler(["ok": true], nil)

        case "portDisconnect":
            guard let portID = body["portId"] as? String else { replyHandler(nil, nil); return }
            ports.removeValue(forKey: portID)
            ExtensionEventPush.shared.emit(
                "runtime.__userScriptPortDisconnect",
                args: [portID],
                to: extensionID
            )
            replyHandler(["ok": true], nil)

        default:
            replyHandler(nil, "Unknown operation: \(op)")
        }
    }

    func replyToUserScriptMessage(requestID: Int, response: Any?, error: String?) {
        guard let handler = pendingReplies.removeValue(forKey: requestID) else { return }
        if let error {
            handler(nil, error)
        } else {
            handler(["response": response ?? NSNull()], nil)
        }
    }

    func sendToUserScriptPort(portID: String, message: Any?, extensionID: String) {
        guard let port = ports[portID], port.extensionID == extensionID, let webView = port.webView else { return }
        let json = (try? JSONSerialization.data(withJSONObject: ["m": message ?? NSNull()])).flatMap { String(data: $0, encoding: .utf8) } ?? "{\"m\":null}"
        let idJSON = (try? JSONSerialization.data(withJSONObject: [portID])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        let js = "if (window.__tuffUserScriptPortDispatch) window.__tuffUserScriptPortDispatch(\(idJSON)[0], 'message', (\(json)).m); void 0;"
        webView.evaluateJavaScript(js, in: port.frame, in: port.world) { _ in }
    }

    func disconnectUserScriptPort(portID: String, extensionID: String) {
        guard let port = ports.removeValue(forKey: portID), port.extensionID == extensionID, let webView = port.webView else { return }
        let idJSON = (try? JSONSerialization.data(withJSONObject: [portID])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        let js = "if (window.__tuffUserScriptPortDispatch) window.__tuffUserScriptPortDispatch(\(idJSON)[0], 'disconnect', null); void 0;"
        webView.evaluateJavaScript(js, in: port.frame, in: port.world) { _ in }
    }

    private static func senderInfo(extensionID: String, message: WKScriptMessage) -> (dict: [String: Any], tabIndex: Int?) {
        let frame = message.frameInfo
        let url = frame.request.url
        let origin = "\(frame.securityOrigin.protocol)://\(frame.securityOrigin.host)"
            + (frame.securityOrigin.port != 0 ? ":\(frame.securityOrigin.port)" : "")
        var dict: [String: Any] = [
            "id": extensionID,
            "frameId": frame.isMainFrame ? 0 : 1,
            "origin": origin,
        ]
        if let url { dict["url"] = url.absoluteString }
        let tabIndex = BrowserState.shared.allTabs.firstIndex { $0.webView === message.webView }
        return (dict, tabIndex)
    }

    private static func messagingBootstrap(extensionID: String) -> String {
        let idJSON = (try? JSONSerialization.data(withJSONObject: [extensionID])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return """
        (() => {
          if (window.__tuffUserScriptMessaging) return;
          window.__tuffUserScriptMessaging = true;
          const extId = (\(idJSON))[0];
          const handler = () => window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(messageHandlerName);
          const ports = new Map();
          let nextPort = 1;
          const makeEvent = () => {
            const list = new Set();
            return {
              addListener: (fn) => { if (typeof fn === 'function') list.add(fn); },
              removeListener: (fn) => { list.delete(fn); },
              hasListener: (fn) => list.has(fn),
              hasListeners: () => list.size > 0,
              _fire: (...args) => { for (const fn of [...list]) { try { fn(...args); } catch (e) {} } },
            };
          };
          window.__tuffUserScriptPortDispatch = (portId, op, payload) => {
            const port = ports.get(portId);
            if (!port) return;
            if (op === 'message') port.onMessage._fire(payload, port);
            else if (op === 'disconnect') {
              ports.delete(portId);
              port._disconnected = true;
              port.onDisconnect._fire(port);
            }
          };
          const sendMessage = (...args) => {
            const callback = args.length && typeof args[args.length - 1] === 'function' ? args.pop() : null;
            const message = args.length >= 2 && typeof args[0] === 'string' ? args[1] : args[0];
            const h = handler();
            const p = h
              ? h.postMessage({ op: 'sendMessage', message: message === undefined ? null : message }).then((r) => {
                  if (r && r.noListener) throw new Error('Could not establish connection. Receiving end does not exist.');
                  return r ? r.response : undefined;
                })
              : Promise.reject(new Error('Messaging is not available.'));
            if (!callback) return p;
            p.then((v) => { try { callback(v); } catch (e) {} }, () => { try { callback(undefined); } catch (e) {} });
            return undefined;
          };
          const connect = (...args) => {
            const info = (args.length >= 2 && typeof args[0] === 'string' ? args[1] : (typeof args[0] === 'object' ? args[0] : {})) || {};
            const portId = extId + ':' + (nextPort++) + ':' + Math.random().toString(36).slice(2);
            const onMessage = makeEvent();
            const onDisconnect = makeEvent();
            const port = {
              name: info.name || '',
              onMessage,
              onDisconnect,
              _disconnected: false,
              postMessage: (msg) => {
                if (port._disconnected) throw new Error('Attempting to use a disconnected port object');
                const h = handler();
                if (h) h.postMessage({ op: 'portMessage', portId, message: msg === undefined ? null : msg }).catch(() => {});
              },
              disconnect: () => {
                if (port._disconnected) return;
                port._disconnected = true;
                ports.delete(portId);
                const h = handler();
                if (h) h.postMessage({ op: 'portDisconnect', portId }).catch(() => {});
              },
            };
            ports.set(portId, port);
            const h = handler();
            if (h) h.postMessage({ op: 'connect', portId, name: port.name }).catch(() => {});
            return port;
          };
          const runtime = { id: extId, sendMessage, connect };
          for (const rootName of ['chrome', 'browser']) {
            if (!window[rootName]) window[rootName] = {};
            if (!window[rootName].runtime) window[rootName].runtime = runtime;
          }
        })();
        """
    }

    private final class UserScriptMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
        let extensionID: String
        let world: WKContentWorld

        init(extensionID: String, world: WKContentWorld) {
            self.extensionID = extensionID
            self.world = world
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage,
            replyHandler: @escaping (Any?, String?) -> Void
        ) {
            ExtensionContentScripts.shared.handleUserScriptMessage(
                extensionID: extensionID, world: world, message: message, replyHandler: replyHandler
            )
        }
    }

    // MARK: Registering

    /// Firefox `contentScripts.register` / `userScripts.register` (MV2): registers and returns the
    /// id of the handle the shim gives back (`handle.unregister()` sends it back here).
    func register(_ details: [String: Any], extensionID: String, resources: URL?, defaultWorld: String) throws -> String {
        let id = "\(extensionID):\(nextID)"
        nextID += 1
        let scripts = try makeScripts(details, extensionID: extensionID, resources: resources, defaultWorld: defaultWorld)
        add(Registration(id: id, extensionID: extensionID, userScriptID: nil, details: details, scripts: scripts))
        return id
    }

    func unregister(handle id: String) {
        remove { $0.id == id }
    }

    /// Chrome `userScripts.register(scripts)` (MV3). Ids are the extension's own and must be new.
    func registerUserScripts(_ list: [[String: Any]], extensionID: String, resources: URL?) throws {
        var seen = Set(registrations.filter { $0.extensionID == extensionID }.compactMap(\.userScriptID))
        var made: [Registration] = []
        for details in list {
            guard let scriptID = details["id"] as? String, !scriptID.isEmpty else { throw RegistrationError("A user script needs an id.") }
            guard !seen.contains(scriptID) else { throw RegistrationError("Duplicate script ID '\(scriptID)'.") }
            _ = try Self.validatedWorldID(details["worldId"])
            seen.insert(scriptID)
            let scripts = try makeScripts(details, extensionID: extensionID, resources: resources, defaultWorld: "USER_SCRIPT")
            made.append(Registration(id: "\(extensionID):\(nextID)", extensionID: extensionID, userScriptID: scriptID, details: details, scripts: scripts))
            nextID += 1
        }
        made.forEach(add)
    }

    /// Chrome `userScripts.update(scripts)`: each entry's fields replace those of the script with its id.
    func updateUserScripts(_ list: [[String: Any]], extensionID: String, resources: URL?) throws {
        var replacements: [(old: String, new: Registration)] = []
        for changes in list {
            guard let scriptID = changes["id"] as? String,
                  let existing = registrations.first(where: { $0.extensionID == extensionID && $0.userScriptID == scriptID }) else {
                throw RegistrationError("Invalid script ID '\(changes["id"] as? String ?? "")'.")
            }
            let details = existing.details.merging(changes) { _, new in new }
            _ = try Self.validatedWorldID(details["worldId"])
            let scripts = try makeScripts(details, extensionID: extensionID, resources: resources, defaultWorld: "USER_SCRIPT")
            replacements.append((existing.id, Registration(id: existing.id, extensionID: extensionID, userScriptID: scriptID, details: details, scripts: scripts)))
        }
        for (old, new) in replacements {
            remove { $0.id == old }
            add(new)
        }
    }

    /// Chrome `userScripts.unregister({ids})`; no ids removes all of the extension's user scripts.
    func unregisterUserScripts(ids: [String]?, extensionID: String) {
        remove { registration in
            guard registration.extensionID == extensionID, let scriptID = registration.userScriptID else { return false }
            return ids?.contains(scriptID) ?? true
        }
    }

    /// Chrome `userScripts.getScripts({ids})`.
    func userScripts(ids: [String]?, extensionID: String) -> [[String: Any]] {
        registrations
            .filter { $0.extensionID == extensionID && $0.userScriptID != nil }
            .filter { ids == nil || ids!.contains($0.userScriptID!) }
            .map(\.details)
    }

    /// Drops everything an extension registered (it was disabled, removed or reloaded).
    func extensionUnloaded(_ extensionID: String) {
        remove { $0.extensionID == extensionID }
        if let apiScript = apiScripts.removeValue(forKey: extensionID) {
            for controller in controllers.allObjects where controller.responds(to: Self.removeSelector) {
                controller.perform(Self.removeSelector, with: apiScript)
            }
        }
        worldConfigs[extensionID] = nil
        let keys = messagingBridges.keys.filter { $0.extensionID == extensionID }
        keys.forEach(disableMessaging)
        let extPorts = ports.filter { $0.value.extensionID == extensionID }.map(\.key)
        extPorts.forEach { disconnectUserScriptPort(portID: $0, extensionID: extensionID) }
    }

    private func add(_ registration: Registration) {
        registrations.append(registration)
        for controller in controllers.allObjects {
            for script in registration.scripts { controller.addUserScript(script) }
        }
    }

    private func remove(where predicate: (Registration) -> Bool) {
        let gone = registrations.filter(predicate)
        guard !gone.isEmpty else { return }
        registrations.removeAll(where: predicate)
        let scripts = gone.flatMap(\.scripts)
        // `_removeUserScript:` is private but has been in WebKit for years; without it a removed
        // script stays in tabs that already have it until they are reopened.
        for controller in controllers.allObjects where controller.responds(to: Self.removeSelector) {
            for script in scripts { controller.perform(Self.removeSelector, with: script) }
        }
    }

    // MARK: Building scripts

    private func makeScripts(_ details: [String: Any], extensionID: String, resources: URL?, defaultWorld: String) throws -> [WKUserScript] {
        let include = Self.patterns(details["matches"])
        let exclude = Self.patterns(details["excludeMatches"])
        let includeGlobs = details["includeGlobs"] as? [String] ?? []
        let excludeGlobs = details["excludeGlobs"] as? [String] ?? []
        guard !include.isEmpty else { throw RegistrationError("matches is required.") }

        let world: WKContentWorld
        switch ((details["world"] as? String) ?? defaultWorld).uppercased() {
        case "MAIN": world = .page
        case "USER_SCRIPT": world = userScriptWorld(extensionID: extensionID, worldID: details["worldId"] as? String)
        default: world = .world(name: "Tuff content scripts \(extensionID)")
        }
        let time: WKUserScriptInjectionTime = (details["runAt"] as? String) == "document_start" ? .atDocumentStart : .atDocumentEnd
        let mainFrameOnly = !((details["allFrames"] as? Bool) ?? false)
        let idle = (details["runAt"] as? String ?? "document_idle") == "document_idle"

        var sources: [String] = []
        for entry in details["css"] as? [[String: Any]] ?? [] {
            sources.append(Self.styleInjector(try Self.text(of: entry, in: resources)))
        }
        let metadataJSON: String?
        if defaultWorld == "USER_SCRIPT", details["id"] == nil {
            let meta = details["scriptMetadata"] ?? NSNull()
            metadataJSON = (try? JSONSerialization.data(withJSONObject: ["m": meta])).flatMap { String(data: $0, encoding: .utf8) }
        } else {
            metadataJSON = nil
        }
        var didPrependBeforeHook = false
        for entry in details["js"] as? [[String: Any]] ?? [] {
            var code = try Self.text(of: entry, in: resources)
            if !didPrependBeforeHook, let metadataJSON {
                didPrependBeforeHook = true
                code = "if (typeof window.__tuffRunBeforeUserScript === 'function') window.__tuffRunBeforeUserScript((\(metadataJSON)).m);\n" + code
            }
            // document_idle: after DOMContentLoaded, once the page has had a moment to itself.
            if idle { code = "setTimeout(function () {\n\(code)\n}, 0);" }
            sources.append(code)
        }
        guard !sources.isEmpty else { throw RegistrationError("At least one js or css entry is required.") }
        return sources.map { source in
            let guarded: String
            if includeGlobs.isEmpty && excludeGlobs.isEmpty {
                guarded = source
            } else {
                guarded = "if (\(Self.globTest(include: includeGlobs, exclude: excludeGlobs))) {\n\(source)\n}"
            }
            return Self.makeScript(source: guarded, time: time, mainFrameOnly: mainFrameOnly, include: include, exclude: exclude, world: world)
        }
    }

    static func globRegex(_ glob: String) -> String {
        "^" + NSRegularExpression.escapedPattern(for: glob)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".") + "$"
    }

    private static func globTest(include: [String], exclude: [String]) -> String {
        let encode = { (list: [String]) in
            (try? JSONSerialization.data(withJSONObject: list.map(globRegex))).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
        return "(function(u){var t=function(l){return l.some(function(r){return new RegExp(r).test(u);});};return (!\(encode(include)).length||t(\(encode(include))))&&!t(\(encode(exclude)));})(location.href)"
    }

    /// `{code}` as given, or `{file}` read from the extension's own files.
    private static func text(of entry: [String: Any], in resources: URL?) throws -> String {
        if let code = entry["code"] as? String { return code }
        if let path = entry["file"] as? String, let resources {
            let url = resources.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).standardizedFileURL
            guard url.path.hasPrefix(resources.standardizedFileURL.path),
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw RegistrationError("Could not load file '\(path)'.")
            }
            return text
        }
        throw RegistrationError("Each js / css entry needs code or file.")
    }

    private static func styleInjector(_ css: String) -> String {
        let literal = (try? JSONSerialization.data(withJSONObject: [css])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return """
        (function () {
          var style = document.createElement('style');
          style.textContent = \(literal)[0];
          (document.head || document.documentElement).appendChild(style);
        })();
        """
    }

    /// WebKit's match-pattern parser knows `http`, `https`, `file` and `<all_urls>`; Chrome's
    /// `*://` scheme (http and https) is spelt out.
    private static func patterns(_ value: Any?) -> [String] {
        let list = value as? [String] ?? []
        return list.flatMap { pattern -> [String] in
            if pattern.hasPrefix("*://") {
                let rest = pattern.dropFirst(4)
                return ["http://" + rest, "https://" + rest]
            }
            return [pattern]
        }
    }

    // MARK: WebKit

    private static let removeSelector = NSSelectorFromString("_removeUserScript:")
    private static let initSelector = NSSelectorFromString(
        "_initWithSource:injectionTime:forMainFrameOnly:includeMatchPatternStrings:excludeMatchPatternStrings:associatedURL:contentWorld:")
    private typealias PatternInit = @convention(c) (
        AnyObject, Selector, NSString, Int, Bool, NSArray, NSArray, NSURL?, WKContentWorld
    ) -> Unmanaged<WKUserScript>

    /// A user script limited to `include` minus `exclude`. WebKit's public initializer has no
    /// URL patterns (its own extension content scripts use this private one), so the fallback
    /// checks the URL in the script itself.
    static func makeScript(
        source: String, time: WKUserScriptInjectionTime, mainFrameOnly: Bool,
        include: [String], exclude: [String], world: WKContentWorld
    ) -> WKUserScript {
        if let method = class_getInstanceMethod(WKUserScript.self, initSelector),
           let allocMethod = class_getClassMethod(WKUserScript.self, NSSelectorFromString("alloc")) {
            // alloc's +1 is handed to the initializer, which consumes it and returns its own +1.
            typealias Alloc = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>
            let allocated = unsafeBitCast(method_getImplementation(allocMethod), to: Alloc.self)(
                WKUserScript.self, NSSelectorFromString("alloc")).takeUnretainedValue()
            let initialize = unsafeBitCast(method_getImplementation(method), to: PatternInit.self)
            return initialize(allocated, initSelector, source as NSString, time.rawValue, mainFrameOnly,
                              include as NSArray, exclude as NSArray, nil, world).takeRetainedValue()
        }
        let guarded = "if (\(urlTest(include: include, exclude: exclude))) {\n\(source)\n}"
        return WKUserScript(source: guarded, injectionTime: time, forMainFrameOnly: mainFrameOnly, in: world)
    }

    /// A JavaScript condition matching `location.href` against the patterns (fallback only).
    private static func urlTest(include: [String], exclude: [String]) -> String {
        func regex(_ pattern: String) -> String {
            if pattern == "<all_urls>" { return "^(https?|file|ftp)://" }
            guard let schemeEnd = pattern.range(of: "://") else { return "$^" }
            let scheme = pattern[..<schemeEnd.lowerBound]
            var rest = pattern[schemeEnd.upperBound...]
            let slash = rest.firstIndex(of: "/") ?? rest.endIndex
            let host = rest[..<slash]
            rest = rest[slash...]
            let escape = { (s: Substring) in NSRegularExpression.escapedPattern(for: String(s)).replacingOccurrences(of: "\\*", with: ".*") }
            var hostRegex = escape(host)
            if host == "*" { hostRegex = "[^/]*" } else if host.hasPrefix("*.") { hostRegex = "([^/]*\\.)?" + escape(host.dropFirst(2)) }
            return "^" + escape(scheme) + "://" + hostRegex + (rest.isEmpty ? "/" : escape(rest)) + "$"
        }
        let encode = { (list: [String]) in
            (try? JSONSerialization.data(withJSONObject: list.map(regex))).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
        return "(function(u){var t=function(l){return l.some(function(r){return new RegExp(r).test(u);});};return t(\(encode(include)))&&!t(\(encode(exclude)));})(location.href)"
    }
}
