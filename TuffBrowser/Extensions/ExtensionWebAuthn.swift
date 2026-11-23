import AppKit
import WebKit

/// `chrome.webAuthenticationProxy` (MV3): lets one attached extension intercept WebAuthn
/// (`navigator.credentials.create`, `navigator.credentials.get`, and
/// `PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable`) across web pages and
/// answer them asynchronously.
///
/// Zero page cost when no extension is attached: the interception script and message handler are
/// only installed into tabs while an extension is attached, and removed again on detach or unload.
final class ExtensionWebAuthn: NSObject {
    static let shared = ExtensionWebAuthn()

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    enum RequestKind { case create, get, isUvpaa }

    private struct PendingRequest {
        let id: Int
        let kind: RequestKind
        let clientToken: String?
        weak var webView: WKWebView?
        let replyHandler: (Any?, String?) -> Void
    }

    static let messageHandlerName = "__tuffWebAuthnProxy"
    private static let removeScriptSelector = NSSelectorFromString("_removeUserScript:")

    private(set) var attachedExtensionID: String?
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private var installedScript: WKUserScript?
    private var pending: [Int: PendingRequest] = [:]
    private var nextRequestID = 1
    private var workspaceObservers: [NSObjectProtocol] = []

    /// Test hook: when set, replaces `ExtensionEventPush.shared.emit`.
    var testEventSink: ((String, [Any], String) -> Void)?

    private override init() { super.init() }

    /// Registers a new tab's content controller. If an extension is currently attached, the
    /// proxy script and message handler are installed immediately; otherwise nothing is added.
    func attach(_ controller: WKUserContentController) {
        controllers.add(controller)
        if attachedExtensionID != nil {
            install(into: controller)
        }
    }

