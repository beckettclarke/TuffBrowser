import Foundation
import WebKit

/// Chrome / Firefox style native messaging: launches the helper app an extension asks for
/// (`runtime.connectNative`) and exchanges length-prefixed JSON with it over stdio.
///
/// Hosts are discovered from the same manifest folders Chrome and Firefox use, and — like
/// those browsers — a host is only launched for extensions its manifest explicitly allows.
final class NativeMessagingHost {
    var onMessage: ((Any) -> Void)?
    /// Called once when the host goes away, with the reason if it didn't end cleanly.
    var onExit: ((NSError?) -> Void)?

    private let executable: URL
    private let origin: String
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private var buffer = Data()
    /// The end of what the host wrote to stderr, for the error an extension gets and the log.
    private var stderrTail = Data()
    private let name: String

    static func notFound(_ name: String?) -> NSError {
        error(1, "Specified native messaging host not found: \(name ?? "?")")
    }

    static func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "Tuff.NativeMessaging", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static var searchDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Application Support/TuffBrowser/NativeMessagingHosts"),
            home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts"),
            URL(fileURLWithPath: "/Library/Google/Chrome/NativeMessagingHosts"),
            home.appendingPathComponent("Library/Application Support/Chromium/NativeMessagingHosts"),
            URL(fileURLWithPath: "/Library/Application Support/Chromium/NativeMessagingHosts"),
            home.appendingPathComponent("Library/Application Support/Mozilla/NativeMessagingHosts"),
            URL(fileURLWithPath: "/Library/Application Support/Mozilla/NativeMessagingHosts"),
        ]
    }

    init?(application: String, context: WKWebExtensionContext) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TUFF_NO_NATIVE_MESSAGING"] != nil { return nil }
        #endif
        name = application
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
        process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.stderrTail.append(chunk)
                if self.stderrTail.count > 4096 { self.stderrTail = self.stderrTail.suffix(4096) }
            }
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(chunk) }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            let reason = process.terminationReason
            DispatchQueue.main.async {
                guard let self else { return }
                self.output.fileHandleForReading.readabilityHandler = nil
                self.errors.fileHandleForReading.readabilityHandler = nil
                let stderr = String(decoding: self.stderrTail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !stderr.isEmpty { NSLog("Tuff: native host \(self.name) stderr: \(stderr)") }
                guard !self.stopped, status != 0 || reason == .uncaughtSignal else { self.onExit?(nil); return }
                var message = "Native host has exited (\(reason == .uncaughtSignal ? "signal" : "status") \(status))."
                if let last = stderr.split(separator: "\n").last { message += " " + last }
                self.onExit?(Self.error(3, message))
            }
        }
        do {
            try process.run()
        } catch {
            NSLog("Tuff: couldn’t start native host \(name): \(error.localizedDescription)")
            let failure = Self.error(2, "Failed to start native messaging host: \(error.localizedDescription)")
            DispatchQueue.main.async { [weak self] in self?.onExit?(failure) }
        }
    }

    private var stopped = false

    func stop() {
        stopped = true
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    /// Writes one message to the host. Throws (instead of dropping it) when the host isn't
    /// running, the message can't be sent as JSON, or it is bigger than hosts accept.
    func send(_ message: Any) throws {
        guard process.isRunning else { throw Self.error(4, "Native host has exited.") }
        guard JSONSerialization.isValidJSONObject(message) || message is String || message is NSNumber || message is NSNull,
              let body = try? JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed]) else {
            throw Self.error(5, "The message couldn’t be sent to the native host as JSON.")
        }
        // Chrome's limit for messages to a host is 64 MiB.
        guard body.count <= 64 * 1_048_576 else { throw Self.error(6, "The message is too large for the native host.") }
        var length = UInt32(body.count).littleEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        do {
            try input.fileHandleForWriting.write(contentsOf: frame)
        } catch {
            throw Self.error(7, "Error when communicating with the native messaging host.")
        }
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
