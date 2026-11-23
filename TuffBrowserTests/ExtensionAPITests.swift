import CryptoKit
import WebKit
import XCTest
@testable import Tuff

final class ExtensionAPIExpansionTests: XCTestCase {

    // MARK: - chrome.readingList

    func testReadingListCRUDQueryAndPersistence() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("reading-list-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        let store = ExtensionReadingList(file: file, profileProvider: { "profile-a" }, emitEvents: false)

        try store.addEntry(["url": "https://example.com/a", "title": "Article A", "hasBeenRead": false])
        try store.addEntry(["url": "https://example.com/b", "title": "Article B", "hasBeenRead": true])

        // Duplicate URL rejected.
        XCTAssertThrowsError(try store.addEntry(["url": "https://example.com/a", "title": "Dup", "hasBeenRead": false]))
        // Unsupported scheme rejected.
        XCTAssertThrowsError(try store.addEntry(["url": "ftp://example.com/x", "title": "FTP", "hasBeenRead": false]))

        // Query filtering.
        XCTAssertEqual(try store.query([:]).count, 2)
        let unread = try store.query(["hasBeenRead": false])
        XCTAssertEqual(unread.count, 1)
        XCTAssertEqual(unread[0]["url"] as? String, "https://example.com/a")
        XCTAssertEqual(unread[0]["title"] as? String, "Article A")
        XCTAssertNotNil(unread[0]["creationTime"] as? Double)
        XCTAssertNotNil(unread[0]["lastUpdateTime"] as? Double)

        let byTitle = try store.query(["title": "Article B"])
        XCTAssertEqual(byTitle.count, 1)
        XCTAssertEqual(byTitle[0]["url"] as? String, "https://example.com/b")

        // Update requires at least title or hasBeenRead.
        XCTAssertThrowsError(try store.updateEntry(["url": "https://example.com/a"]))
        try store.updateEntry(["url": "https://example.com/a", "title": "Article A (Updated)", "hasBeenRead": true])
        let updated = try store.query(["url": "https://example.com/a"])
        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated[0]["title"] as? String, "Article A (Updated)")
        XCTAssertEqual(updated[0]["hasBeenRead"] as? Bool, true)

        // Persistence round-trip.
        let reloaded = ExtensionReadingList(file: file, profileProvider: { "profile-a" }, emitEvents: false)
        XCTAssertEqual(try reloaded.query([:]).count, 2)

