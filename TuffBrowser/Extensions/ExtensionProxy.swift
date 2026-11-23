import CFNetwork
import CryptoKit
import Foundation
import JavaScriptCore
import Network
import WebKit

/// One resolved upstream proxy route (or direct connection).
enum ProxyRoute: Equatable {
    case direct
    case http(host: String, port: Int, tls: Bool, username: String? = nil, password: String? = nil)
    case socks5(host: String, port: Int, username: String? = nil, password: String? = nil)
    case socks4(host: String, port: Int, userID: String? = nil)

    /// Parses a PAC `FindProxyForURL` result string such as
    /// `"PROXY p1.example:8080; SOCKS5 127.0.0.1:1080; DIRECT"`.
    static func parsePACResult(_ raw: String) -> [ProxyRoute] {
        var routes: [ProxyRoute] = []
        for piece in raw.split(separator: ";") {
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let kind = parts[0].uppercased()
            if kind == "DIRECT" {
                routes.append(.direct)
                continue
            }
            guard parts.count >= 2, let (host, port) = splitHostPort(parts[1]) else { continue }
            switch kind {
            case "PROXY", "HTTP":
                routes.append(.http(host: host, port: port ?? 80, tls: false))
            case "HTTPS":
                routes.append(.http(host: host, port: port ?? 443, tls: true))
            case "SOCKS", "SOCKS5":
                routes.append(.socks5(host: host, port: port ?? 1080))
            case "SOCKS4":
                routes.append(.socks4(host: host, port: port ?? 1080))
            default:
                break
            }
        }
        return routes.isEmpty ? [.direct] : routes
    }

    /// Parses one Firefox `proxy.ProxyInfo` dictionary.
    static func fromFirefoxProxyInfo(_ info: [String: Any]) throws -> ProxyRoute {
        let type = (info["type"] as? String ?? "direct").lowercased()
        if type == "direct" { return .direct }
        guard let host = info["host"] as? String, !host.isEmpty else {
            throw ExtensionSettings.Failure("ProxyInfo '\(type)' requires a host.")
        }
        let defaultPort = (type == "socks" || type == "socks4") ? 1080 : (type == "https" ? 443 : 80)
        let port = info["port"] as? Int ?? defaultPort
        guard (1...65535).contains(port) else {
            throw ExtensionSettings.Failure("Invalid proxy port \(port).")
        }
        let username = info["username"] as? String
        let password = info["password"] as? String
        switch type {
        case "http": return .http(host: host, port: port, tls: false, username: username, password: password)
        case "https": return .http(host: host, port: port, tls: true, username: username, password: password)
        case "socks", "socks5": return .socks5(host: host, port: port, username: username, password: password)
        case "socks4": return .socks4(host: host, port: port, userID: username)
        default:
            throw ExtensionSettings.Failure("Unsupported proxy type '\(type)'.")
        }
    }

    static func splitHostPort(_ raw: String) -> (String, Int?)? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            let host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if rest.hasPrefix(":"), let port = Int(rest.dropFirst()) { return (host, port) }
            return (host, nil)
        }
        if let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]) {
            let host = String(text[..<colon])
            return host.isEmpty ? nil : (host, port)
        }
        return (text, nil)
    }
}

/// Evaluates Proxy Auto-Config (PAC) JavaScript (`FindProxyForURL(url, host)`) using JavaScriptCore.
final class PACEvaluator {
    private let lock = NSLock()
    private let context: JSContext
    private(set) var lastError: String?

    init(script: String) throws {
        guard let vm = JSVirtualMachine(), let ctx = JSContext(virtualMachine: vm) else {
            throw ExtensionSettings.Failure("Could not initialize JavaScriptCore for PAC script.")
        }
        self.context = ctx
        var jsError: String?
        ctx.exceptionHandler = { _, exc in
            jsError = exc?.toString() ?? "PAC script error"
        }
        // Native DNS helper for `dnsResolve` / `isResolvable` / `myIpAddress`.
        let dnsResolveBlock: @convention(block) (String) -> Any = { host in
            Self.resolveIPv4(host) ?? NSNull()
        }
        ctx.setObject(dnsResolveBlock, forKeyedSubscript: "__tuffDnsResolve" as NSString)
        let myIPBlock: @convention(block) () -> String = {
            Self.localIPv4() ?? "127.0.0.1"
        }
        ctx.setObject(myIPBlock, forKeyedSubscript: "__tuffMyIpAddress" as NSString)

        ctx.evaluateScript(Self.pacHelpers)
        ctx.evaluateScript(script)
        if let jsError {
            throw ExtensionSettings.Failure("PAC script error: \(jsError)")
        }
        guard let fn = ctx.objectForKeyedSubscript("FindProxyForURL"), !fn.isUndefined else {
            throw ExtensionSettings.Failure("PAC script does not define FindProxyForURL.")
        }
    }

