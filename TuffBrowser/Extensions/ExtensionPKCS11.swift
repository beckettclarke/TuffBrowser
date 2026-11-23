import Darwin
import Foundation

/// Firefox `browser.pkcs11`: discovers native PKCS#11 module manifests on macOS, validates
/// extension access, persists installed modules, and queries live slots/tokens through the
/// PKCS#11 v2.40 C ABI (`C_GetFunctionList`).
final class ExtensionPKCS11 {
    static let shared = ExtensionPKCS11()

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    struct Manifest: Equatable {
        let name: String
        let description: String
        let path: String
        let allowedExtensions: [String]
    }

    struct SlotInfo: Equatable {
        struct Token: Equatable {
            let name: String
            let manufacturer: String
            let hwVersion: String
            let fwVersion: String
            let serial: String
            let isLoggedIn: Bool

            var dictionary: [String: Any] {
                [
                    "name": name,
                    "manufacturer": manufacturer,
                    "HWVersion": hwVersion,
                    "FWVersion": fwVersion,
                    "serial": serial,
                    "isLoggedIn": isLoggedIn,
                ]
            }
        }

        let name: String
        let token: Token?

        var dictionary: [String: Any] {
            ["name": name, "token": token?.dictionary ?? NSNull()]
        }
    }

    private struct InstalledRecord: Codable, Equatable {
        let name: String
        let path: String
        let flags: Int
    }

    private let directories: [URL]
    private let stateFile: URL
    private var installed: [String: InstalledRecord] = [:]

    /// Loaded `dlopen` handles so a module stays initialized while installed.
    private var handles: [String: UnsafeMutableRawPointer] = [:]

    /// Optional test hook to override C library loading when testing without compiling a dylib.
    var slotLoaderOverride: ((String) throws -> [SlotInfo])?

    init(
        directories: [URL]? = nil,
        stateFile: URL = Paths.appSupport.appendingPathComponent("pkcs11-modules.json")
    ) {
        if let directories {
            self.directories = directories
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.directories = [
                Paths.appSupport.appendingPathComponent("PKCS11Modules", isDirectory: true),
                home.appendingPathComponent("Library/Application Support/Mozilla/PKCS11Modules", isDirectory: true),
                URL(fileURLWithPath: "/Library/Application Support/Mozilla/PKCS11Modules", isDirectory: true),
            ]
        }
        self.stateFile = stateFile
        if let data = try? Data(contentsOf: stateFile),
           let decoded = try? JSONDecoder().decode([String: InstalledRecord].self, from: data) {
            installed = decoded
        }
    }

    deinit {
        for handle in handles.values { dlclose(handle) }
        handles.removeAll()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(installed) else { return }
        try? data.write(to: stateFile, options: .atomic)
    }

    // MARK: API methods

    func isModuleInstalled(name: String, extensionID: String, manifest: [String: Any]?) throws -> Bool {
        _ = try findManifest(named: name, extensionID: extensionID, extensionManifest: manifest)
        return installed[name] != nil
    }

    func installModule(name: String, flags: Int, extensionID: String, manifest: [String: Any]?) throws {
        let mod = try findManifest(named: name, extensionID: extensionID, extensionManifest: manifest)
        if installed[name] != nil {
            throw Failure("Module '\(name)' is already installed.")
        }
        guard FileManager.default.fileExists(atPath: mod.path) else {
            throw Failure("PKCS#11 library not found at '\(mod.path)'.")
        }
        if slotLoaderOverride == nil {
            let handle = try Self.openModule(at: mod.path)
            handles[name] = handle
        }
        installed[name] = InstalledRecord(name: name, path: mod.path, flags: flags)
        save()
    }

    func uninstallModule(name: String, extensionID: String, manifest: [String: Any]?) throws {
        _ = try findManifest(named: name, extensionID: extensionID, extensionManifest: manifest)
        guard installed.removeValue(forKey: name) != nil else {
            throw Failure("Module '\(name)' is not installed.")
        }
        if let handle = handles.removeValue(forKey: name) {
            Self.closeModule(handle)
        }
        save()
    }

    func getModuleSlots(name: String, extensionID: String, manifest: [String: Any]?) throws -> [[String: Any]] {
        let mod = try findManifest(named: name, extensionID: extensionID, extensionManifest: manifest)
        guard let record = installed[name] else {
            throw Failure("Module '\(name)' is not installed.")
        }
        let path = record.path.isEmpty ? mod.path : record.path
        let slots: [SlotInfo]
        if let override = slotLoaderOverride {
            slots = try override(path)
        } else {
            let handle: UnsafeMutableRawPointer
            if let existing = handles[name] {
                handle = existing
            } else {
                let opened = try Self.openModule(at: path)
                handles[name] = opened
                handle = opened
            }
            slots = try Self.querySlots(handle: handle)
        }
        return slots.map(\.dictionary)
    }

