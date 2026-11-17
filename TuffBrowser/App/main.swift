import AppKit

let app = NSApplication.shared
// Hosting unit tests (TuffBrowserTests): don't open windows, restore the session or start
// extensions — the tests only call into the app's code, and must never touch the real profile.
let hostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
let delegate: AppDelegate? = hostingTests ? nil : AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
