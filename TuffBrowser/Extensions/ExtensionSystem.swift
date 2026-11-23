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

    // MARK: system.display

    /// `system.display.getInfo`: the Mac's screens as Chrome's `DisplayUnitInfo`, in Chrome's
    /// coordinates (top-left of the main screen is 0, 0; y grows downwards).
    func displayInfo() -> [[String: Any]] {
        let screens = NSScreen.screens
        let top = screens.first?.frame.maxY ?? 0
        func rect(_ r: NSRect) -> [String: Int] {
            ["left": Int(r.minX), "top": Int(top - r.maxY), "width": Int(r.width), "height": Int(r.height)]
        }
        return screens.enumerated().map { index, screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            let dpi = (screen.deviceDescription[.resolution] as? NSSize)?.width ?? 72 * screen.backingScaleFactor
            return [
                "id": String(number), "name": screen.localizedName, "isPrimary": index == 0,
                "isInternal": CGDisplayIsBuiltin(number) != 0, "isEnabled": true, "isUnified": false,
                "dpiX": dpi, "dpiY": dpi, "rotation": Int(CGDisplayRotation(number)),
                "bounds": rect(screen.frame), "workArea": rect(screen.visibleFrame),
                "overscan": ["left": 0, "top": 0, "right": 0, "bottom": 0],
                "mirroringSourceId": "", "mirroringDestinationIds": [String](),
                "displayZoomFactor": 1, "availableDisplayZoomFactors": [1],
                "hasTouchSupport": false, "hasAccelerometerSupport": false, "modes": [[String: Any]](),
            ]
        }
    }

    struct DisplayRect {
        let id: String
        let left: Int
        let top: Int
        let width: Int
        let height: Int
        var right: Int { left + width }
        var bottom: Int { top + height }
    }

    /// `system.display.getDisplayLayout`: how each secondary display sits next to its parent in
    /// Chrome's `DisplayLayout` format (`id`, `parentId`, `position`, `offset`). Empty for a
    /// single display, as in Chrome.
    func displayLayout() -> [[String: Any]] {
        let screens = NSScreen.screens
        guard screens.count > 1 else { return [] }
        let top = screens.first?.frame.maxY ?? 0
        let rects = screens.map { screen -> DisplayRect in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            let frame = screen.frame
            return DisplayRect(id: String(number), left: Int(frame.minX), top: Int(top - frame.maxY),
                               width: Int(frame.width), height: Int(frame.height))
        }
        return Self.displayLayout(for: rects)
    }

    static func displayLayout(for displays: [DisplayRect]) -> [[String: Any]] {
        guard displays.count > 1 else { return [] }
        var placed: [DisplayRect] = [displays[0]]
        var remaining = Array(displays.dropFirst())
        var layouts: [[String: Any]] = []

        func relation(child: DisplayRect, parent: DisplayRect) -> (distance: Int, position: String, offset: Int) {
            let verticalGap = max(0, max(parent.top - child.bottom, child.top - parent.bottom))
            let horizontalGap = max(0, max(parent.left - child.right, child.left - parent.right))
            let candidates: [(Int, String, Int)] = [
                (abs(child.left - parent.right) + verticalGap, "right", child.top - parent.top),
                (abs(child.right - parent.left) + verticalGap, "left", child.top - parent.top),
                (abs(child.top - parent.bottom) + horizontalGap, "bottom", child.left - parent.left),
                (abs(child.bottom - parent.top) + horizontalGap, "top", child.left - parent.left),
            ]
            return candidates.min { $0.0 < $1.0 }!
        }

        while !remaining.isEmpty {
            var bestIndex = 0
            var bestParent = placed[0]
            var best = relation(child: remaining[0], parent: placed[0])
            for (i, candidate) in remaining.enumerated() {
                for parent in placed {
                    let rel = relation(child: candidate, parent: parent)
                    if rel.distance < best.distance {
                        bestIndex = i
                        bestParent = parent
                        best = rel
                    }
                }
            }
            let next = remaining.remove(at: bestIndex)
            placed.append(next)
            layouts.append([
                "id": next.id,
                "parentId": bestParent.id,
                "position": best.position,
                "offset": best.offset,
            ])
        }
        return layouts
    }

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

    private static let volumeKeys: [URLResourceKey] = [
        .volumeNameKey, .volumeLocalizedNameKey, .volumeUUIDStringKey, .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey,
        .volumeIsBrowsableKey,
    ]
    /// Volume path -> the id it was given, so a volume that's gone can still be named in `onDetached`.
    private var volumeIDs: [String: String] = [:]

    /// The volumes the Finder shows (the startup disk, drives, disk images), as Chrome's
    /// `StorageUnitInfo`. Ids are the volumes' UUIDs, so they stay the same across mounts.
    func storageInfo() -> [[String: Any]] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Self.volumeKeys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap(storageUnit)
    }

    private func storageUnit(_ url: URL) -> [String: Any]? {
        guard let values = try? url.resourceValues(forKeys: Set(Self.volumeKeys)), values.volumeIsBrowsable != false else { return nil }
        let id = values.volumeUUIDString ?? url.path
        volumeIDs[url.path] = id
        let removable = values.volumeIsRemovable == true || values.volumeIsEjectable == true || values.volumeIsInternal == false
        return [
            "id": id, "name": values.volumeLocalizedName ?? values.volumeName ?? url.lastPathComponent,
            "type": url.path == "/" ? "fixed" : removable ? "removable" : "fixed",
            "capacity": values.volumeTotalCapacity ?? 0,
        ]
    }

    private func volume(id: String) -> URL? {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey], options: [.skipHiddenVolumes]) ?? []
        return urls.first { url in
            ((try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString ?? url.path) == id
        }
    }

    /// `system.storage.getAvailableCapacity`.
    func availableCapacity(id: String) throws -> [String: Any] {
        guard let url = volume(id: id) else { throw SystemError("No storage unit with id \(id).") }
        let free = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity ?? 0
        return ["id": id, "availableCapacity": free]
    }

    /// `system.storage.ejectDevice`: Chrome's answers are "success", "in_use", "no_such_device"
    /// and "failure". The startup disk and internal drives can't be ejected.
    func ejectDevice(id: String, finish: @escaping (Any?) -> Void) {
        guard let url = volume(id: id) else { return finish("no_such_device") }
        let values = try? url.resourceValues(forKeys: [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey])
        guard url.path != "/", values?.volumeIsEjectable == true || values?.volumeIsRemovable == true || values?.volumeIsInternal == false else {
            return finish("failure")
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var answer = "success"
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            } catch {
                // EBUSY, or the Carbon "file busy" error (fBsyErr) the Finder's eject reports.
                answer = [Int(EBUSY), -47].contains((error as NSError).code) ? "in_use" : "failure"
            }
            DispatchQueue.main.async { finish(answer) }
        }
    }

    struct SystemError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    // MARK: Events

    private var watchingVolumes = false
    private var watchingDisplays = false

    /// Pushes `system.storage.onAttached` / `onDetached` from here on.
    func startVolumeMonitoring() {
        guard !watchingVolumes else { return }
        watchingVolumes = true
        _ = storageInfo()  // learns the ids of what's mounted now, for onDetached
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
                  let unit = self.storageUnit(url) else { return }
            ExtensionEventPush.shared.emit("system.storage.onAttached", args: [unit])
        }
        center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
                  let id = self.volumeIDs.removeValue(forKey: url.path) else { return }
            ExtensionEventPush.shared.emit("system.storage.onDetached", args: [id])
        }
    }

    /// Pushes `system.display.onDisplayChanged` (no arguments; listeners call getInfo) from here on.
    /// macOS posts the notification for more than display changes, so only a change in what
    /// `getInfo` reports counts.
    func startDisplayMonitoring() {
        guard !watchingDisplays else { return }
        watchingDisplays = true
        let snapshot = { [weak self] in self.flatMap { try? JSONSerialization.data(withJSONObject: $0.displayInfo(), options: .sortedKeys) } }
        var last = snapshot()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            let now = snapshot()
            guard now != last else { return }
            last = now
            ExtensionEventPush.shared.emit("system.display.onDisplayChanged", args: [])
        }
    }

    // MARK: dns (Firefox)

    /// Firefox's `dns.resolve(hostname, flags)`: the host's addresses, and its canonical name when
    /// asked for with "canonical_name". Fails as Firefox does for a name that doesn't resolve.
    func resolve(_ hostname: String, flags: [String], finish: @escaping (Any?) -> Void, fail: @escaping (Error) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var hints = addrinfo()
            hints.ai_socktype = SOCK_STREAM
            hints.ai_family = flags.contains("disable_ipv4") ? AF_INET6 : flags.contains("disable_ipv6") ? AF_INET : AF_UNSPEC
            if flags.contains("canonical_name") { hints.ai_flags |= AI_CANONNAME }
            var list: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(hostname, nil, &hints, &list)
            var addresses: [String] = []
            var canonical: String?
            var entry = list
            while let info = entry?.pointee {
                if canonical == nil, let name = info.ai_canonname { canonical = String(cString: name) }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if let address = info.ai_addr,
                   getnameinfo(address, info.ai_addrlen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let text = String(cString: host)
                    if !addresses.contains(text) { addresses.append(text) }
                }
                entry = info.ai_next
            }
            if let list { freeaddrinfo(list) }
            DispatchQueue.main.async {
                guard status == 0, !addresses.isEmpty else { return fail(SystemError("NS_ERROR_UNKNOWN_HOST")) }
                var record: [String: Any] = ["addresses": addresses, "isTRR": false]
                if flags.contains("canonical_name") { record["canonicalName"] = canonical ?? hostname }
                finish(record)
            }
        }
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