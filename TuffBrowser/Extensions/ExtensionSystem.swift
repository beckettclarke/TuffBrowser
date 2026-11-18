import AppKit
import Darwin
import IOKit.pwr_mgt

/// Native `chrome.system.*`, `chrome.power` and `chrome.idle` for extensions — read-only system
/// information, keep-awake power assertions, and the user's idle state. Routed here by
/// `ExtensionAPIBridge`. `idle.onStateChanged` and detection intervals use the event-push relay.
final class ExtensionSystem {
    static let shared = ExtensionSystem()

    /// Keep-awake assertions, one per extension so they don't clobber each other.
    private var assertions: [String: IOPMAssertionID] = [:]
    /// idle.onStateChanged monitoring.
    private var idleTimer: Timer?
    private var idleInterval = 60
    private var lastIdleState = "active"

    // MARK: system.cpu / memory / storage

    func cpuInfo() -> [String: Any] {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return [
            "numOfProcessors": ProcessInfo.processInfo.processorCount,
            "archName": arch,
            "modelName": cpuModel(),
            "features": [String](),
            "processors": [[String: Any]](),
        ]
    }

    private func cpuModel() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    func memoryInfo() -> [String: Any] {
        let capacity = ProcessInfo.processInfo.physicalMemory
        var available: UInt64 = 0
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        if result == KERN_SUCCESS {
            var pageSize: vm_size_t = 0
            host_page_size(mach_host_self(), &pageSize)
            available = UInt64(stats.free_count) * UInt64(pageSize)
        }
        return ["capacity": capacity, "availableCapacity": available]
    }

    func storageInfo() -> [[String: Any]] {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
              let capacity = attributes[.systemSize] as? UInt64 else { return [] }
        let name = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Macintosh HD"
        return [["id": "0", "name": name, "type": "fixed", "capacity": capacity]]
    }

    // MARK: power

    func requestKeepAwake(level: String, extensionID: String) {
        releaseKeepAwake(extensionID: extensionID)
        let type = (level == "display"
                    ? kIOPMAssertionTypePreventUserIdleDisplaySleep
                    : kIOPMAssertionTypePreventUserIdleSystemSleep) as CFString
        var assertion: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Tuff extension" as CFString, &assertion
        )
        if result == kIOReturnSuccess { assertions[extensionID] = assertion }
    }

    func releaseKeepAwake(extensionID: String) {
        if let assertion = assertions.removeValue(forKey: extensionID) {
            IOPMAssertionRelease(assertion)
        }
    }

    func hasKeepAwakeAssertion(extensionID: String) -> Bool { assertions[extensionID] != nil }

    func extensionUnloaded(_ extensionID: String) {
        releaseKeepAwake(extensionID: extensionID)
    }

    // MARK: idle

    func queryState(interval: Int) -> String {
        let anyInput = CGEventType(rawValue: UInt32.max)!   // kCGAnyInputEventType
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
        return idle >= Double(interval) ? "idle" : "active"
    }

    func setDetectionInterval(_ interval: Int) {
        idleInterval = max(15, interval)
        if idleTimer != nil { startIdleMonitoring() }
    }

    /// Polls the idle state and pushes `idle.onStateChanged` when it flips. Started when an extension
    /// subscribes to the event (see ExtensionEventPush).
    func startIdleMonitoring() {
        idleTimer?.invalidate()
        lastIdleState = queryState(interval: idleInterval)
        idleTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(idleInterval), repeats: true) { [weak self] _ in
            guard let self else { return }
            let state = self.queryState(interval: self.idleInterval)
            if state != self.lastIdleState {
                self.lastIdleState = state
                ExtensionEventPush.shared.emit("idle.onStateChanged", args: [state])
            }
        }
    }
}