    // MARK: Manifest discovery

    func findManifest(named name: String, extensionID: String, extensionManifest: [String: Any]?) throws -> Manifest {
        guard !name.isEmpty,
              name.range(of: #"^\w+(\.\w+)*$"#, options: .regularExpression) != nil else {
            throw Failure("Invalid PKCS#11 module name '\(name)'.")
        }
        let allowedIDs = Set(ExtensionManagedStorage.candidateIdentifiers(extensionID: extensionID, manifest: extensionManifest))
        for dir in directories {
            let file = dir.appendingPathComponent("\(name).json").standardizedFileURL
            guard file.path.hasPrefix(dir.standardizedFileURL.path + "/"),
                  let data = try? Data(contentsOf: file),
                  let json = (try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed])) as? [String: Any] else {
                continue
            }
            guard (json["type"] as? String) == "pkcs11",
                  (json["name"] as? String) == name,
                  let path = json["path"] as? String, !path.isEmpty,
                  let allowed = json["allowed_extensions"] as? [String] else {
                continue
            }
            guard allowed.contains(where: { allowedIDs.contains($0) }) else {
                throw Failure("Extension is not allowed to access PKCS#11 module '\(name)'.")
            }
            let resolvedPath: String
            if path.hasPrefix("/") {
                resolvedPath = path
            } else {
                resolvedPath = dir.appendingPathComponent(path).standardizedFileURL.path
            }
            return Manifest(
                name: name,
                description: json["description"] as? String ?? "",
                path: resolvedPath,
                allowedExtensions: allowed
            )
        }
        throw Failure("No such PKCS#11 module '\(name)'.")
    }

    // MARK: PKCS#11 v2.40 C ABI

    private typealias CK_RV = UInt
    private typealias CK_ULONG = UInt
    private typealias CK_SLOT_ID = UInt
    private typealias CK_FLAGS = UInt
    private typealias CK_BBOOL = UInt8

    private static let CKR_OK: CK_RV = 0
    private static let CKR_CRYPTOKI_ALREADY_INITIALIZED: CK_RV = 0x0000_0191
    private static let CKF_TOKEN_PRESENT: CK_FLAGS = 0x0000_0001
    private static let CKF_LOGIN_REQUIRED: CK_FLAGS = 0x0000_0004
    private static let CKF_USER_PIN_INITIALIZED: CK_FLAGS = 0x0000_0008

    private typealias FnGetFunctionList = @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> CK_RV
    private typealias FnInitialize = @convention(c) (UnsafeMutableRawPointer?) -> CK_RV
    private typealias FnFinalize = @convention(c) (UnsafeMutableRawPointer?) -> CK_RV
    private typealias FnGetSlotList = @convention(c) (CK_BBOOL, UnsafeMutablePointer<CK_SLOT_ID>?, UnsafeMutablePointer<CK_ULONG>?) -> CK_RV
    private typealias FnGetSlotInfo = @convention(c) (CK_SLOT_ID, UnsafeMutableRawPointer?) -> CK_RV
    private typealias FnGetTokenInfo = @convention(c) (CK_SLOT_ID, UnsafeMutableRawPointer?) -> CK_RV

    /// In `CK_FUNCTION_LIST`: offset 0 is `CK_VERSION` (2 bytes + 6 bytes alignment padding = 8 bytes = 1 pointer slot).
    /// Function pointer indices (in pointer-sized slots, 1-based after `version`):
    /// 1: C_Initialize, 2: C_Finalize, 3: C_GetInfo, 4: C_GetFunctionList,
    /// 5: C_GetSlotList, 6: C_GetSlotInfo, 7: C_GetTokenInfo.
    private static func functionList(from handle: UnsafeMutableRawPointer) throws -> UnsafeMutablePointer<UnsafeMutableRawPointer?> {
        guard let sym = dlsym(handle, "C_GetFunctionList") else {
            throw Failure("Library does not export C_GetFunctionList.")
        }
        let getList = unsafeBitCast(sym, to: FnGetFunctionList.self)
        var rawPtr: UnsafeMutableRawPointer?
        let rv = getList(&rawPtr)
        guard rv == CKR_OK, let ptr = rawPtr else {
            throw Failure("C_GetFunctionList failed (0x\(String(rv, radix: 16))).")
        }
        return ptr.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    }

    private static func openModule(at path: String) throws -> UnsafeMutableRawPointer {
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            let msg = dlerror().map { String(cString: $0) } ?? "dlopen failed"
            throw Failure("Could not load PKCS#11 library: \(msg)")
        }
        do {
            let list = try functionList(from: handle)
            if let initPtr = list[1] {
                let initialize = unsafeBitCast(initPtr, to: FnInitialize.self)
                let rv = initialize(nil)
                if rv != CKR_OK && rv != CKR_CRYPTOKI_ALREADY_INITIALIZED {
                    throw Failure("C_Initialize failed (0x\(String(rv, radix: 16))).")
                }
            }
            return handle
        } catch {
            dlclose(handle)
            throw error
        }
    }

    private static func closeModule(_ handle: UnsafeMutableRawPointer) {
        if let list = try? functionList(from: handle), let finPtr = list[2] {
            let finalize = unsafeBitCast(finPtr, to: FnFinalize.self)
            _ = finalize(nil)
        }
        dlclose(handle)
    }

    private static func querySlots(handle: UnsafeMutableRawPointer) throws -> [SlotInfo] {
        let list = try functionList(from: handle)
        guard let getSlotListPtr = list[5], let getSlotInfoPtr = list[6] else {
            throw Failure("PKCS#11 module is missing C_GetSlotList or C_GetSlotInfo.")
        }
        let getSlotList = unsafeBitCast(getSlotListPtr, to: FnGetSlotList.self)
        let getSlotInfo = unsafeBitCast(getSlotInfoPtr, to: FnGetSlotInfo.self)
        let getTokenInfo = list[7].map { unsafeBitCast($0, to: FnGetTokenInfo.self) }

        var count: CK_ULONG = 0
        var rv = getSlotList(0, nil, &count)
        guard rv == CKR_OK else {
            throw Failure("C_GetSlotList failed (0x\(String(rv, radix: 16))).")
        }
        guard count > 0 else { return [] }

        var ids = [CK_SLOT_ID](repeating: 0, count: Int(count))
        rv = getSlotList(0, &ids, &count)
        guard rv == CKR_OK else {
            throw Failure("C_GetSlotList failed (0x\(String(rv, radix: 16))).")
        }

        var result: [SlotInfo] = []
        for slotID in ids.prefix(Int(count)) {
            let slotBuf = UnsafeMutableRawBufferPointer.allocate(byteCount: 128, alignment: 8)
            slotBuf.initializeMemory(as: UInt8.self, repeating: 0)
            defer { slotBuf.deallocate() }
            guard getSlotInfo(slotID, slotBuf.baseAddress) == CKR_OK else { continue }
            let slotDesc = paddedString(in: slotBuf, offset: 0, length: 64)
            let slotFlags = slotBuf.load(fromByteOffset: 96, as: CK_FLAGS.self)

            var token: SlotInfo.Token?
            if (slotFlags & CKF_TOKEN_PRESENT) != 0, let getTokenInfo {
                let tokBuf = UnsafeMutableRawBufferPointer.allocate(byteCount: 256, alignment: 8)
                tokBuf.initializeMemory(as: UInt8.self, repeating: 0)
                defer { tokBuf.deallocate() }
                if getTokenInfo(slotID, tokBuf.baseAddress) == CKR_OK {
                    let label = paddedString(in: tokBuf, offset: 0, length: 32)
                    let mfr = paddedString(in: tokBuf, offset: 32, length: 32)
                    let serial = paddedString(in: tokBuf, offset: 80, length: 16)
                    let tokFlags = tokBuf.load(fromByteOffset: 96, as: CK_FLAGS.self)
                    let hwMajor = tokBuf[184], hwMinor = tokBuf[185]
                    let fwMajor = tokBuf[186], fwMinor = tokBuf[187]
                    let loginRequired = (tokFlags & CKF_LOGIN_REQUIRED) != 0
                    let pinInitialized = (tokFlags & CKF_USER_PIN_INITIALIZED) != 0
                    token = SlotInfo.Token(
                        name: label,
                        manufacturer: mfr,
                        hwVersion: "\(hwMajor).\(hwMinor)",
                        fwVersion: "\(fwMajor).\(fwMinor)",
                        serial: serial,
                        isLoggedIn: !loginRequired && pinInitialized
                    )
                }
            }
            result.append(SlotInfo(name: slotDesc, token: token))
        }
        return result
    }

    private static func paddedString(in buffer: UnsafeMutableRawBufferPointer, offset: Int, length: Int) -> String {
        let bytes = Array(buffer[offset..<(offset + length)])
        let raw = String(decoding: bytes, as: UTF8.self)
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
    }
}