    /// Attaches `extensionID` as the active WebAuthn proxy. Only one extension may be attached.
    func attach(extensionID: String) throws {
        if let current = attachedExtensionID {
            if current == extensionID {
                throw Failure("This extension is already attached to webAuthenticationProxy.")
            }
            throw Failure("Another extension is already attached to webAuthenticationProxy.")
        }
        attachedExtensionID = extensionID
        let script = WKUserScript(source: Self.proxyScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
        installedScript = script
        for controller in controllers.allObjects {
            install(into: controller)
        }
        // Also activate in already-open tabs so pages don't need a reload.
        for tab in BrowserState.shared.allTabs {
            guard let webView = tab.webView, tab.hostExtension == nil else { continue }
            webView.evaluateJavaScript(Self.proxyScript, in: nil, in: .page) { _ in }
        }
        startSessionMonitoring()
    }

    /// Detaches `extensionID` from the WebAuthn proxy and restores native WebAuthn in open tabs.
    func detach(extensionID: String) throws {
        guard attachedExtensionID == extensionID else {
            throw Failure("This extension is not attached to webAuthenticationProxy.")
        }
        detachNow()
    }

    func extensionUnloaded(_ extensionID: String) {
        if attachedExtensionID == extensionID { detachNow() }
    }

    /// Cancels any in-flight WebAuthn requests belonging to `webView` (tab closed or navigated).
    func cancelRequests(for webView: WKWebView?) {
        guard let webView else { return }
        let matching = pending.values.filter { $0.webView === webView }
        for request in matching {
            pending.removeValue(forKey: request.id)
            request.replyHandler(["error": ["name": "AbortError", "message": "The request was canceled."]], nil)
            if let extID = attachedExtensionID {
                emit("webAuthenticationProxy.onRequestCanceled", args: [request.id], to: extID)
            }
        }
    }

    func completeCreateRequest(_ details: [String: Any], extensionID: String) throws {
        try completeCredentialRequest(details, expectedKind: .create, extensionID: extensionID)
    }

    func completeGetRequest(_ details: [String: Any], extensionID: String) throws {
        try completeCredentialRequest(details, expectedKind: .get, extensionID: extensionID)
    }

    func completeIsUvpaaRequest(_ details: [String: Any], extensionID: String) throws {
        guard attachedExtensionID == extensionID else {
            throw Failure("This extension is not attached to webAuthenticationProxy.")
        }
        guard let requestID = details["requestId"] as? Int else {
            throw Failure("requestId is required.")
        }
        guard let isUvpaa = details["isUvpaa"] as? Bool else {
            throw Failure("isUvpaa is required.")
        }
        guard let request = pending[requestID], request.kind == .isUvpaa else {
            throw Failure("No pending isUvpaa request with id \(requestID).")
        }
        pending.removeValue(forKey: requestID)
        request.replyHandler(["isUvpaa": isUvpaa], nil)
    }

    // MARK: Internals

    private func completeCredentialRequest(_ details: [String: Any], expectedKind: RequestKind, extensionID: String) throws {
        guard attachedExtensionID == extensionID else {
            throw Failure("This extension is not attached to webAuthenticationProxy.")
        }
        guard let requestID = details["requestId"] as? Int else {
            throw Failure("requestId is required.")
        }
        guard let request = pending[requestID], request.kind == expectedKind else {
            throw Failure("No pending request with id \(requestID).")
        }
        if let error = details["error"] as? [String: Any] {
            let name = error["name"] as? String ?? "UnknownError"
            let message = error["message"] as? String ?? ""
            pending.removeValue(forKey: requestID)
            request.replyHandler(["error": ["name": name, "message": message]], nil)
            return
        }
        guard let responseJson = details["responseJson"] as? String else {
            throw Failure("Either responseJson or error is required.")
        }
        guard (try? JSONSerialization.jsonObject(with: Data(responseJson.utf8))) is [String: Any] else {
            throw Failure("responseJson must be a valid JSON object.")
        }
        pending.removeValue(forKey: requestID)
        request.replyHandler(["responseJson": responseJson], nil)
    }

    private func detachNow() {
        let wasAttached = attachedExtensionID
        attachedExtensionID = nil
        stopSessionMonitoring()

        let remaining = Array(pending.values)
        pending.removeAll()
        for request in remaining {
            request.replyHandler(["error": ["name": "AbortError", "message": "WebAuthn proxy detached."]], nil)
            if let wasAttached {
                emit("webAuthenticationProxy.onRequestCanceled", args: [request.id], to: wasAttached)
            }
        }

        let script = installedScript
        installedScript = nil
        for controller in controllers.allObjects {
            controller.removeScriptMessageHandler(forName: Self.messageHandlerName, contentWorld: .page)
            if let script, controller.responds(to: Self.removeScriptSelector) {
                controller.perform(Self.removeScriptSelector, with: script)
            }
        }
        for tab in BrowserState.shared.allTabs {
            guard let webView = tab.webView, tab.hostExtension == nil else { continue }
            webView.evaluateJavaScript("if (window.__tuffWebAuthnDetach) window.__tuffWebAuthnDetach(); void 0;", in: nil, in: .page) { _ in }
        }
    }

    private func install(into controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: Self.messageHandlerName, contentWorld: .page)
        controller.addScriptMessageHandler(self, contentWorld: .page, name: Self.messageHandlerName)
        if let script = installedScript {
            controller.addUserScript(script)
        }
    }

    private func emit(_ event: String, args: [Any], to extensionID: String) {
        if let testEventSink {
            testEventSink(event, args, extensionID)
        } else {
            ExtensionEventPush.shared.emit(event, args: args, to: extensionID)
        }
    }