    func evaluate(url: String, host: String) throws -> [ProxyRoute] {
        lock.lock()
        defer { lock.unlock() }
        var jsError: String?
        context.exceptionHandler = { _, exc in
            jsError = exc?.toString() ?? "PAC evaluation failed"
        }
        guard let fn = context.objectForKeyedSubscript("FindProxyForURL"),
              let result = fn.call(withArguments: [url, host]) else {
            throw ExtensionSettings.Failure(jsError ?? "FindProxyForURL returned no result.")
        }
        if let jsError {
            lastError = jsError
            throw ExtensionSettings.Failure(jsError)
        }
        guard result.isString, let text = result.toString() else {
            return [.direct]
        }
        return ProxyRoute.parsePACResult(text)
    }

    private static func resolveIPv4(_ host: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }
        var addr = first.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buffer)
    }

    private static func localIPv4() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let iface = cur {
            if let sa = iface.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                let flags = Int32(iface.pointee.ifa_flags)
                if (flags & IFF_UP) != 0 && (flags & IFF_LOOPBACK) == 0 {
                    var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &sin, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                        return String(cString: buf)
                    }
                }
            }
            cur = iface.pointee.ifa_next
        }
        return nil
    }

    /// Standard Netscape / Chrome / Firefox PAC helper functions.
    private static let pacHelpers = #"""
    function isPlainHostName(host) { return host.indexOf('.') === -1; }
    function dnsDomainIs(host, domain) {
      host = host.toLowerCase(); domain = domain.toLowerCase();
      return host.length >= domain.length && host.substring(host.length - domain.length) === domain;
    }
    function localHostOrDomainIs(host, hostdom) {
      return host === hostdom || hostdom.lastIndexOf(host + '.', 0) === 0;
    }
    function dnsResolve(host) {
      var ip = __tuffDnsResolve(String(host || ''));
      return ip === null ? null : String(ip);
    }
    function isResolvable(host) { return dnsResolve(host) !== null; }
    function myIpAddress() { return String(__tuffMyIpAddress()); }
    function dnsDomainLevels(host) { return host.split('.').length - 1; }
    function convert_addr(ipchars) {
      var bytes = String(ipchars).split('.');
      if (bytes.length !== 4) return 0;
      return ((bytes[0] & 0xff) << 24) | ((bytes[1] & 0xff) << 16) | ((bytes[2] & 0xff) << 8) | (bytes[3] & 0xff);
    }
    function isInNet(ipaddr, pattern, maskstr) {
      var ip = /^\d+\.\d+\.\d+\.\d+$/.test(ipaddr) ? ipaddr : dnsResolve(ipaddr);
      if (!ip) return false;
      var host = convert_addr(ip), pat = convert_addr(pattern), mask = convert_addr(maskstr);
      return (host & mask) === (pat & mask);
    }
    function shExpMatch(str, shexp) {
      var re = String(shexp).replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*').replace(/\?/g, '.');
      return new RegExp('^' + re + '$').test(String(str));
    }
    function weekdayRange(wd1, wd2, gmt) {
      var days = { SUN:0, MON:1, TUE:2, WED:3, THU:4, FRI:5, SAT:6 };
      var d = new Date();
      var today = (gmt === 'GMT' || wd2 === 'GMT') ? d.getUTCDay() : d.getDay();
      var w1 = days[String(wd1).toUpperCase()];
      var w2 = (wd2 && wd2 !== 'GMT') ? days[String(wd2).toUpperCase()] : w1;
      if (w1 === undefined || w2 === undefined) return false;
      return w1 <= w2 ? (today >= w1 && today <= w2) : (today >= w1 || today <= w2);
    }
    function timeRange() {
      var args = Array.prototype.slice.call(arguments);
      var gmt = args[args.length - 1] === 'GMT';
      if (gmt) args.pop();
      var d = new Date();
      var h = gmt ? d.getUTCHours() : d.getHours();
      var m = gmt ? d.getUTCMinutes() : d.getMinutes();
      var s = gmt ? d.getUTCSeconds() : d.getSeconds();
      var now = h * 3600 + m * 60 + s;
      if (args.length === 1) return h === args[0];
      if (args.length === 2) return args[0] <= args[1] ? (h >= args[0] && h <= args[1]) : (h >= args[0] || h <= args[1]);
      if (args.length === 4) {
        var t1 = args[0] * 3600 + args[1] * 60, t2 = args[2] * 3600 + args[3] * 60 + 59;
        return t1 <= t2 ? (now >= t1 && now <= t2) : (now >= t1 || now <= t2);
      }
      if (args.length === 6) {
        var s1 = args[0] * 3600 + args[1] * 60 + args[2], s2 = args[3] * 3600 + args[4] * 60 + args[5];
        return s1 <= s2 ? (now >= s1 && now <= s2) : (now >= s1 || now <= s2);
      }
      return false;
    }
    function dateRange() { return true; }
    """#
}

/// Local loopback HTTP/CONNECT proxy relay powering:
/// - `proxy.settings` modes that Network.framework doesn't natively handle (`direct`, `pac_script`,
///   `auto_detect`, and `socks4` servers)
/// - Firefox's `proxy.onRequest` dynamic per-request proxy routing
/// - `proxy.onProxyError` (Chrome) and `proxy.onError` (Firefox) error reporting.
///
/// The listener binds only to `127.0.0.1` on an ephemeral port and requires a random per-session
/// `Proxy-Authorization` credential that Tuff attaches to `nw_proxy_config_t`, so other local
/// processes cannot use it. It runs lazily only while a relay-backed proxy mode or `proxy.onRequest`
/// listener is active (zero cost otherwise).
final class ExtensionProxyRelay {
    static let shared = ExtensionProxyRelay()

    enum RelayMode {
        case none
        case direct
        case pac(PACEvaluator, mandatory: Bool)
        case staticRoutes([ProxyRoute], bypassList: [String])
    }

    struct OnRequestListener {
        let extensionID: String
        let urlPatterns: [String]
    }

    private let queue = DispatchQueue(label: "tuff.extension-proxy-relay", qos: .userInitiated)
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private let authToken: String = {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }()
    private var expectedAuthHeader: String {
        "Basic " + Data("tuff:\(authToken)".utf8).base64EncodedString()
    }

    private var mode: RelayMode = .none
    private var requestListeners: [String: OnRequestListener] = [:]
    private var pendingOnRequest: [Int: ([ProxyRoute]?) -> Void] = [:]
    private var nextRequestID = 1
    private var activeTunnels: [ObjectIdentifier: RelayConnection] = [:]

    /// Test override for routing without touching `ExtensionEventPush`.
    var onRequestResolverOverride: ((String, String) async -> [ProxyRoute]?)?

    var needsRelay: Bool {
        if !requestListeners.isEmpty { return true }
        if case .none = mode { return false }
        return true
    }

    // MARK: Lifecycle & configuration

    func setMode(_ newMode: RelayMode) {
        queue.sync { mode = newMode }
        syncListenerState()
    }

    func registerOnRequest(extensionID: String, urls: [String]) {
        queue.sync {
            requestListeners[extensionID] = OnRequestListener(extensionID: extensionID, urlPatterns: urls)
        }
        syncListenerState()
        DispatchQueue.main.async {
            ExtensionSettings.shared.applyProxy(to: DataStores.all)
        }
    }

    func unregisterOnRequest(extensionID: String) {
        queue.sync {
            _ = requestListeners.removeValue(forKey: extensionID)
        }
        syncListenerState()
        DispatchQueue.main.async {
            ExtensionSettings.shared.applyProxy(to: DataStores.all)
        }
    }

    func extensionUnloaded(_ extensionID: String) {
        unregisterOnRequest(extensionID: extensionID)
    }

    func replyOnRequest(requestID: Int, result: Any?, error: String?) {
        let callback: (([ProxyRoute]?) -> Void)? = queue.sync {
            pendingOnRequest.removeValue(forKey: requestID)
        }
        guard let callback else { return }
        if let error, !error.isEmpty {
            emitError(error, fatal: false)
            callback(nil)
            return
        }
        if let dict = result as? [String: Any] {
            do {
                callback([try ProxyRoute.fromFirefoxProxyInfo(dict)])
            } catch {
                emitError(error.localizedDescription, fatal: false)
                callback(nil)
            }
        } else if let list = result as? [[String: Any]], !list.isEmpty {
            do {
                callback(try list.map(ProxyRoute.fromFirefoxProxyInfo))
            } catch {
                emitError(error.localizedDescription, fatal: false)
                callback(nil)
            }
        } else {
            callback(nil)
        }
    }

    /// Returns a `nw_proxy_config_t` pointing WebKit at this loopback relay, starting it if needed.
    func proxyConfiguration() -> nw_proxy_config_t? {
        guard needsRelay else { return nil }
        ensureStarted()
        let activePort = queue.sync { port }
        guard activePort > 0 else { return nil }
        let endpoint = nw_endpoint_create_host("127.0.0.1", String(activePort))
        let config = nw_proxy_config_create_http_connect(endpoint, nil)
        nw_proxy_config_set_username_and_password(config, "tuff", authToken)
        return config
    }

    /// Starts the loopback listener synchronously (up to 1s) so its ephemeral port is known immediately.
    @discardableResult
    func ensureStarted() -> UInt16 {
        let existing = queue.sync { port }
        if existing > 0 { return existing }

        let sem = DispatchSemaphore(value: 0)
        var boundPort: UInt16 = 0
        queue.sync {
            if self.listener != nil && self.port > 0 {
                boundPort = self.port
                sem.signal()
                return
            }
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
            guard let newListener = try? NWListener(using: params) else {
                sem.signal()
                return
            }
            newListener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let p = newListener.port?.rawValue {
                        self?.port = p
                        boundPort = p
                    }
                    sem.signal()
                case .failed, .cancelled:
                    self?.port = 0
                    sem.signal()
                default:
                    break
                }
            }
            newListener.newConnectionHandler = { [weak self] conn in
                self?.accept(conn)
            }
            self.listener = newListener
            newListener.start(queue: self.queue)
        }
        _ = sem.wait(timeout: .now() + 1)
        return boundPort
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            port = 0
            for tunnel in activeTunnels.values { tunnel.cancel() }
            activeTunnels.removeAll()
        }
    }

    private func syncListenerState() {
        if needsRelay {
            ensureStarted()
        } else {
            stop()
        }
    }

    func emitError(_ message: String, fatal: Bool = false) {
        DispatchQueue.main.async {
            ExtensionEventPush.shared.emit("proxy.onProxyError", args: [["fatal": fatal, "error": "net::ERR_PROXY_CONNECTION_FAILED", "details": message]])
            ExtensionEventPush.shared.emit("proxy.onError", args: [["message": message]])
        }
    }

    /// Fetches a PAC script from a URL (or macOS system WPAD / auto-config) and activates it.
    static func loadAutoDetectScript() async -> String? {
        if let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] {
            if let js = settings[kCFNetworkProxiesProxyAutoConfigJavaScript as String] as? String, !js.isEmpty {
                return js
            }
            if let urlStr = settings[kCFNetworkProxiesProxyAutoConfigURLString as String] as? String,
               let url = URL(string: urlStr),
               let (data, _) = try? await URLSession.shared.data(from: url),
               let js = String(data: data, encoding: .utf8), !js.isEmpty {
                return js
            }
        }
        if let wpad = URL(string: "http://wpad/wpad.dat") {
            var req = URLRequest(url: wpad)
            req.timeoutInterval = 2
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let js = String(data: data, encoding: .utf8), !js.isEmpty {
                return js
            }
        }
        return nil
    }

    // MARK: Route resolution

    func resolveRoutes(url: String, host: String, method: String, completion: @escaping ([ProxyRoute], Bool) -> Void) {
        if let override = onRequestResolverOverride {
            Task {
                if let routes = await override(url, host) {
                    completion(routes, false)
                } else {
                    self.resolveStaticOrPAC(url: url, host: host, completion: completion)
                }
            }
            return
        }

        let matchingListeners: [String] = queue.sync {
            requestListeners.values.compactMap { listener in
                Self.matchesAnyPattern(url, patterns: listener.urlPatterns) ? listener.extensionID : nil
            }
        }

        guard !matchingListeners.isEmpty else {
            resolveStaticOrPAC(url: url, host: host, completion: completion)
            return
        }

        // Ask the first matching Firefox proxy.onRequest listener.
        let extID = matchingListeners[0]
        let reqID: Int = queue.sync {
            let id = nextRequestID
            nextRequestID += 1
            pendingOnRequest[id] = { [weak self] routes in
                if let routes {
                    completion(routes, false)
                } else {
                    self?.resolveStaticOrPAC(url: url, host: host, completion: completion)
                }
            }
            return id
        }

        let details: [String: Any] = [
            "requestId": String(reqID),
            "url": url,
            "method": method,
            "type": method == "CONNECT" ? "other" : "main_frame",
            "timeStamp": Date().timeIntervalSince1970 * 1000,
            "frameId": 0,
            "tabId": -1,
        ]
        DispatchQueue.main.async {
            ExtensionEventPush.shared.emit("proxy.onRequest", args: [details], extra: ["proxyRequestId": reqID], to: extID)
        }
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, let cb = self.pendingOnRequest.removeValue(forKey: reqID) else { return }
            cb(nil)
        }
    }

    private func resolveStaticOrPAC(url: String, host: String, completion: @escaping ([ProxyRoute], Bool) -> Void) {
        let currentMode = queue.sync { mode }
        switch currentMode {
        case .none, .direct:
            completion([.direct], false)
        case .staticRoutes(let routes, let bypass):
            if Self.matchesBypass(host: host, bypassList: bypass) {
                completion([.direct], false)
            } else {
                completion(routes, false)
            }
        case .pac(let evaluator, let mandatory):
            do {
                let routes = try evaluator.evaluate(url: url, host: host)
                completion(routes, mandatory)
            } catch {
                emitError(error.localizedDescription, fatal: mandatory)
                completion(mandatory ? [] : [.direct], mandatory)
            }
        }
    }

    private static func matchesBypass(host: String, bypassList: [String]) -> Bool {
        let lower = host.lowercased()
        for raw in bypassList {
            let item = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if item.isEmpty { continue }
            if item == "<local>" && (!lower.contains(".") || lower == "localhost" || lower == "127.0.0.1") { return true }
            if item == lower { return true }
            if item.hasPrefix("*.") {
                let suffix = String(item.dropFirst(2))
                if lower == suffix || lower.hasSuffix("." + suffix) { return true }
            } else if item.hasPrefix("."), lower.hasSuffix(item) {
                return true
            }
        }
        return false
    }

    static func matchesAnyPattern(_ url: String, patterns: [String]) -> Bool {
        if patterns.isEmpty { return true }
        for pattern in patterns {
            if pattern == "<all_urls>" || pattern == "*://*/*" { return true }
            let escaped = NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*")
            if let regex = try? NSRegularExpression(pattern: "^\(escaped)$", options: [.caseInsensitive]),
               regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil {
                return true
            }
        }
        return false
    }

    // MARK: Connection handling

    private func accept(_ client: NWConnection) {
        let conn = RelayConnection(client: client, expectedAuth: expectedAuthHeader, relay: self, queue: queue)
        let key = ObjectIdentifier(conn)
        activeTunnels[key] = conn
        conn.onClose = { [weak self] in
            self?.activeTunnels.removeValue(forKey: key)
        }
        conn.start()
    }
}

/// Handles one client connection to `ExtensionProxyRelay` (HTTP CONNECT or plain HTTP proxy request).
private final class RelayConnection {
    private let client: NWConnection
    private let expectedAuth: String
    private weak var relay: ExtensionProxyRelay?
    private let queue: DispatchQueue
    private var buffer = Data()
    private var upstream: NWConnection?
    private var closed = false
    var onClose: (() -> Void)?

    init(client: NWConnection, expectedAuth: String, relay: ExtensionProxyRelay, queue: DispatchQueue) {
        self.client = client
        self.expectedAuth = expectedAuth
        self.relay = relay
        self.queue = queue
    }

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.cancel() }
            if case .cancelled = state { self?.cancel() }
        }
        client.start(queue: queue)
        readRequestHeaders()
    }

    func cancel() {
        guard !closed else { return }
        closed = true
        client.cancel()
        upstream?.cancel()
        upstream = nil
        onClose?()
        onClose = nil
    }

    private func readRequestHeaders() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                if let sep = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let headData = self.buffer[..<sep.lowerBound]
                    let remainder = Data(self.buffer[sep.upperBound...])
                    self.handleHeader(headData, remainder: remainder)
                    return
                }
                if self.buffer.count > 65_536 {
                    self.sendErrorAndClose("431 Request Header Fields Too Large")
                    return
                }
            }
            if isComplete || error != nil {
                self.cancel()
            } else {
                self.readRequestHeaders()
            }
        }
    }

    private func handleHeader(_ headData: Data, remainder: Data) {
        guard let headText = String(data: headData, encoding: .utf8) else {
            sendErrorAndClose("400 Bad Request")
            return
        }
        let lines = headText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendErrorAndClose("400 Bad Request")
            return
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else {
            sendErrorAndClose("400 Bad Request")
            return
        }
        let method = parts[0].uppercased()
        let target = parts[1]
        let version = parts.count >= 3 ? parts[2] : "HTTP/1.1"

        var authOK = false
        var filteredHeaders: [String] = []
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("proxy-authorization:") {
                let value = line.dropFirst("proxy-authorization:".count).trimmingCharacters(in: .whitespaces)
                if value == expectedAuth { authOK = true }
                continue
            }
            if lower.hasPrefix("proxy-connection:") { continue }
            filteredHeaders.append(line)
        }
        guard authOK else {
            sendErrorAndClose("407 Proxy Authentication Required")
            return
        }

        let targetHost: String
        let targetPort: Int
        let fullURL: String
        let isConnect = method == "CONNECT"

        if isConnect {
            guard let (h, p) = ProxyRoute.splitHostPort(target) else {
                sendErrorAndClose("400 Bad Request")
                return
            }
            targetHost = h
            targetPort = p ?? 443
            fullURL = "https://\(targetHost)\(targetPort == 443 ? "" : ":\(targetPort)")/"
        } else {
            guard let parsed = URL(string: target), let h = parsed.host else {
                sendErrorAndClose("400 Bad Request")
                return
            }
            targetHost = h
            targetPort = parsed.port ?? (parsed.scheme?.lowercased() == "https" ? 443 : 80)
            fullURL = target
        }

        relay?.resolveRoutes(url: fullURL, host: targetHost, method: method) { [weak self] routes, _ in
            guard let self, !self.closed else { return }
            guard !routes.isEmpty else {
                self.sendErrorAndClose("502 Bad Gateway")
                return
            }
            let forwardRequest: Data?
            if isConnect {
                forwardRequest = nil
            } else {
                let parsed = URL(string: target)
                let path = (parsed?.path.isEmpty == false ? parsed!.path : "/") + (parsed?.query.map { "?\($0)" } ?? "")
                let rebuilt = "\(method) \(path) \(version)\r\n" + filteredHeaders.joined(separator: "\r\n") + "\r\n\r\n"
                var payload = Data(rebuilt.utf8)
                payload.append(remainder)
                forwardRequest = payload
            }
            let rawProxyRequest: Data?
            if isConnect {
                rawProxyRequest = nil
            } else {
                let rebuilt = "\(method) \(target) \(version)\r\n" + filteredHeaders.joined(separator: "\r\n") + "\r\n\r\n"
                var payload = Data(rebuilt.utf8)
                payload.append(remainder)
                rawProxyRequest = payload
            }
            self.tryRoutes(
                routes, index: 0, targetHost: targetHost, targetPort: targetPort,
                isConnect: isConnect, directPayload: forwardRequest, proxyPayload: rawProxyRequest,
                connectRemainder: remainder
            )
        }
    }

    private func tryRoutes(
        _ routes: [ProxyRoute], index: Int,
        targetHost: String, targetPort: Int,
        isConnect: Bool, directPayload: Data?, proxyPayload: Data?, connectRemainder: Data
    ) {
        guard !closed else { return }
        guard routes.indices.contains(index) else {
            relay?.emitError("All proxy routes failed for \(targetHost):\(targetPort).")
            sendErrorAndClose("502 Bad Gateway")
            return
        }
        let route = routes[index]
        let tryNext: (String) -> Void = { [weak self] reason in
            guard let self, !self.closed else { return }
            self.upstream?.cancel()
            self.upstream = nil
            if index + 1 < routes.count {
                self.tryRoutes(
                    routes, index: index + 1, targetHost: targetHost, targetPort: targetPort,
                    isConnect: isConnect, directPayload: directPayload, proxyPayload: proxyPayload,
                    connectRemainder: connectRemainder
                )
            } else {
                self.relay?.emitError(reason)
                self.sendErrorAndClose("502 Bad Gateway")
            }
        }

        switch route {
        case .direct:
            connectTCP(host: targetHost, port: targetPort, tls: false) { [weak self] result in
                guard let self, !self.closed else { return }
                switch result {
                case .failure(let err):
                    tryNext(err.localizedDescription)
                case .success(let conn):
                    self.upstream = conn
                    if isConnect {
                        self.sendConnectEstablishedAndPump(upstream: conn, remainder: connectRemainder)
                    } else if let directPayload {
                        conn.send(content: directPayload, completion: .contentProcessed { _ in
                            self.pump(from: self.client, to: conn)
                            self.pump(from: conn, to: self.client)
                        })
                    }
                }
            }

        case .http(let host, let port, let tls, let username, let password):
            connectTCP(host: host, port: port, tls: tls) { [weak self] result in
                guard let self, !self.closed else { return }
                switch result {
                case .failure(let err):
                    tryNext(err.localizedDescription)
                case .success(let conn):
                    self.upstream = conn
                    let authLine: String
                    if let username {
                        let cred = Data("\(username):\(password ?? "")".utf8).base64EncodedString()
                        authLine = "Proxy-Authorization: Basic \(cred)\r\n"
                    } else {
                        authLine = ""
                    }
                    if isConnect {
                        let req = "CONNECT \(targetHost):\(targetPort) HTTP/1.1\r\nHost: \(targetHost):\(targetPort)\r\n\(authLine)\r\n"
                        conn.send(content: Data(req.utf8), completion: .contentProcessed { err in
                            if let err { tryNext(err.localizedDescription); return }
                            self.readUpstreamHTTPStatus(conn: conn) { ok in
                                if ok {
                                    self.sendConnectEstablishedAndPump(upstream: conn, remainder: connectRemainder)
                                } else {
                                    tryNext("Upstream HTTP proxy rejected CONNECT.")
                                }
                            }
                        })
                    } else if var payload = proxyPayload {
                        if !authLine.isEmpty, let firstCRLF = payload.range(of: Data("\r\n".utf8)) {
                            payload.insert(contentsOf: Data(authLine.utf8), at: firstCRLF.upperBound)
                        }
                        conn.send(content: payload, completion: .contentProcessed { err in
                            if let err { tryNext(err.localizedDescription); return }
                            self.pump(from: self.client, to: conn)
                            self.pump(from: conn, to: self.client)
                        })
                    }
                }
            }

        case .socks5(let host, let port, let username, let password):
            connectTCP(host: host, port: port, tls: false) { [weak self] result in
                guard let self, !self.closed else { return }
                switch result {
                case .failure(let err):
                    tryNext(err.localizedDescription)
                case .success(let conn):
                    self.upstream = conn
                    self.socks5Handshake(
                        conn: conn, targetHost: targetHost, targetPort: targetPort,
                        username: username, password: password
                    ) { error in
                        if let error { tryNext(error); return }
                        if isConnect {
                            self.sendConnectEstablishedAndPump(upstream: conn, remainder: connectRemainder)
                        } else if let directPayload {
                            conn.send(content: directPayload, completion: .contentProcessed { _ in
                                self.pump(from: self.client, to: conn)
                                self.pump(from: conn, to: self.client)
                            })
                        }
                    }
                }
            }

        case .socks4(let host, let port, let userID):
            connectTCP(host: host, port: port, tls: false) { [weak self] result in
                guard let self, !self.closed else { return }
                switch result {
                case .failure(let err):
                    tryNext(err.localizedDescription)
                case .success(let conn):
                    self.upstream = conn
                    self.socks4Handshake(conn: conn, targetHost: targetHost, targetPort: targetPort, userID: userID) { error in
                        if let error { tryNext(error); return }
                        if isConnect {
                            self.sendConnectEstablishedAndPump(upstream: conn, remainder: connectRemainder)
                        } else if let directPayload {
                            conn.send(content: directPayload, completion: .contentProcessed { _ in
                                self.pump(from: self.client, to: conn)
                                self.pump(from: conn, to: self.client)
                            })
                        }
                    }
                }
            }
        }
    }

    private func connectTCP(host: String, port: Int, tls: Bool, completion: @escaping (Result<NWConnection, Error>) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            completion(.failure(ExtensionSettings.Failure("Invalid port \(port).")))
            return
        }
        let params: NWParameters = tls ? .tls : .tcp
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        var settled = false
        conn.stateUpdateHandler = { state in
            guard !settled else { return }
            switch state {
            case .ready:
                settled = true
                completion(.success(conn))
            case .failed(let error):
                settled = true
                conn.cancel()
                completion(.failure(error))
            case .cancelled:
                settled = true
                completion(.failure(ExtensionSettings.Failure("Connection cancelled.")))
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func readUpstreamHTTPStatus(conn: NWConnection, accumulated: Data = Data(), completion: @escaping (Bool) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { completion(false); return }
            var buf = accumulated
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                let text = String(data: buf[..<end.lowerBound], encoding: .utf8) ?? ""
                let firstLine = text.components(separatedBy: "\r\n").first ?? ""
                let parts = firstLine.split(separator: " ")
                let ok = parts.count >= 2 && parts[1].hasPrefix("2")
                completion(ok)
                return
            }
            if isComplete || error != nil || buf.count > 16_384 {
                completion(false)
            } else {
                self.readUpstreamHTTPStatus(conn: conn, accumulated: buf, completion: completion)
            }
        }
    }

    private func socks5Handshake(
        conn: NWConnection, targetHost: String, targetPort: Int,
        username: String?, password: String?, completion: @escaping (String?) -> Void
    ) {
        let greeting: Data = username != nil ? Data([0x05, 0x02, 0x00, 0x02]) : Data([0x05, 0x01, 0x00])
        conn.send(content: greeting, completion: .contentProcessed { err in
            if let err { completion(err.localizedDescription); return }
            conn.receive(minimumIncompleteLength: 2, maximumLength: 2) { data, _, _, err in
                guard err == nil, let data, data.count == 2, data[0] == 0x05 else {
                    completion("SOCKS5 greeting failed.")
                    return
                }
                let sendConnect = {
                    let hostBytes = Array(targetHost.utf8)
                    guard hostBytes.count <= 255 else { completion("Hostname too long for SOCKS5."); return }
                    var req = Data([0x05, 0x01, 0x00, 0x03, UInt8(hostBytes.count)])
                    req.append(contentsOf: hostBytes)
                    req.append(UInt8((targetPort >> 8) & 0xFF))
                    req.append(UInt8(targetPort & 0xFF))
                    conn.send(content: req, completion: .contentProcessed { err in
                        if let err { completion(err.localizedDescription); return }
                        conn.receive(minimumIncompleteLength: 4, maximumLength: 512) { resp, _, _, err in
                            guard err == nil, let resp, resp.count >= 4, resp[0] == 0x05, resp[1] == 0x00 else {
                                completion("SOCKS5 CONNECT rejected.")
                                return
                            }
                            completion(nil)
                        }
                    })
                }
                switch data[1] {
                case 0x00:
                    sendConnect()
                case 0x02:
                    let u = Array((username ?? "").utf8), p = Array((password ?? "").utf8)
                    guard u.count <= 255, p.count <= 255 else { completion("SOCKS5 credentials too long."); return }
                    var auth = Data([0x01, UInt8(u.count)])
                    auth.append(contentsOf: u)
                    auth.append(UInt8(p.count))
                    auth.append(contentsOf: p)
                    conn.send(content: auth, completion: .contentProcessed { err in
                        if let err { completion(err.localizedDescription); return }
                        conn.receive(minimumIncompleteLength: 2, maximumLength: 2) { resp, _, _, err in
                            guard err == nil, let resp, resp.count == 2, resp[1] == 0x00 else {
                                completion("SOCKS5 authentication failed.")
                                return
                            }
                            sendConnect()
                        }
                    })
                default:
                    completion("SOCKS5 server rejected authentication methods.")
                }
            }
        })
    }

    private func socks4Handshake(
        conn: NWConnection, targetHost: String, targetPort: Int, userID: String?,
        completion: @escaping (String?) -> Void
    ) {
        var req = Data([0x04, 0x01, UInt8((targetPort >> 8) & 0xFF), UInt8(targetPort & 0xFF)])
        var ipv4 = in_addr()
        if inet_pton(AF_INET, targetHost, &ipv4) == 1 {
            withUnsafeBytes(of: &ipv4) { req.append(contentsOf: $0) }
            req.append(contentsOf: (userID ?? "").utf8)
            req.append(0x00)
        } else {
            // SOCKS4a: 0.0.0.1 + userid\0 + domain\0
            req.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            req.append(contentsOf: (userID ?? "").utf8)
            req.append(0x00)
            req.append(contentsOf: targetHost.utf8)
            req.append(0x00)
        }
        conn.send(content: req, completion: .contentProcessed { err in
            if let err { completion(err.localizedDescription); return }
            conn.receive(minimumIncompleteLength: 8, maximumLength: 8) { resp, _, _, err in
                guard err == nil, let resp, resp.count == 8, resp[1] == 0x5A else {
                    completion("SOCKS4 CONNECT rejected.")
                    return
                }
                completion(nil)
            }
        })
    }

    private func sendConnectEstablishedAndPump(upstream: NWConnection, remainder: Data) {
        let ok = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
        client.send(content: ok, completion: .contentProcessed { [weak self] err in
            guard let self, !self.closed, err == nil else { self?.cancel(); return }
            let startPump = {
                self.pump(from: self.client, to: upstream)
                self.pump(from: upstream, to: self.client)
            }
            if !remainder.isEmpty {
                upstream.send(content: remainder, completion: .contentProcessed { _ in startPump() })
            } else {
                startPump()
            }
        })
    }

    private func pump(from source: NWConnection, to dest: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                dest.send(content: data, completion: .contentProcessed { [weak self] sendErr in
                    if sendErr != nil {
                        self?.cancel()
                    } else if isComplete {
                        self?.cancel()
                    } else {
                        self?.pump(from: source, to: dest)
                    }
                })
            } else if isComplete || error != nil {
                self.cancel()
            } else {
                self.pump(from: source, to: dest)
            }
        }
    }

    private func sendErrorAndClose(_ status: String) {
        let resp = Data("HTTP/1.1 \(status)\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8)
        client.send(content: resp, completion: .contentProcessed { [weak self] _ in
            self?.cancel()
        })
    }
}
