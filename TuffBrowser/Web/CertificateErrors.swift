import AppKit
import CryptoKit
import SecurityInterface
import WebKit

/// A page that failed because its certificate isn't trusted (expired, self-signed, unknown
/// issuer, not valid yet). The error page offers to show the certificate and to visit anyway.
struct CertificateFailure {
    var url: URL
    var host: String
    var port: Int
    var trust: SecTrust?
    var code: Int

    /// The URL error codes a person can choose to get past (a bad TLS connection can't be).
    static let bypassableCodes: Set<Int> = [
        NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
        NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
    ]

    init?(error: NSError, url: URL) {
        guard error.domain == NSURLErrorDomain, Self.bypassableCodes.contains(error.code),
              let host = url.host(percentEncoded: false) else { return nil }
        self.url = url
        self.host = host
        self.port = url.port ?? 443
        self.code = error.code
        if let peer = error.userInfo[NSURLErrorFailingURLPeerTrustErrorKey] {
            trust = (peer as! SecTrust)
        } else if let chain = error.userInfo["NSErrorPeerCertificateChainKey"] as? [Any], !chain.isEmpty {
            var made: SecTrust?
            SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateSSL(true, host as CFString), &made)
            trust = made
        }
    }

    var reason: String {
        switch code {
        case NSURLErrorServerCertificateHasBadDate: "Its certificate has expired."
        case NSURLErrorServerCertificateNotYetValid: "Its certificate isn’t valid yet."
        case NSURLErrorServerCertificateHasUnknownRoot: "Its certificate was issued by an authority this Mac doesn’t trust."
        default: "Its certificate isn’t trusted."
        }
    }
}

/// Certificates the user chose to trust anyway, by host, port and the exact certificate (a
/// different bad certificate on the same site asks again). Kept until Tuff quits, as in Chrome.
final class CertificateExceptions {
    static let shared = CertificateExceptions()
    private var allowed: Set<String> = []

    private static func key(host: String, port: Int, trust: SecTrust) -> String? {
        guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else { return nil }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
        return "\(host.lowercased()):\(port)|" + digest.map { String(format: "%02x", $0) }.joined()
    }

    func allow(_ failure: CertificateFailure) {
        guard let trust = failure.trust, let key = Self.key(host: failure.host, port: failure.port, trust: trust) else { return }
        allowed.insert(key)
    }

    /// Whether a server's certificate was let through by hand. Only a match of host, port and
    /// certificate counts.
    func allows(_ trust: SecTrust, host: String, port: Int) -> Bool {
        guard !allowed.isEmpty, let key = Self.key(host: host, port: port, trust: trust) else { return false }
        return allowed.contains(key)
    }
}

extension WebEngine {
    /// The error page for a certificate problem, with Show Certificate / Visit Anyway buttons
    /// that talk to `CertificateErrorHandler`.
    static func certificateErrorPage(for failure: CertificateFailure) -> String {
        let canShow = failure.trust != nil
        var buttons: [StatusButton] = [
            .init(label: "Go Back", primary: true, key: "↩", action: "history.length > 1 ? history.back() : location.replace('about:blank')"),
        ]
        if canShow { buttons.append(.init(label: "Show Certificate", primary: false, key: nil, action: "tuffCert('show')")) }
        buttons.append(.init(label: "Visit Anyway…", primary: false, key: nil, action: "tuffCert('proceed')"))
        return statusPage(
            title: "Not a secure connection",
            heading: "This connection isn’t private",
            message: "\(failure.host) may be pretending to be another site to steal your information. \(failure.reason)",
            detail: failure.host,
            icon: .shield,
            tone: .warning,
            buttons: buttons,
            script: """
            function tuffCert(action) {
              const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(CertificateErrorHandler.name);
              if (h) h.postMessage(action);
            }
            """
        )
    }
}

/// The certificate error page's buttons. A message only counts from the main frame of a tab
/// that is showing the error page for that very site (`Tab.certificateFailure`), so no other
/// page can use it, and visiting anyway still asks on a card of Tuff's own.
final class CertificateErrorHandler: NSObject, WKScriptMessageHandler {
    static let name = "tuffCertificate"
    static let shared = CertificateErrorHandler()

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let tab = (message.webView as? TuffWebView)?.tab, let failure = tab.certificateFailure,
              message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.host.lowercased() == failure.host.lowercased(),
              let action = message.body as? String else { return }
        switch action {
        case "show":
            guard let trust = failure.trust, let window = message.webView?.window else { return }
            SFCertificateTrustPanel.shared()?.beginSheet(
                for: window, modalDelegate: nil, didEnd: nil, contextInfo: nil,
                trust: trust, message: "The certificate for \(failure.host)"
            )
        case "proceed":
            let prompt = Prompt(
                icon: nil,
                symbol: "exclamationmark.shield.fill",
                symbolColor: .systemOrange,
                title: "Visit “\(failure.host)” anyway?",
                message: "\(failure.reason) Anyone on your network might be able to see or change what you send to this site. Only continue if you know why, such as a test server of your own.",
                confirmTitle: "Visit Anyway",
                destructive: true
            )
            Task { @MainActor in
                guard let result = await tab.askForPage(prompt), result.confirmed, tab.certificateFailure != nil else { return }
                CertificateExceptions.shared.allow(failure)
                tab.certificateFailure = nil
                tab.load(failure.url)
            }
        default:
            break
        }
    }
}