        // Remove entry and verify error on second remove.
        try reloaded.removeEntry(["url": "https://example.com/b"])
        XCTAssertEqual(try reloaded.query([:]).count, 1)
        XCTAssertThrowsError(try reloaded.removeEntry(["url": "https://example.com/b"]))
    }

    // MARK: - chrome.ttsEngine

    func testTTSEngineVoicesAndLifecycle() throws {
        let tts = ExtensionTTS.shared
        let extID = "tts-test-\(UUID().uuidString)"
        defer { tts.extensionUnloaded(extID) }

        tts.extensionLoaded(extID, manifest: [
            "tts_engine": [
                "voices": [
                    ["voice_name": "Tuff Static Voice", "lang": "en-US", "event_types": ["start", "end"]],
                ],
            ],
        ])
        XCTAssertEqual(tts.engineVoices[extID]?.map(\.voiceName), ["Tuff Static Voice"])

        // updateVoices replaces the extension's voice list.
        tts.updateVoices([
            ["voiceName": "Custom Voice", "lang": "en-GB", "remote": true, "eventTypes": ["start", "word", "end"]],
        ], extensionID: extID)
        XCTAssertEqual(tts.engineVoices[extID]?.map(\.voiceName), ["Custom Voice"])

        // getVoices includes custom engine voices.
        let voicesExp = expectation(description: "getVoices")
        var fetchedVoices: [[String: Any]] = []
        tts.getVoices { result in
            fetchedVoices = result as? [[String: Any]] ?? []
            voicesExp.fulfill()
        }
        wait(for: [voicesExp], timeout: 2)
        XCTAssertTrue(fetchedVoices.contains { ($0["voiceName"] as? String) == "Custom Voice" && ($0["extensionId"] as? String) == extID })

        // speak routes to the matching engine voice.
        let speakExp = expectation(description: "speak")
        tts.speak(options: ["utterance": "Hello world", "voiceName": "Custom Voice"], extensionID: "caller-ext", finish: { _ in
            speakExp.fulfill()
        }, fail: { error in
            XCTFail("speak failed: \(error)")
            speakExp.fulfill()
        })
        wait(for: [speakExp], timeout: 2)

        let active = try XCTUnwrap(tts.activeEngineSpeech)
        XCTAssertEqual(active.engineExtensionID, extID)
        XCTAssertEqual(active.callerExtensionID, "caller-ext")

        // Wrong extension cannot send events for another engine's request.
        XCTAssertThrowsError(try tts.sendTtsEvent(requestID: active.requestID, event: ["type": "start"], from: "other-ext"))

        // Non-terminal event keeps speech active; terminal event clears it.
        try tts.sendTtsEvent(requestID: active.requestID, event: ["type": "start", "charIndex": 0], from: extID)
        XCTAssertNotNil(tts.activeEngineSpeech)
        try tts.sendTtsEvent(requestID: active.requestID, event: ["type": "end", "charIndex": 11], from: extID)
        XCTAssertNil(tts.activeEngineSpeech)
    }

    // MARK: - chrome.userScripts world config & execute

    func testUserScriptsWorldConfigurations() throws {
        let scripts = ExtensionContentScripts.shared
        let extID = "us-world-\(UUID().uuidString)"
        defer { scripts.extensionUnloaded(extID) }

        XCTAssertTrue(scripts.getWorldConfigurations(extensionID: extID).isEmpty)

        // Reserved underscore prefix is rejected.
        XCTAssertThrowsError(try scripts.configureWorld(["worldId": "_reserved"], extensionID: extID))

        try scripts.configureWorld(["csp": "script-src 'self'", "messaging": true], extensionID: extID)
        try scripts.configureWorld(["worldId": "sandbox", "messaging": false], extensionID: extID)

        let configs = scripts.getWorldConfigurations(extensionID: extID)
        XCTAssertEqual(configs.count, 2)
        XCTAssertNil(configs[0]["worldId"])
        XCTAssertEqual(configs[0]["messaging"] as? Bool, true)
        XCTAssertEqual(configs[0]["csp"] as? String, "script-src 'self'")
        XCTAssertEqual(configs[1]["worldId"] as? String, "sandbox")
        XCTAssertEqual(configs[1]["messaging"] as? Bool, false)

        try scripts.resetWorldConfiguration(worldID: "sandbox", extensionID: extID)
        XCTAssertEqual(scripts.getWorldConfigurations(extensionID: extID).count, 1)

        try scripts.resetWorldConfiguration(worldID: nil, extensionID: extID)
        XCTAssertTrue(scripts.getWorldConfigurations(extensionID: extID).isEmpty)
    }

    @MainActor
    func testUserScriptsExecuteInMainAndIsolatedWorldsWithMessaging() async throws {
        let extID = "us-exec-\(UUID().uuidString)"
        let browser = BrowserState.makeIncognito()
        let tab = browser.newTab(url: nil, select: true)
        defer {
            ExtensionContentScripts.shared.extensionUnloaded(extID)
            tab.tearDown()
        }

        tab.wake()
        let webView = try XCTUnwrap(tab.webView)
        webView.loadHTMLString("<!doctype html><html><body><script>window.pageSecret = 42;</script></body></html>", baseURL: URL(string: "https://example.com/")!)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let v = try? await webView.evaluateJavaScript("window.pageSecret") as? Int, v == 42 { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        // MAIN world sees pageSecret.
        let mainResult: Any? = try await withCheckedThrowingContinuation { cont in
            ExtensionContentScripts.shared.execute(
                in: tab,
                details: ["world": "MAIN", "js": [["code": "window.pageSecret + 1"]]],
                context: nil, extensionID: extID, resources: nil,
                finish: { cont.resume(returning: $0) }, fail: { cont.resume(throwing: $0) }
            )
        }
        let mainList = try XCTUnwrap(mainResult as? [[String: Any]])
        XCTAssertEqual(mainList.first?["result"] as? Int, 43)

        // USER_SCRIPT world with messaging: true is isolated from pageSecret and exposes chrome.runtime.
        try ExtensionContentScripts.shared.configureWorld(["messaging": true], extensionID: extID)
        let usResult: Any? = try await withCheckedThrowingContinuation { cont in
            ExtensionContentScripts.shared.execute(
                in: tab,
                details: [
                    "world": "USER_SCRIPT",
                    "js": [["code": "({ secret: typeof window.pageSecret, id: chrome.runtime.id, send: typeof chrome.runtime.sendMessage, connect: typeof chrome.runtime.connect })"]],
                ],
                context: nil, extensionID: extID, resources: nil,
                finish: { cont.resume(returning: $0) }, fail: { cont.resume(throwing: $0) }
            )
        }
        let usList = try XCTUnwrap(usResult as? [[String: Any]])
        let payload = try XCTUnwrap(usList.first?["result"] as? [String: Any])
        XCTAssertEqual(payload["secret"] as? String, "undefined")
        XCTAssertEqual(payload["id"] as? String, extID)
        XCTAssertEqual(payload["send"] as? String, "function")
        XCTAssertEqual(payload["connect"] as? String, "function")
    }

    // MARK: - browser.captivePortal

    func testCaptivePortalClassificationAndStateTransitions() {
        XCTAssertEqual(ExtensionCaptivePortal.classify(statusCode: 200, body: "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"), .clear)
        XCTAssertEqual(ExtensionCaptivePortal.classify(statusCode: 200, body: "<html>Sign in to Wi-Fi</html>"), .captive)
        XCTAssertEqual(ExtensionCaptivePortal.classify(statusCode: 302, body: nil), .captive)
        XCTAssertEqual(ExtensionCaptivePortal.classify(statusCode: 503, body: nil), .unreachable)

        let portal = ExtensionCaptivePortal(emitEvents: false)
        XCTAssertEqual(portal.state, .unknown)
        XCTAssertEqual(portal.getLastChecked(), 0)

        let first = portal.apply(probe: .clear)
        XCTAssertEqual(first.stateChanged, "not_captive")
        XCTAssertEqual(first.connectivity, "clear")

        let locked = portal.apply(probe: .captive)
        XCTAssertEqual(locked.stateChanged, "locked_portal")
        XCTAssertNil(locked.connectivity)

        let unlocked = portal.apply(probe: .clear)
        XCTAssertEqual(unlocked.stateChanged, "unlocked_portal")
        XCTAssertEqual(unlocked.connectivity, "captive")

        let offline = portal.apply(probe: .unreachable)
        XCTAssertEqual(offline.stateChanged, "unknown")
        XCTAssertNil(offline.connectivity)
    }

    // MARK: - Bookmarks dates & browsingData.removePasswords

    func testBookmarkDatesPersistAndUpdateOnChildChanges() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bm-dates-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let profile = UUID()
        let store = BookmarkStore(file: file)

        let folder = store.addFolder(named: "Reading", profile: profile)
        XCTAssertNotNil(folder.dateAdded)
        XCTAssertNotNil(folder.dateGroupModified)

        let item = store.add(url: URL(string: "https://swift.org")!, title: "Swift", profile: profile, into: folder.id)
        XCTAssertNotNil(item.dateAdded)
        store.saveNow(synchronously: true)

        let reloaded = BookmarkStore(file: file)
        let loadedFolder = reloaded.bookmark(withID: folder.id, profile: profile)
        XCTAssertNotNil(loadedFolder?.dateAdded)
        XCTAssertNotNil(loadedFolder?.dateGroupModified)
        XCTAssertNotNil(loadedFolder?.children.first?.dateAdded)
    }

    func testPasswordStoreRemoveByOriginsAndSince() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pw-rm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = PasswordStore(folder: dir)
        let profile = UUID()
        store.save(origin: "https://a.example", username: "u1", password: "p1", profile: profile)
        store.save(origin: "https://b.example", username: "u2", password: "p2", profile: profile)
        store.save(origin: "https://c.example", username: "u3", password: "p3", profile: profile)

        // Exclude c.example and only match a.example.
        store.remove(origins: ["https://a.example"])
        XCTAssertEqual(store.logins.map(\.origin), ["https://b.example", "https://c.example"])

        // Exclude c.example removes b.example only.
        store.remove(excludeOrigins: ["https://c.example"])
        XCTAssertEqual(store.logins.map(\.origin), ["https://c.example"])

        // Future `since` removes nothing.
        store.remove(since: Date().addingTimeInterval(60))
        XCTAssertEqual(store.logins.count, 1)

        // Unfiltered removes everything remaining.
        store.remove()
        XCTAssertTrue(store.logins.isEmpty)
    }

    // MARK: - system.display.getDisplayLayout

    func testDisplayLayoutGeometry() {
        let primary = ExtensionSystem.DisplayRect(id: "1", left: 0, top: 0, width: 1440, height: 900)
        XCTAssertTrue(ExtensionSystem.displayLayout(for: [primary]).isEmpty)

        let right = ExtensionSystem.DisplayRect(id: "2", left: 1440, top: -180, width: 1920, height: 1080)
        let farRight = ExtensionSystem.DisplayRect(id: "3", left: 3360, top: 0, width: 1280, height: 720)
        let layout = ExtensionSystem.displayLayout(for: [primary, right, farRight])
        XCTAssertEqual(layout.count, 2)
        XCTAssertEqual(layout[0]["id"] as? String, "2")
        XCTAssertEqual(layout[0]["parentId"] as? String, "1")
        XCTAssertEqual(layout[0]["position"] as? String, "right")
        XCTAssertEqual(layout[0]["offset"] as? Int, -180)
        XCTAssertEqual(layout[1]["id"] as? String, "3")
        XCTAssertEqual(layout[1]["parentId"] as? String, "2")
        XCTAssertEqual(layout[1]["position"] as? String, "right")
        XCTAssertEqual(layout[1]["offset"] as? Int, 180)

        let above = ExtensionSystem.DisplayRect(id: "4", left: 100, top: -1080, width: 1920, height: 1080)
        let topLayout = ExtensionSystem.displayLayout(for: [primary, above])
        XCTAssertEqual(topLayout.first?["position"] as? String, "top")
        XCTAssertEqual(topLayout.first?["offset"] as? Int, 100)
    }

    // MARK: - declarativeContent PageStateMatcher css

    @MainActor
    func testDeclarativeContentCSSMatching() async throws {
        let rule: [String: Any] = [
            "conditions": [["pageUrl": ["hostEquals": "example.com"], "css": ["video", ".player"]]],
            "actions": [["instanceType": "declarativeContent.ShowAction"]],
        ]
        let url = URL(string: "https://example.com/watch")!
        XCTAssertFalse(ExtensionDeclarativeContent.matches(rule, url: url, matchedCSS: []))
        XCTAssertFalse(ExtensionDeclarativeContent.matches(rule, url: url, matchedCSS: ["video"]))
        XCTAssertTrue(ExtensionDeclarativeContent.matches(rule, url: url, matchedCSS: ["video", ".player"]))

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        webView.loadHTMLString("<!doctype html><html><body><div class='visible'>hi</div><div class='hidden' style='display:none'>no</div></body></html>", baseURL: url)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let text = try? await webView.evaluateJavaScript("document.querySelector('.visible')?.textContent") as? String, text == "hi" { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let matched: Set<String> = await withCheckedContinuation { cont in
            ExtensionDeclarativeContent.checkCSS([".visible", ".hidden", ".missing"], in: webView) { cont.resume(returning: $0) }
        }
        XCTAssertTrue(matched.contains(".visible"))
        XCTAssertFalse(matched.contains(".hidden"))
        XCTAssertFalse(matched.contains(".missing"))
    }

    // MARK: - contextualIdentities.move & contentSettings.sound

    func testContextualIdentitiesReorder() {
        let a = Profile(name: "A", icon: "person.fill", usesSharedStore: true)
        let b = Profile(name: "B", icon: "briefcase.fill", usesSharedStore: false)
        let c = Profile(name: "C", icon: "cart.fill", usesSharedStore: false)
        var profiles = [a, b, c]

        ExtensionContainers.reorder(&profiles, moving: [c], to: 0)
        XCTAssertEqual(profiles.map(\.name), ["C", "A", "B"])

        ExtensionContainers.reorder(&profiles, moving: [c, a], to: -1)
        XCTAssertEqual(profiles.map(\.name), ["B", "C", "A"])
    }

    func testContentSettingsSoundSetAndClear() throws {
        let extID = "sound-test-\(UUID().uuidString)"
        let url = "https://noisy.example/video"
        defer { ExtensionContentSettings.shared.extensionRemoved(extID) }

        let before = try ExtensionContentSettings.shared.get(type: "sound", args: ["primaryUrl": url])
        XCTAssertEqual(before["setting"] as? String, "allow")

        try ExtensionContentSettings.shared.set(
            type: "sound",
            args: ["primaryPattern": "https://noisy.example/*", "setting": "block"],
            extensionID: extID
        )
        let blocked = try ExtensionContentSettings.shared.get(type: "sound", args: ["primaryUrl": url])
        XCTAssertEqual(blocked["setting"] as? String, "block")

        ExtensionContentSettings.shared.clear(type: "sound", extensionID: extID)
        let after = try ExtensionContentSettings.shared.get(type: "sound", args: ["primaryUrl": url])
        XCTAssertEqual(after["setting"] as? String, "allow")
    }

    // MARK: - chrome.webAuthenticationProxy

    @MainActor
    func testWebAuthenticationProxyEndToEnd() async throws {
        let proxy = ExtensionWebAuthn.shared
        let extA = "webauthn-a-\(UUID().uuidString)"
        let extB = "webauthn-b-\(UUID().uuidString)"
        var events: [(event: String, args: [Any], extID: String)] = []
        proxy.testEventSink = { event, args, extID in
            events.append((event, args, extID))
        }
        defer {
            proxy.testEventSink = nil
            proxy.extensionUnloaded(extA)
            proxy.extensionUnloaded(extB)
        }

        // Attach & exclusivity.
        try proxy.attach(extensionID: extA)
        XCTAssertThrowsError(try proxy.attach(extensionID: extA))
        XCTAssertThrowsError(try proxy.attach(extensionID: extB))
        XCTAssertThrowsError(try proxy.detach(extensionID: extB))

        let config = WKWebViewConfiguration()
        proxy.attach(config.userContentController)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        webView.loadHTMLString("<!doctype html><html><body>WebAuthn Test</body></html>", baseURL: URL(string: "https://auth.example/")!)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let active = try? await webView.evaluateJavaScript("window.__tuffWebAuthnActive") as? Bool, active { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        // 1. isUserVerifyingPlatformAuthenticatorAvailable
        let uvpaaTask = Task<Bool, Error> {
            try await webView.callAsyncJavaScript(
                "return await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable();",
                arguments: [:], in: nil, contentWorld: .page
            ) as? Bool ?? false
        }
        let uvpaaDeadline = Date().addingTimeInterval(5)
        while Date() < uvpaaDeadline && !events.contains(where: { $0.event == "webAuthenticationProxy.onIsUvpaaRequest" }) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let uvpaaEvent = try XCTUnwrap(events.first { $0.event == "webAuthenticationProxy.onIsUvpaaRequest" })
        let uvpaaID = try XCTUnwrap((uvpaaEvent.args.first as? [String: Any])?["requestId"] as? Int)
        try proxy.completeIsUvpaaRequest(["requestId": uvpaaID, "isUvpaa": true], extensionID: extA)
        let uvpaaResult = try await uvpaaTask.value
        XCTAssertTrue(uvpaaResult)

        // 2. navigator.credentials.create
        let createTask = Task<[String: Any], Error> {
            let val = try await webView.callAsyncJavaScript(
                """
                const cred = await navigator.credentials.create({
                  publicKey: {
                    challenge: new Uint8Array([1, 2, 3, 4]),
                    rp: { name: 'Example', id: 'auth.example' },
                    user: { id: new Uint8Array([9, 8]), name: 'alice', displayName: 'Alice' },
                    pubKeyCredParams: [{ type: 'public-key', alg: -7 }],
                  }
                });
                return {
                  id: cred.id,
                  type: cred.type,
                  rawLen: cred.rawId.byteLength,
                  clientDataLen: cred.response.clientDataJSON.byteLength,
                  transports: cred.response.getTransports(),
                };
                """,
                arguments: [:], in: nil, contentWorld: .page
            )
            return val as? [String: Any] ?? [:]
        }
        let createDeadline = Date().addingTimeInterval(5)
        while Date() < createDeadline && !events.contains(where: { $0.event == "webAuthenticationProxy.onCreateRequest" }) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let createEvent = try XCTUnwrap(events.first { $0.event == "webAuthenticationProxy.onCreateRequest" })
        let createPayload = try XCTUnwrap(createEvent.args.first as? [String: Any])
        let createID = try XCTUnwrap(createPayload["requestId"] as? Int)
        let reqJSON = try XCTUnwrap(createPayload["requestDetailsJson"] as? String)
        let reqObj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reqJSON.utf8)) as? [String: Any])
        XCTAssertEqual(reqObj["challenge"] as? String, "AQIDBA")
        let responseJSON = #"{"id":"Y3JlZA","rawId":"Y3JlZA","type":"public-key","response":{"clientDataJSON":"e30","attestationObject":"AQID","transports":["internal"]}}"#
        try proxy.completeCreateRequest(["requestId": createID, "responseJson": responseJSON], extensionID: extA)
        let created = try await createTask.value
        XCTAssertEqual(created["id"] as? String, "Y3JlZA")
        XCTAssertEqual(created["type"] as? String, "public-key")
        XCTAssertEqual(created["rawLen"] as? Int, 4)
        XCTAssertEqual(created["clientDataLen"] as? Int, 2)
        XCTAssertEqual(created["transports"] as? [String], ["internal"])

        // 3. navigator.credentials.get + AbortSignal -> onRequestCanceled
        let abortTask = Task<String, Error> {
            let val = try await webView.callAsyncJavaScript(
                """
                const ac = new AbortController();
                setTimeout(() => ac.abort(), 80);
                try {
                  await navigator.credentials.get({
                    signal: ac.signal,
                    publicKey: { challenge: new Uint8Array([5, 6]) }
                  });
                  return 'resolved';
                } catch (e) {
                  return e.name;
                }
                """,
                arguments: [:], in: nil, contentWorld: .page
            )
            return val as? String ?? ""
        }
        let abortResult = try await abortTask.value
        XCTAssertEqual(abortResult, "AbortError")
        let cancelDeadline = Date().addingTimeInterval(2)
        while Date() < cancelDeadline && !events.contains(where: { $0.event == "webAuthenticationProxy.onRequestCanceled" }) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(events.contains { $0.event == "webAuthenticationProxy.onRequestCanceled" })

        try proxy.detach(extensionID: extA)
        XCTAssertNil(proxy.attachedExtensionID)
    }

    // MARK: - chrome.declarativeNetRequest

    func testDeclarativeNetRequestStaticCountAndMatchOutcome() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dnr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let staticRules: [[String: Any]] = [
            [
                "id": 10,
                "priority": 1,
                "action": ["type": "block"],
                "condition": ["urlFilter": "||ads.tracker.example^", "resourceTypes": ["script", "image"]],
            ],
            [
                "id": 11,
                "priority": 2,
                "action": ["type": "allow"],
                "condition": ["urlFilter": "||ads.tracker.example/safe.js", "resourceTypes": ["script"]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: staticRules).write(to: dir.appendingPathComponent("rules.json"))
        let manifest: [String: Any] = [
            "declarative_net_request": [
                "rule_resources": [
                    ["id": "ruleset_1", "enabled": true, "path": "rules.json"],
                ],
            ],
        ]

        XCTAssertEqual(
            ExtensionDNR.availableStaticRuleCount(manifest: manifest, resources: dir, enabledRulesetIDs: ["ruleset_1"]),
            ExtensionDNR.guaranteedMinimumStaticRules - 2
        )
        XCTAssertEqual(
            ExtensionDNR.availableStaticRuleCount(manifest: manifest, resources: dir, enabledRulesetIDs: []),
            ExtensionDNR.guaranteedMinimumStaticRules
        )

        // Block rule matches third-party script.
        let blocked = try ExtensionDNR.testMatchOutcome(
            request: ["url": "https://sub.ads.tracker.example/ad.js", "type": "script", "initiator": "https://news.example"],
            manifest: manifest, resources: dir, enabledRulesetIDs: ["ruleset_1"], dynamicRules: [], sessionRules: []
        )
        let blockedList = try XCTUnwrap(blocked["matchedRules"] as? [[String: Any]])
        XCTAssertEqual(blockedList.count, 1)
        XCTAssertEqual(blockedList[0]["ruleId"] as? Int, 10)
        XCTAssertEqual(blockedList[0]["rulesetId"] as? String, "ruleset_1")

        // Higher-priority allow rule wins over block rule.
        let allowed = try ExtensionDNR.testMatchOutcome(
            request: ["url": "https://ads.tracker.example/safe.js", "type": "script"],
            manifest: manifest, resources: dir, enabledRulesetIDs: ["ruleset_1"], dynamicRules: [], sessionRules: []
        )
        let allowedList = try XCTUnwrap(allowed["matchedRules"] as? [[String: Any]])
        XCTAssertEqual(allowedList.first?["ruleId"] as? Int, 11)

        // Dynamic rule with regexFilter & domainType thirdParty.
        let dynamicRules: [[String: Any]] = [
            [
                "id": 99,
                "priority": 5,
                "action": ["type": "block"],
                "condition": ["regexFilter": #"^https://pixel\.other\.example/t\d+"#, "domainType": "thirdParty"],
            ],
        ]
        let dynThird = try ExtensionDNR.testMatchOutcome(
            request: ["url": "https://pixel.other.example/t42", "type": "image", "initiator": "https://news.example"],
            manifest: manifest, resources: dir, enabledRulesetIDs: [], dynamicRules: dynamicRules, sessionRules: []
        )
        XCTAssertEqual((dynThird["matchedRules"] as? [[String: Any]])?.first?["rulesetId"] as? String, "_dynamic")

        let dynFirst = try ExtensionDNR.testMatchOutcome(
            request: ["url": "https://pixel.other.example/t42", "type": "image", "initiator": "https://www.other.example"],
            manifest: manifest, resources: dir, enabledRulesetIDs: [], dynamicRules: dynamicRules, sessionRules: []
        )
        XCTAssertTrue((dynFirst["matchedRules"] as? [[String: Any]])?.isEmpty == true)
    }

    // MARK: - tabs.moveInSuccession & cookies.getPartitionKey

    func testTabsMoveInSuccessionAlgorithm() {
        let a = Tab(url: URL(string: "https://a.example"))
        let b = Tab(url: URL(string: "https://b.example"))
        let c = Tab(url: URL(string: "https://c.example"))
        let d = Tab(url: URL(string: "https://d.example"))
        let all = [a, b, c, d]

        // Default: a -> b -> c
        ExtensionTabs.moveInSuccession(tabs: [a, b], target: c, allTabs: all, append: false, insert: false)
        XCTAssertTrue(a.successorTab === b)
        XCTAssertTrue(b.successorTab === c)
        XCTAssertNil(c.successorTab)

        // insert: true splices [d] before c, so b now points to d and d points to c.
        ExtensionTabs.moveInSuccession(tabs: [d], target: c, allTabs: all, append: false, insert: true)
        XCTAssertTrue(b.successorTab === d)
        XCTAssertTrue(d.successorTab === c)

        // append: true, insert: true splices [a] after d (inheriting d's old successor c).
        ExtensionTabs.moveInSuccession(tabs: [a], target: d, allTabs: all, append: true, insert: true)
        XCTAssertTrue(d.successorTab === a)
        XCTAssertTrue(a.successorTab === c)
    }

    func testCookiesGetPartitionKey() throws {
        let top = ExtensionCookies.partitionKey(for: URL(string: "https://sub.news.example.com/article"), frameID: 0)
        let key1 = try XCTUnwrap(top["partitionKey"] as? [String: Any])
        XCTAssertEqual(key1["topLevelSite"] as? String, "https://example.com")
        XCTAssertEqual(key1["hasCrossSiteAncestor"] as? Bool, false)

        let uk = ExtensionCookies.partitionKey(for: URL(string: "https://a.shop.co.uk/cart"), frameID: 3)
        let key2 = try XCTUnwrap(uk["partitionKey"] as? [String: Any])
        XCTAssertEqual(key2["topLevelSite"] as? String, "https://shop.co.uk")
        XCTAssertEqual(key2["hasCrossSiteAncestor"] as? Bool, true)

        let blank = ExtensionCookies.partitionKey(for: URL(string: "about:blank"), frameID: 0)
        let key3 = try XCTUnwrap(blank["partitionKey"] as? [String: Any])
        XCTAssertTrue(key3.isEmpty)
    }

    // MARK: - bookmarks.onChildrenReordered

    func testBookmarksChildrenReorderedDetection() {
        let a = Bookmark(title: "A", url: URL(string: "https://a.example"))
        let b = Bookmark(title: "B", url: URL(string: "https://b.example"))
        let c = Bookmark(title: "C", url: URL(string: "https://c.example"))
        let d = Bookmark(title: "D", url: URL(string: "https://d.example"))

        // Reversing 4 items displaces 3 items; bulk -> onChildrenReordered.
        let bulkReordered = ExtensionBookmarks.reorderedFolders(before: [a, b, c, d], after: [d, c, b, a], bulk: true)
        XCTAssertEqual(bulkReordered.count, 1)
        XCTAssertEqual(bulkReordered[0].parentID, ExtensionBookmarks.barID)
        XCTAssertEqual(bulkReordered[0].childIDs, [d, c, b, a].map(\.id.uuidString))

        // Non-bulk single move does not fire onChildrenReordered.
        let singleMove = ExtensionBookmarks.reorderedFolders(before: [a, b, c, d], after: [d, a, b, c], bulk: false)
        XCTAssertTrue(singleMove.isEmpty)
    }

    // MARK: - contentSettings images / cookies / automaticDownloads

    func testContentSettingsImagesCookiesAndAutomaticDownloads() throws {
        let extID = "cs-ext-\(UUID().uuidString)"
        let url = "https://media.example/page"
        defer { ExtensionContentSettings.shared.extensionRemoved(extID) }

        try ExtensionContentSettings.shared.set(
            type: "images",
            args: ["primaryPattern": "https://media.example/*", "setting": "block"],
            extensionID: extID
        )
        XCTAssertEqual(try ExtensionContentSettings.shared.get(type: "images", args: ["primaryUrl": url])["setting"] as? String, "block")

        try ExtensionContentSettings.shared.set(
            type: "cookies",
            args: ["primaryPattern": "https://media.example/*", "setting": "block"],
            extensionID: extID
        )
        XCTAssertEqual(try ExtensionContentSettings.shared.get(type: "cookies", args: ["primaryUrl": url])["setting"] as? String, "block")

        let rules = SiteSettings.shared.contentRulesJSON()
        XCTAssertTrue(rules.contains { ($0["action"] as? [String: Any])?["type"] as? String == "block" })
        XCTAssertTrue(rules.contains { ($0["action"] as? [String: Any])?["type"] as? String == "block-cookies" })

        try ExtensionContentSettings.shared.set(
            type: "cookies",
            args: ["primaryPattern": "https://media.example/*", "setting": "session_only"],
            extensionID: extID
        )
        XCTAssertEqual(try ExtensionContentSettings.shared.get(type: "cookies", args: ["primaryUrl": url])["setting"] as? String, "session_only")

        try ExtensionContentSettings.shared.set(
            type: "automaticDownloads",
            args: ["primaryPattern": "https://media.example/*", "setting": "block"],
            extensionID: extID
        )
        XCTAssertEqual(try ExtensionContentSettings.shared.get(type: "automaticDownloads", args: ["primaryUrl": url])["setting"] as? String, "block")

        ExtensionContentSettings.shared.extensionRemoved(extID)
        XCTAssertEqual(try ExtensionContentSettings.shared.get(type: "images", args: ["primaryUrl": url])["setting"] as? String, "allow")
        XCTAssertEqual(try ExtensionContentSettings.shared.get(type: "cookies", args: ["primaryUrl": url])["setting"] as? String, "allow")
        XCTAssertEqual(try ExtensionContentSettings.shared.get(type: "automaticDownloads", args: ["primaryUrl": url])["setting"] as? String, "ask")
    }

    // MARK: - runtime.getPackageDirectoryEntry & menus.contexts

    func testPackageDirectoryEntryListingAndSandboxing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pkg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("icons"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "{}".write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "shim".write(to: dir.appendingPathComponent("__tuff_compat.js"), atomically: true, encoding: .utf8)
        try "png".write(to: dir.appendingPathComponent("icons/icon.png"), atomically: true, encoding: .utf8)

        let entries = try ExtensionAPIBridge.packageList(path: "/", in: dir)
        let names = entries.compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["icons", "manifest.json"])
        XCTAssertFalse(names.contains("__tuff_compat.js"))

        let stat = try ExtensionAPIBridge.packageStat(path: "/icons/icon.png", in: dir)
        XCTAssertEqual(stat["isFile"] as? Bool, true)
        XCTAssertEqual(stat["fullPath"] as? String, "/icons/icon.png")

        // Internal Tuff shim files are hidden.
        XCTAssertThrowsError(try ExtensionAPIBridge.packageStat(path: "/__tuff_compat.js", in: dir))
    }

    func testMenusContextsExtraction() {
        let menu = NSMenu()
        let openLink = NSMenuItem(title: "Open Link", action: nil, keyEquivalent: "")
        openLink.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLink")
        menu.addItem(openLink)

        let capture = ExtensionMenus.CapturedTarget(
            timestamp: Date(), targetElementID: 12345, editable: false,
            linkURL: "https://example.com", linkText: "Example",
            srcURL: "https://example.com/a.png", mediaType: "image",
            selectionText: "hello", frameURL: "https://page.example/"
        )
        let contexts = ExtensionMenus.contexts(from: menu, capture: capture)
        XCTAssertTrue(contexts.contains("all"))
        XCTAssertTrue(contexts.contains("link"))
        XCTAssertTrue(contexts.contains("image"))
        XCTAssertTrue(contexts.contains("selection"))
        XCTAssertFalse(contexts.contains("editable"))
    }

    // MARK: - Bookmarks separators

    func testBookmarkSeparatorsPersistAndSkipSearchAndPages() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bm-sep-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let profile = UUID()
        let store = BookmarkStore(file: file)

        let folder = store.addFolder(named: "Links", profile: profile)
        let page = store.add(url: URL(string: "https://example.com")!, title: "Example", profile: profile, into: folder.id)
        let sep = store.addSeparator(profile: profile, into: folder.id, at: 1)

        XCTAssertTrue(sep.isSeparator)
        XCTAssertFalse(sep.isFolder)
        XCTAssertEqual(store.bookmark(withID: folder.id, profile: profile)?.children.count, 2)
        XCTAssertEqual(store.bookmark(withID: folder.id, profile: profile)?.pages.map(\.id), [page.id])
        XCTAssertEqual(store.search("Separator", limit: 10, profile: profile).count, 0)

        // Updating a separator is a no-op.
        store.update(sep.id, title: "Ignored", url: URL(string: "https://bad.example"), profile: profile)
        let updatedSep = try XCTUnwrap(store.bookmark(withID: sep.id, profile: profile))
        XCTAssertTrue(updatedSep.isSeparator)
        XCTAssertNil(updatedSep.url)

        // Persistence round-trip.
        store.saveNow(synchronously: true)
        let reloaded = BookmarkStore(file: file)
        let loadedSep = try XCTUnwrap(reloaded.bookmark(withID: sep.id, profile: profile))
        XCTAssertTrue(loadedSep.isSeparator)
        XCTAssertFalse(loadedSep.isFolder)

        // Sync maps separator to `.other` rather than a broken bookmark.
        var ids: [UUID: String] = [:]
        let tree = BookmarkMerge.localTree(reloaded.items(for: profile), base: [:], ids: &ids)
        let sepGUID = try XCTUnwrap(ids[sep.id])
        XCTAssertEqual(tree[sepGUID]?.kind, .other)
    }

    // MARK: - tabs.setZoomSettings

    @MainActor
    func testTabZoomSettingsModesAndScopes() throws {
        let browser = BrowserState.makeIncognito()
        let tabA = browser.newTab(url: URL(string: "https://zoom-test.example/a"), select: true)
        let tabB = browser.newTab(url: URL(string: "https://zoom-test.example/b"), select: false)
        defer {
            tabA.tearDown()
            tabB.tearDown()
        }

        XCTAssertEqual(tabA.zoomMode, .automatic)
        XCTAssertEqual(tabA.zoomScope, .perOrigin)

        // Manual + per-origin is rejected per Chrome spec.
        XCTAssertThrowsError(try tabA.setZoomSettings(mode: "manual", scope: "per-origin"))
        XCTAssertThrowsError(try tabA.setZoomSettings(mode: "invalid", scope: nil))

        // Per-tab automatic zoom stays isolated from tabB.
        try tabA.setZoomSettings(mode: "automatic", scope: "per-tab")
        tabA.setZoom(1.5)
        XCTAssertEqual(Double(tabA.pageZoom), 1.5, accuracy: 0.001)
        XCTAssertEqual(Double(tabB.pageZoom), SiteZoom.defaultZoom, accuracy: 0.001)

        // Manual defaults to per-tab and preserves zoom across applySiteZoom().
        try tabA.setZoomSettings(mode: "manual", scope: nil)
        XCTAssertEqual(tabA.zoomScope, .perTab)
        tabA.setZoom(1.75)
        tabA.applySiteZoom()
        XCTAssertEqual(Double(tabA.pageZoom), 1.75, accuracy: 0.001)

        // Disabled resets to default and ignores subsequent zoom changes.
        try tabA.setZoomSettings(mode: "disabled", scope: "per-tab")
        XCTAssertEqual(Double(tabA.pageZoom), SiteZoom.defaultZoom, accuracy: 0.001)
        tabA.setZoom(2.0)
        XCTAssertEqual(Double(tabA.pageZoom), SiteZoom.defaultZoom, accuracy: 0.001)
    }

    // MARK: - declarativeNetRequest.updateStaticRules / getDisabledRuleIds

    func testDNRUpdateStaticRulesAndDisabledRuleIds() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dnr-static-\(UUID().uuidString)", isDirectory: true)
        let stateFile = dir.appendingPathComponent("dnr-disabled.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let rulesJSON = """
        [
          { "id": 1, "priority": 1, "action": { "type": "block" }, "condition": { "urlFilter": "||ads.example^" } },
          { "id": 2, "priority": 1, "action": { "type": "block" }, "condition": { "urlFilter": "||tracker.example^" } }
        ]
        """
        try rulesJSON.write(to: dir.appendingPathComponent("rules.json"), atomically: true, encoding: .utf8)
        let manifest: [String: Any] = [
            "declarative_net_request": [
                "rule_resources": [["id": "r1", "enabled": true, "path": "rules.json"]],
            ],
        ]

        let dnr = ExtensionDNR(file: stateFile)
        let extID = "ext-dnr-1"

        XCTAssertThrowsError(try dnr.disabledRuleIDs(rulesetID: "missing", extensionID: extID, manifest: manifest))
        XCTAssertEqual(try dnr.disabledRuleIDs(rulesetID: "r1", extensionID: extID, manifest: manifest), [])

        try dnr.updateStaticRules(rulesetID: "r1", disableRuleIDs: [1], enableRuleIDs: [], extensionID: extID, manifest: manifest, resources: dir)
        XCTAssertEqual(try dnr.disabledRuleIDs(rulesetID: "r1", extensionID: extID, manifest: manifest), [1])

        // Disabled rule 1 does not match; rule 2 still matches.
        let m1 = try ExtensionDNR.testMatchOutcome(
            request: ["url": "https://ads.example/banner.js", "type": "script"],
            manifest: manifest, resources: dir, enabledRulesetIDs: ["r1"], dynamicRules: [], sessionRules: [],
            disabledByRuleset: dnr.disabledMap(for: extID)
        )
        XCTAssertEqual((m1["matchedRules"] as? [[String: Any]])?.count, 0)

        let m2 = try ExtensionDNR.testMatchOutcome(
            request: ["url": "https://tracker.example/pixel.gif", "type": "image"],
            manifest: manifest, resources: dir, enabledRulesetIDs: ["r1"], dynamicRules: [], sessionRules: [],
            disabledByRuleset: dnr.disabledMap(for: extID)
        )
        XCTAssertEqual((m2["matchedRules"] as? [[String: Any]])?.first?["ruleId"] as? Int, 2)

        // Persistence round-trip and re-enable.
        let reloaded = ExtensionDNR(file: stateFile)
        XCTAssertEqual(try reloaded.disabledRuleIDs(rulesetID: "r1", extensionID: extID, manifest: manifest), [1])
        try reloaded.updateStaticRules(rulesetID: "r1", disableRuleIDs: [], enableRuleIDs: [1], extensionID: extID, manifest: manifest, resources: dir)
        XCTAssertEqual(try reloaded.disabledRuleIDs(rulesetID: "r1", extensionID: extID, manifest: manifest), [])

        let m1After = try ExtensionDNR.testMatchOutcome(
            request: ["url": "https://ads.example/banner.js", "type": "script"],
            manifest: manifest, resources: dir, enabledRulesetIDs: ["r1"], dynamicRules: [], sessionRules: [],
            disabledByRuleset: reloaded.disabledMap(for: extID)
        )
        XCTAssertEqual((m1After["matchedRules"] as? [[String: Any]])?.first?["ruleId"] as? Int, 1)
    }

    // MARK: - menus.overrideContext

    func testMenusOverrideContextValidationAndConsumption() throws {
        let menus = ExtensionMenus.shared
        let extID = "ext-menus-\(UUID().uuidString)"
        defer { menus.extensionUnloaded(extID) }

        XCTAssertThrowsError(try menus.overrideContext(["context": "bookmark"], extensionID: extID))
        XCTAssertThrowsError(try menus.overrideContext(["context": "tab"], extensionID: extID))
        XCTAssertThrowsError(try menus.overrideContext(["context": "invalid"], extensionID: extID))

        try menus.overrideContext(["context": "bookmark", "bookmarkId": "bm-123", "showDefaults": true], extensionID: extID)
        let consumed = try XCTUnwrap(menus.consumeOverride(for: extID))
        XCTAssertEqual(consumed.context, "bookmark")
        XCTAssertEqual(consumed.bookmarkID, "bm-123")
        XCTAssertTrue(consumed.showDefaults)
        XCTAssertNil(menus.consumeOverride(for: extID))

        menus.registerItem(["id": "open-custom", "title": "Custom Tab Action", "contexts": ["tab"]], extensionID: extID)
        XCTAssertTrue(menus.customItems(for: "tab").contains { $0.extensionID == extID && $0.items.first?.id == "open-custom" })
        menus.removeItem(id: "open-custom", extensionID: extID)
        XCTAssertFalse(menus.customItems(for: "tab").contains { $0.extensionID == extID })
    }

    // MARK: - storage.managed

    func testManagedStorageLoadingPrecedenceQueriesAndDiff() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("managed-\(UUID().uuidString)", isDirectory: true)
        let dirA = root.appendingPathComponent("low", isDirectory: true)
        let dirB = root.appendingPathComponent("high", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let geckoManifest: [String: Any] = ["browser_specific_settings": ["gecko": ["id": "policy@example.org"]]]
        let lowPolicy = """
        { "name": "policy@example.org", "description": "Managed", "type": "storage", "data": { "theme": "dark", "limit": 10 } }
        """
        try lowPolicy.write(to: dirA.appendingPathComponent("policy@example.org.json"), atomically: true, encoding: .utf8)
        let highPolicy = """
        { "limit": 25, "extra": true }
        """
        try highPolicy.write(to: dirB.appendingPathComponent("ext-id-1.json"), atomically: true, encoding: .utf8)

        let managed = ExtensionManagedStorage(directories: [dirA, dirB], readPreferences: false, emitEvents: false)

        let all = managed.get(keys: nil, extensionID: "ext-id-1", manifest: geckoManifest)
        XCTAssertEqual(all["theme"] as? String, "dark")
        XCTAssertEqual(all["limit"] as? Int, 25)
        XCTAssertEqual(all["extra"] as? Bool, true)

        XCTAssertEqual(managed.getKeys(extensionID: "ext-id-1", manifest: geckoManifest), ["extra", "limit", "theme"])
        let withDefaults = managed.get(keys: ["theme": "light", "missing": "fallback"], extensionID: "ext-id-1", manifest: geckoManifest)
        XCTAssertEqual(withDefaults["theme"] as? String, "dark")
        XCTAssertEqual(withDefaults["missing"] as? String, "fallback")
        XCTAssertGreaterThan(managed.getBytesInUse(keys: "theme", extensionID: "ext-id-1", manifest: geckoManifest), 0)

        // Change detection diff.
        managed.startMonitoring(extensionID: "ext-id-1", manifest: geckoManifest)
        try """
        { "limit": 99 }
        """.write(to: dirB.appendingPathComponent("ext-id-1.json"), atomically: true, encoding: .utf8)
        let emitted = managed.checkForChanges(manifests: ["ext-id-1": geckoManifest])
        let extDiff = try XCTUnwrap(emitted["ext-id-1"])
        XCTAssertEqual(extDiff["limit"]?["oldValue"] as? Int, 25)
        XCTAssertEqual(extDiff["limit"]?["newValue"] as? Int, 99)
        XCTAssertEqual(extDiff["extra"]?["oldValue"] as? Bool, true)
        XCTAssertNil(extDiff["extra"]?["newValue"])
        managed.stopMonitoring()
    }

    // MARK: - contentSettings.clipboard

    func testContentSettingsClipboardSetAndClear() throws {
        let extID = "ext-clip-\(UUID().uuidString)"
        let url = "https://clip.example/app"
        defer { ExtensionContentSettings.shared.extensionRemoved(extID) }

        XCTAssertEqual(try ExtensionContentSettings.shared.get(type: "clipboard", args: ["primaryUrl": url])["setting"] as? String, "ask")
        try ExtensionContentSettings.shared.set(
            type: "clipboard",
            args: ["primaryPattern": "https://clip.example/*", "setting": "block"],
            extensionID: extID
        )
        XCTAssertEqual(try ExtensionContentSettings.shared.get(type: "clipboard", args: ["primaryUrl": url])["setting"] as? String, "block")

        ExtensionContentSettings.shared.clear(type: "clipboard", extensionID: extID)
        XCTAssertEqual(try ExtensionContentSettings.shared.get(type: "clipboard", args: ["primaryUrl": url])["setting"] as? String, "ask")
    }

    // MARK: - userScripts.onBeforeScript (Firefox)

    @MainActor
    func testFirefoxUserScriptsOnBeforeScriptAndDefineGlobals() async throws {
        let extID = "us-before-\(UUID().uuidString)"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("us-api-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            ExtensionContentScripts.shared.extensionUnloaded(extID)
            try? FileManager.default.removeItem(at: dir)
        }

        let apiJS = """
        browser.userScripts.onBeforeScript.addListener((script) => {
          script.defineGlobals({
            getGreeting: () => 'hello-' + (script.metadata && script.metadata.name),
          });
        });
        """
        try apiJS.write(to: dir.appendingPathComponent("api.js"), atomically: true, encoding: .utf8)

        let scripts = ExtensionContentScripts.shared
        scripts.extensionLoaded(extID, manifest: ["user_scripts": ["api_script": "api.js"]], resources: dir)
        _ = try scripts.register([
            "matches": ["https://example.com/*"],
            "runAt": "document_start",
            "scriptMetadata": ["name": "tuff"],
            "js": [["code": "window.__usBeforeResult = typeof getGreeting === 'function' ? getGreeting() : 'missing';"]],
        ], extensionID: extID, resources: dir, defaultWorld: "USER_SCRIPT")

        let config = WKWebViewConfiguration()
        scripts.attach(config.userContentController)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: config)
        webView.loadHTMLString("<!doctype html><html><body>hi</body></html>", baseURL: URL(string: "https://example.com/test")!)

        let world = scripts.userScriptWorld(extensionID: extID, worldID: nil)
        let deadline = Date().addingTimeInterval(5)
        var observed: String?
        while Date() < deadline {
            let value: String? = await withCheckedContinuation { cont in
                webView.evaluateJavaScript("window.__usBeforeResult || null", in: nil, in: world) { result in
                    if case .success(let val) = result {
                        cont.resume(returning: val as? String)
                    } else {
                        cont.resume(returning: nil)
                    }
                }
            }
            if let value {
                observed = value
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(observed, "hello-tuff")
    }

    // MARK: - browser.pkcs11

    func testPKCS11ManifestLifecycleAndRealCModuleABI() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pkcs11-\(UUID().uuidString)", isDirectory: true)
        let manifestDir = root.appendingPathComponent("manifests", isDirectory: true)
        let stateFile = root.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(at: manifestDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Compile a minimal real PKCS#11 C dylib when clang is present so we test real dlopen + C_GetFunctionList.
        let dylibURL = root.appendingPathComponent("libmockpkcs11.dylib")
        var compiledRealDylib = false
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/clang") {
            let cFile = root.appendingPathComponent("mock.c")
            let cSource = """
            #include <stdint.h>
            #include <string.h>
            typedef unsigned long CK_RV;
            typedef unsigned long CK_ULONG;
            typedef unsigned long CK_SLOT_ID;
            typedef unsigned long CK_FLAGS;
            typedef unsigned char CK_BBOOL;
            typedef struct { uint8_t major; uint8_t minor; } CK_VERSION;
            typedef struct {
              uint8_t slotDescription[64];
              uint8_t manufacturerID[32];
              CK_FLAGS flags;
              CK_VERSION hardwareVersion;
              CK_VERSION firmwareVersion;
            } CK_SLOT_INFO;
            typedef struct {
              uint8_t label[32];
              uint8_t manufacturerID[32];
              uint8_t model[16];
              uint8_t serialNumber[16];
              CK_FLAGS flags;
              CK_ULONG ulMaxSessionCount, ulSessionCount, ulMaxRwSessionCount, ulRwSessionCount;
              CK_ULONG ulMaxPinLen, ulMinPinLen, ulTotalPublicMemory, ulFreePublicMemory;
              CK_ULONG ulTotalPrivateMemory, ulFreePrivateMemory;
              CK_VERSION hardwareVersion;
              CK_VERSION firmwareVersion;
              uint8_t utcTime[16];
            } CK_TOKEN_INFO;
            static CK_RV m_init(void *p) { return 0; }
            static CK_RV m_fin(void *p) { return 0; }
            static CK_RV m_slots(CK_BBOOL present, CK_SLOT_ID *list, CK_ULONG *count) {
              if (!list) { *count = 1; return 0; }
              list[0] = 7; *count = 1; return 0;
            }
            static CK_RV m_slotInfo(CK_SLOT_ID id, CK_SLOT_INFO *info) {
              memset(info, ' ', sizeof(*info));
              memcpy(info->slotDescription, "Tuff Virtual Reader", 19);
              info->flags = 1; /* CKF_TOKEN_PRESENT */
              return 0;
            }
            static CK_RV m_tokenInfo(CK_SLOT_ID id, CK_TOKEN_INFO *info) {
              memset(info, ' ', sizeof(*info));
              memcpy(info->label, "Tuff SmartCard", 14);
              memcpy(info->manufacturerID, "Tuff Labs", 9);
              memcpy(info->serialNumber, "SN123456", 8);
              info->flags = 8; /* CKF_USER_PIN_INITIALIZED */
              info->hardwareVersion.major = 2; info->hardwareVersion.minor = 1;
              info->firmwareVersion.major = 3; info->firmwareVersion.minor = 4;
              return 0;
            }
            typedef struct {
              CK_VERSION version;
              void *C_Initialize;
              void *C_Finalize;
              void *C_GetInfo;
              void *C_GetFunctionList;
              void *C_GetSlotList;
              void *C_GetSlotInfo;
              void *C_GetTokenInfo;
            } CK_FUNC_LIST;
            static CK_FUNC_LIST fnList = {
              {2, 40}, (void*)m_init, (void*)m_fin, 0, 0, (void*)m_slots, (void*)m_slotInfo, (void*)m_tokenInfo
            };
            CK_RV C_GetFunctionList(void **pp) { *pp = &fnList; return 0; }
            """
            try cSource.write(to: cFile, atomically: true, encoding: .utf8)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
            proc.arguments = ["-shared", "-fPIC", cFile.path, "-o", dylibURL.path]
            try proc.run()
            proc.waitUntilExit()
            compiledRealDylib = proc.terminationStatus == 0
        }
        if !compiledRealDylib {
            try Data().write(to: dylibURL)
        }

        let manifestJSON = """
        {
          "name": "test_module",
          "description": "Test PKCS#11 Module",
          "path": "\(dylibURL.path)",
          "type": "pkcs11",
          "allowed_extensions": ["pkcs-ext@example.org"]
        }
        """
        try manifestJSON.write(to: manifestDir.appendingPathComponent("test_module.json"), atomically: true, encoding: .utf8)

        let extManifest: [String: Any] = ["browser_specific_settings": ["gecko": ["id": "pkcs-ext@example.org"]]]
        let pkcs = ExtensionPKCS11(directories: [manifestDir], stateFile: stateFile)
        if !compiledRealDylib {
            pkcs.slotLoaderOverride = { _ in
                [ExtensionPKCS11.SlotInfo(
                    name: "Tuff Virtual Reader",
                    token: .init(name: "Tuff SmartCard", manufacturer: "Tuff Labs", hwVersion: "2.1", fwVersion: "3.4", serial: "SN123456", isLoggedIn: true)
                )]
            }
        }

        // Disallowed extension is rejected.
        XCTAssertThrowsError(try pkcs.isModuleInstalled(name: "test_module", extensionID: "other", manifest: nil))

        XCTAssertFalse(try pkcs.isModuleInstalled(name: "test_module", extensionID: "ext-1", manifest: extManifest))
        try pkcs.installModule(name: "test_module", flags: 0, extensionID: "ext-1", manifest: extManifest)
        XCTAssertTrue(try pkcs.isModuleInstalled(name: "test_module", extensionID: "ext-1", manifest: extManifest))

        let slots = try pkcs.getModuleSlots(name: "test_module", extensionID: "ext-1", manifest: extManifest)
        XCTAssertEqual(slots.count, 1)
        XCTAssertEqual(slots[0]["name"] as? String, "Tuff Virtual Reader")
        let token = try XCTUnwrap(slots[0]["token"] as? [String: Any])
        XCTAssertEqual(token["name"] as? String, "Tuff SmartCard")
        XCTAssertEqual(token["manufacturer"] as? String, "Tuff Labs")
        XCTAssertEqual(token["serial"] as? String, "SN123456")
        XCTAssertEqual(token["HWVersion"] as? String, "2.1")
        XCTAssertEqual(token["FWVersion"] as? String, "3.4")

        try pkcs.uninstallModule(name: "test_module", extensionID: "ext-1", manifest: extManifest)
        XCTAssertFalse(try pkcs.isModuleInstalled(name: "test_module", extensionID: "ext-1", manifest: extManifest))
    }

    // MARK: - proxy (PAC, direct, SOCKS4, auto_detect, onRequest)

    func testPACEvaluatorAndProxyPlanValidation() throws {
        let pac = try PACEvaluator(script: """
        function FindProxyForURL(url, host) {
          if (isPlainHostName(host) || dnsDomainIs(host, '.local')) return 'DIRECT';
          if (shExpMatch(url, 'https://corp.example/*')) return 'HTTPS corp-proxy.example:443; PROXY backup.example:8080; DIRECT';
          if (isInNet('10.1.2.3', '10.0.0.0', '255.0.0.0')) return 'SOCKS4 127.0.0.1:1080';
          return 'DIRECT';
        }
        """)

        XCTAssertEqual(try pac.evaluate(url: "http://intranet/", host: "intranet"), [.direct])
        XCTAssertEqual(
            try pac.evaluate(url: "https://corp.example/api", host: "corp.example"),
            [
                .http(host: "corp-proxy.example", port: 443, tls: true),
                .http(host: "backup.example", port: 8080, tls: false),
                .direct,
            ]
        )
        XCTAssertEqual(
            try pac.evaluate(url: "https://other.example/", host: "other.example"),
            [.socks4(host: "127.0.0.1", port: 1080)]
        )

        // Chrome direct, auto_detect, pac_script, socks4 plans validate cleanly.
        if case .relay(.direct) = try ExtensionSettings.validateAndPlanProxy(["mode": "direct"]) {} else { XCTFail("Expected direct relay") }
        if case .autoDetect = try ExtensionSettings.validateAndPlanProxy(["mode": "auto_detect"]) {} else { XCTFail("Expected autoDetect") }
        if case .relay(.pac) = try ExtensionSettings.validateAndPlanProxy([
            "mode": "pac_script",
            "pacScript": ["data": "function FindProxyForURL(u, h) { return 'DIRECT'; }"],
        ]) {} else { XCTFail("Expected PAC relay") }
        if case .relay(.staticRoutes(let routes, _)) = try ExtensionSettings.validateAndPlanProxy([
            "mode": "fixed_servers",
            "rules": ["singleProxy": ["scheme": "socks4", "host": "127.0.0.1", "port": 1080]],
        ]) {
            XCTAssertEqual(routes, [.socks4(host: "127.0.0.1", port: 1080)])
        } else {
            XCTFail("Expected SOCKS4 relay")
        }

        // Firefox ProxyInfo parsing.
        XCTAssertEqual(try ProxyRoute.fromFirefoxProxyInfo(["type": "direct"]), .direct)
        XCTAssertEqual(
            try ProxyRoute.fromFirefoxProxyInfo(["type": "socks", "host": "127.0.0.1", "port": 9050, "username": "u", "password": "p"]),
            .socks5(host: "127.0.0.1", port: 9050, username: "u", password: "p")
        )
        XCTAssertEqual(
            try ProxyRoute.fromFirefoxProxyInfo(["type": "socks4", "host": "127.0.0.1", "port": 1080]),
            .socks4(host: "127.0.0.1", port: 1080)
        )
    }

    // MARK: - theme.update (images & properties) and management.install hash verification

    func testThemeUpdateImagesPropertiesAndHashVerification() throws {
        let extID = "theme-ext-\(UUID().uuidString)"
        defer { ExtensionTheme.shared.reset(extensionID: extID) }

        // 1x1 transparent PNG data URL.
        let pngDataURL = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
        try ExtensionTheme.shared.update([
            "colors": ["frame": "#224466"],
            "images": [
                "theme_frame": pngDataURL,
                "additional_backgrounds": [pngDataURL],
            ],
            "properties": [
                "additional_backgrounds_alignment": ["left top"],
                "additional_backgrounds_tiling": ["repeat"],
                "color_scheme": "dark",
            ],
        ], extensionID: extID)

        XCTAssertNotNil(ExtensionTheme.shared.tint)
        XCTAssertNotNil(ExtensionTheme.shared.headerImage)
        XCTAssertEqual(ExtensionTheme.shared.additionalLayers.count, 1)
        XCTAssertEqual(ExtensionTheme.shared.additionalLayers[0].alignment, "left top")
        XCTAssertEqual(ExtensionTheme.shared.additionalLayers[0].tiling, "repeat")
        XCTAssertEqual(ExtensionTheme.shared.colorScheme, "dark")

        ExtensionTheme.shared.reset(extensionID: extID)
        XCTAssertNil(ExtensionTheme.shared.tint)
        XCTAssertNil(ExtensionTheme.shared.headerImage)
        XCTAssertTrue(ExtensionTheme.shared.additionalLayers.isEmpty)

        // Hash verification for management.install.
        let sample = Data("tuff-theme".utf8)
        let sha256Hex = SHA256.hash(data: sample).map { String(format: "%02x", $0) }.joined()
        let sha512Hex = SHA512.hash(data: sample).map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(ExtensionManager.verifyHash("sha256:\(sha256Hex)", of: sample))
        XCTAssertTrue(ExtensionManager.verifyHash("sha512:\(sha512Hex)", of: sample))
        XCTAssertFalse(ExtensionManager.verifyHash("sha256:0000000000000000000000000000000000000000000000000000000000000000", of: sample))
        XCTAssertFalse(ExtensionManager.verifyHash("md5:1234", of: sample))
    }
}
