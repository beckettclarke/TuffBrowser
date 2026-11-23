import AppKit

/// Tuff's application: keys an extension sent to a page through `chrome.debugger` that the page
/// didn't handle come back here from WebKit, and must not reach Tuff's menus (see `ExtensionDebugger`).
final class TuffApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        if ExtensionDebugger.swallowsReturnedKey(event) { return }
        super.sendEvent(event)
    }
}

let app = TuffApplication.shared
// Hosting unit tests (TuffBrowserTests): don't open windows, restore the session or start
// extensions — the tests only call into the app's code, and must never touch the real profile.
let hostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
let delegate: AppDelegate? = hostingTests ? nil : AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
