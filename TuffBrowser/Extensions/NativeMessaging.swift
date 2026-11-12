import Foundation
import WebKit

/// Chrome / Firefox style native messaging: launches the helper app an extension asks for
/// (`runtime.connectNative`) and exchanges length-prefixed JSON with it over stdio.
///
/// Hosts are discovered from the same manifest folders Chrome and Firefox use, and — like
/// those browsers — a host is only launched for extensions its manifest explicitly allows.
final class NativeMessagingHost {
    var onMessage: ((Any) -> Void)?
    var onExit: (() -> Void)?

    private let executable: URL
    private let origin: String
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()

    static func notFound(_ name: String?) -> NSError {
        NSError(domain: "Tuff.NativeMessaging", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Specified native messaging host not found: \(name ?? "?")",
        ])
    }

    private static var searchDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Application Support/TuffBrowser/NativeMessagingHosts"),
            home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts"),
            URL(fileURLWithPath: "/Library/Google/Chrome/NativeMessagingHosts"),
            home.appendingPathComponent("Library/Application Support/Chromium/NativeMessagingHosts"),
            home.appendingPathComponent("Library/Application Support/Mozilla/NativeMessagingHosts"),
            URL(fileURLWithPath: "/Library/Application Support/Mozilla/NativeMessagingHosts"),
        ]
    }

    init?(application: String, context: WKWebExtensionContext) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TUFF_NO_NATIVE_MESSAGING"] != nil { return nil }
        #endif
        // Host names are restricted to [a-z0-9_.], which also keeps them from escaping the folder.
        guard application.range(of: "^[a-z0-9_]+(\\.[a-z0-9_]+)*$", options: .regularExpression) != nil else { return nil }

        let chromeOrigin = "chrome-extension://\(context.uniqueIdentifier)/"
        let gecko = ((context.webExtension.manifest["browser_specific_settings"] as? [String: Any])?["gecko"] as? [String: Any])?["id"] as? String

        for directory in Self.searchDirectories {
            let file = directory.appendingPathComponent(application + ".json")
            guard let data = try? Data(contentsOf: file),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  manifest["name"] as? String == application,
                  (manifest["type"] as? String ?? "stdio") == "stdio",
                  let path = manifest["path"] as? String, path.hasPrefix("/") else { continue }

            let allowedOrigins = manifest["allowed_origins"] as? [String] ?? []
            let allowedExtensions = manifest["allowed_extensions"] as? [String] ?? []
            let allowed = allowedOrigins.contains(chromeOrigin) || (gecko.map { allowedExtensions.contains($0) } ?? false)
            guard allowed, FileManager.default.isExecutableFile(atPath: path) else { continue }

            executable = URL(fileURLWithPath: path)
            origin = allowedOrigins.contains(chromeOrigin) ? chromeOrigin : (gecko ?? chromeOrigin)
            return
        }
        return nil
    }

    func start() {
        process.executableURL = executable
        process.arguments = [origin]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(chunk) }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.output.fileHandleForReading.readabilityHandler = nil
                self?.onExit?()
            }
        }
        do {
            try process.run()
        } catch {
            DispatchQueue.main.async { [weak self] in self?.onExit?() }
        }
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    func send(_ message: Any) {
        guard process.isRunning,
              JSONSerialization.isValidJSONObject(message) || message is String || message is NSNumber,
              let body = try? JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed]) else { return }
        var length = UInt32(body.count).littleEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        try? input.fileHandleForWriting.write(contentsOf: frame)
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while buffer.count >= 4 {
            let length = buffer.prefix(4).withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
            // Hosts may send at most 1 MB per message; anything else means the stream is corrupt.
            guard length <= 1_048_576 else { stop(); return }
            guard buffer.count >= 4 + length else { return }
            let body = buffer.subdata(in: (buffer.startIndex + 4)..<(buffer.startIndex + 4 + length))
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + 4 + length))
            if let object = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) {
                onMessage?(object)
            }
        }
    }
}
