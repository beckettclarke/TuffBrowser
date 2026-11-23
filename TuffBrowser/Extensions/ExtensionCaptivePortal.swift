import Foundation
import Network

/// Firefox's `browser.captivePortal` API: monitors network connectivity with `NWPathMonitor` and
/// probes Apple's captive portal detection endpoint (`http://captive.apple.com/hotspot-detect.html`)
/// to report `unknown`, `not_captive`, `locked_portal` or `unlocked_portal`, plus
/// `onStateChanged` and `onConnectivityAvailable`. Monitoring starts lazily when an extension
/// queries state or subscribes to an event.
final class ExtensionCaptivePortal {
    static let shared = ExtensionCaptivePortal()

    static let canonicalURL = "http://captive.apple.com/hotspot-detect.html"

    enum State: String {
        case unknown
        case notCaptive = "not_captive"
        case unlockedPortal = "unlocked_portal"
        case lockedPortal = "locked_portal"
    }

    enum ProbeResult: Equatable {
        case clear
        case captive
        case unreachable
    }

    private(set) var state: State = .unknown
    private(set) var lastChecked: Date?
    private var monitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "tuff.captive-portal")
    private var probeInFlight = false
    private var pendingCallbacks: [(String) -> Void] = []
    private let emitEvents: Bool

    init(emitEvents: Bool = true) {
        self.emitEvents = emitEvents
    }

    /// Starts observing macOS network path changes (idempotent).
    func startMonitoring() {
        guard monitor == nil else { return }
        let pathMonitor = NWPathMonitor()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                if path.status != .satisfied {
                    self.apply(probe: .unreachable, now: Date())
                } else {
                    self.runProbe()
                }
            }
        }
        monitor = pathMonitor
        pathMonitor.start(queue: monitorQueue)
    }

    func getState(finish: @escaping (Any?) -> Void) {
        startMonitoring()
        if let lastChecked, Date().timeIntervalSince(lastChecked) < 10, state != .unknown {
            finish(state.rawValue)
            return
        }
        pendingCallbacks.append { finish($0) }
        runProbe()
    }

    func getLastChecked() -> Int {
        guard let lastChecked else { return 0 }
        return max(0, Int((Date().timeIntervalSince(lastChecked) * 1000).rounded()))
    }

    /// Pure state transition from a probe result; returns any events emitted (for testing).
    @discardableResult
    func apply(probe: ProbeResult, now: Date = Date()) -> (stateChanged: String?, connectivity: String?) {
        let previous = state
        let next: State
        var connectivity: String?
        switch probe {
        case .unreachable:
            next = .unknown
        case .captive:
            next = .lockedPortal
        case .clear:
            if previous == .lockedPortal {
                next = .unlockedPortal
                connectivity = "captive"
            } else {
                next = .notCaptive
                if previous == .unknown { connectivity = "clear" }
            }
        }
        state = next
        lastChecked = now
        let stateChanged = next != previous ? next.rawValue : nil
        if emitEvents {
            if let stateChanged {
                ExtensionEventPush.shared.emit("captivePortal.onStateChanged", args: [["state": stateChanged]])
            }
            if let connectivity {
                ExtensionEventPush.shared.emit("captivePortal.onConnectivityAvailable", args: [connectivity])
            }
        }
        return (stateChanged, connectivity)
    }

    private func runProbe() {
        guard !probeInFlight else { return }
        probeInFlight = true
        Self.probe { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.probeInFlight = false
                self.apply(probe: result, now: Date())
                let callbacks = self.pendingCallbacks
                self.pendingCallbacks.removeAll()
                let value = self.state.rawValue
                callbacks.forEach { $0(value) }
            }
        }
    }

    /// Evaluates an HTTP response from Apple's captive portal endpoint.
    static func classify(statusCode: Int, body: String?) -> ProbeResult {
        if (300..<400).contains(statusCode) { return .captive }
        if statusCode == 200 {
            return (body ?? "").contains("Success") ? .clear : .captive
        }
        return .unreachable
    }

    private static func probe(completion: @escaping (ProbeResult) -> Void) {
        guard let url = URL(string: canonicalURL) else { return completion(.unreachable) }
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 5
        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.setValue("CaptiveNetworkSupport-450 wispr", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { data, response, error in
            defer { session.finishTasksAndInvalidate() }
            if error != nil { return completion(.unreachable) }
            guard let http = response as? HTTPURLResponse else { return completion(.unreachable) }
            let body = data.flatMap { String(data: $0, encoding: .utf8) }
            completion(classify(statusCode: http.statusCode, body: body))
        }.resume()
    }

    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            // Do not follow redirects: a redirect on the captive probe URL means a locked portal.
            completionHandler(nil)
        }
    }
}