    private func startSessionMonitoring() {
        stopSessionMonitoring()
        let center = NSWorkspace.shared.notificationCenter
        let notify: (Notification) -> Void = { [weak self] _ in
            guard let self, let id = self.attachedExtensionID else { return }
            self.emit("webAuthenticationProxy.onRemoteSessionStateChange", args: [], to: id)
        }
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main, using: notify),
            center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main, using: notify),
        ]
    }

    private func stopSessionMonitoring() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { center.removeObserver(observer) }
        workspaceObservers.removeAll()
    }

    // MARK: Page script

    private static let proxyScript = #"""
    (() => {
      if (window.__tuffWebAuthnActive) return;
      if (!navigator.credentials || typeof window.PublicKeyCredential === 'undefined') return;
      const handler = () => window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.__tuffWebAuthnProxy;
      if (!handler()) return;

      const origCreate = navigator.credentials.create.bind(navigator.credentials);
      const origGet = navigator.credentials.get.bind(navigator.credentials);
      const origIsUvpaa = typeof PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable === 'function'
        ? PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable.bind(PublicKeyCredential) : null;

      window.__tuffWebAuthnActive = true;
      window.__tuffWebAuthnDetach = () => {
        if (!window.__tuffWebAuthnActive) return;
        window.__tuffWebAuthnActive = false;
        try { Object.defineProperty(navigator.credentials, 'create', { value: origCreate, writable: true, configurable: true }); } catch (e) {}
        try { Object.defineProperty(navigator.credentials, 'get', { value: origGet, writable: true, configurable: true }); } catch (e) {}
        if (origIsUvpaa) {
          try { Object.defineProperty(PublicKeyCredential, 'isUserVerifyingPlatformAuthenticatorAvailable', { value: origIsUvpaa, writable: true, configurable: true }); } catch (e) {}
        }
        delete window.__tuffWebAuthnDetach;
      };

      const toBase64Url = (buf) => {
        if (!buf) return '';
        const bytes = buf instanceof ArrayBuffer ? new Uint8Array(buf)
          : ArrayBuffer.isView(buf) ? new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength) : null;
        if (!bytes) return '';
        let bin = '';
        for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
        return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
      };

      const fromBase64Url = (str) => {
        if (typeof str !== 'string') return new ArrayBuffer(0);
        const pad = str.length % 4 === 0 ? '' : '='.repeat(4 - (str.length % 4));
        const bin = atob(str.replace(/-/g, '+').replace(/_/g, '/') + pad);
        const bytes = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
        return bytes.buffer;
      };

      const encodeValue = (v) => {
        if (v instanceof ArrayBuffer || ArrayBuffer.isView(v)) return toBase64Url(v);
        if (Array.isArray(v)) return v.map(encodeValue);
        if (v && typeof v === 'object') {
          const out = {};
          for (const k of Object.keys(v)) {
            if (v[k] !== undefined) out[k] = encodeValue(v[k]);
          }
          return out;
        }
        return v;
      };

      const buildCredential = (json, isCreate) => {
        const raw = JSON.parse(json);
        const rawId = fromBase64Url(raw.rawId || raw.id || '');
        const resp = raw.response || {};
        const clientExtensions = raw.clientExtensionResults || {};
        let responseObj;
        if (isCreate) {
          const transports = Array.isArray(resp.transports) ? resp.transports.slice() : [];
          const authData = resp.authenticatorData ? fromBase64Url(resp.authenticatorData) : null;
          const pubKey = resp.publicKey ? fromBase64Url(resp.publicKey) : null;
          const pubKeyAlg = typeof resp.publicKeyAlgorithm === 'number' ? resp.publicKeyAlgorithm : -7;
          responseObj = {
            clientDataJSON: fromBase64Url(resp.clientDataJSON || ''),
            attestationObject: fromBase64Url(resp.attestationObject || ''),
            getTransports: () => transports.slice(),
            getAuthenticatorData: () => authData,
            getPublicKey: () => pubKey,
            getPublicKeyAlgorithm: () => pubKeyAlg,
          };
        } else {
          responseObj = {
            clientDataJSON: fromBase64Url(resp.clientDataJSON || ''),
            authenticatorData: fromBase64Url(resp.authenticatorData || ''),
            signature: fromBase64Url(resp.signature || ''),
            userHandle: resp.userHandle ? fromBase64Url(resp.userHandle) : null,
          };
        }
        return {
          id: raw.id || toBase64Url(rawId),
          rawId,
          type: raw.type || 'public-key',
          authenticatorAttachment: raw.authenticatorAttachment || null,
          response: responseObj,
          getClientExtensionResults: () => Object.assign({}, clientExtensions),
          toJSON: () => raw,
        };
      };

      let nextToken = 1;
      const sendProxy = (op, publicKey, signal) => new Promise((resolve, reject) => {
        if (signal && signal.aborted) {
          reject(new DOMException('The operation was aborted.', 'AbortError'));
          return;
        }
        const h = handler();
        if (!h) {
          reject(new DOMException('WebAuthn proxy unavailable.', 'NotSupportedError'));
          return;
        }
        const clientToken = 't' + (nextToken++) + '_' + Math.random().toString(36).slice(2);
        let settled = false;
        const onAbort = () => {
          if (settled) return;
          settled = true;
          try { h.postMessage({ op: 'cancel', clientToken }); } catch (e) {}
          reject(new DOMException('The operation was aborted.', 'AbortError'));
        };
        if (signal) signal.addEventListener('abort', onAbort, { once: true });
        const payload = { op, clientToken };
        if (publicKey) payload.requestDetailsJson = JSON.stringify(encodeValue(publicKey));
        h.postMessage(payload).then((reply) => {
          if (signal) signal.removeEventListener('abort', onAbort);
          if (settled) return;
          settled = true;
          if (!reply) { reject(new DOMException('Empty proxy response.', 'UnknownError')); return; }
          if (reply.error) {
            reject(new DOMException(reply.error.message || '', reply.error.name || 'UnknownError'));
            return;
          }
          if (op === 'isUvpaa') {
            resolve(!!reply.isUvpaa);
            return;
          }
          try {
            resolve(buildCredential(reply.responseJson, op === 'create'));
          } catch (e) {
            reject(new DOMException(String(e && e.message || e), 'DataError'));
          }
        }, (err) => {
          if (signal) signal.removeEventListener('abort', onAbort);
          if (settled) return;
          settled = true;
          reject(new DOMException(String(err && err.message || err), 'UnknownError'));
        });
      });

      const wrappedCreate = function create(options) {
        if (!window.__tuffWebAuthnActive || !options || !options.publicKey) return origCreate(options);
        return sendProxy('create', options.publicKey, options.signal);
      };
      const wrappedGet = function get(options) {
        if (!window.__tuffWebAuthnActive || !options || !options.publicKey) return origGet(options);
        return sendProxy('get', options.publicKey, options.signal);
      };
      const wrappedIsUvpaa = function isUserVerifyingPlatformAuthenticatorAvailable() {
        if (!window.__tuffWebAuthnActive) return origIsUvpaa ? origIsUvpaa() : Promise.resolve(false);
        return sendProxy('isUvpaa', null, null);
      };

      try { Object.defineProperty(navigator.credentials, 'create', { value: wrappedCreate, writable: true, configurable: true }); } catch (e) {}
      try { Object.defineProperty(navigator.credentials, 'get', { value: wrappedGet, writable: true, configurable: true }); } catch (e) {}
      try { Object.defineProperty(PublicKeyCredential, 'isUserVerifyingPlatformAuthenticatorAvailable', { value: wrappedIsUvpaa, writable: true, configurable: true }); } catch (e) {}
    })();
    """#
}

extension ExtensionWebAuthn: WKScriptMessageHandlerWithReply {
    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let extID = attachedExtensionID,
              let body = message.body as? [String: Any],
              let op = body["op"] as? String else {
            replyHandler(["error": ["name": "NotSupportedError", "message": "No WebAuthn proxy is attached."]], nil)
            return
        }
        let clientToken = body["clientToken"] as? String

        if op == "cancel" {
            if let token = clientToken,
               let match = pending.values.first(where: { $0.clientToken == token && $0.webView === message.webView }) {
                pending.removeValue(forKey: match.id)
                match.replyHandler(["error": ["name": "AbortError", "message": "The operation was aborted."]], nil)
                emit("webAuthenticationProxy.onRequestCanceled", args: [match.id], to: extID)
            }
            replyHandler(["ok": true], nil)
            return
        }

        let id = nextRequestID
        nextRequestID += 1

        switch op {
        case "create":
            let json = body["requestDetailsJson"] as? String ?? "{}"
            pending[id] = PendingRequest(id: id, kind: .create, clientToken: clientToken, webView: message.webView, replyHandler: replyHandler)
            emit("webAuthenticationProxy.onCreateRequest", args: [["requestId": id, "requestDetailsJson": json]], to: extID)
        case "get":
            let json = body["requestDetailsJson"] as? String ?? "{}"
            pending[id] = PendingRequest(id: id, kind: .get, clientToken: clientToken, webView: message.webView, replyHandler: replyHandler)
            emit("webAuthenticationProxy.onGetRequest", args: [["requestId": id, "requestDetailsJson": json]], to: extID)
        case "isUvpaa":
            pending[id] = PendingRequest(id: id, kind: .isUvpaa, clientToken: clientToken, webView: message.webView, replyHandler: replyHandler)
            emit("webAuthenticationProxy.onIsUvpaaRequest", args: [["requestId": id]], to: extID)
        default:
            replyHandler(["error": ["name": "NotSupportedError", "message": "Unknown operation."]], nil)
        }
    }
}
