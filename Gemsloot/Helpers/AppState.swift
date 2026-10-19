import Foundation
import AdSupport
import AppTrackingTransparency
import UIKit
import Darwin

/// Process-wide preferences, device identity, locked `ff` snapshot, and bridge telemetry.
final class AppState {
    static let shared = AppState()

    enum DeviceHeaderMode: String, CaseIterable {
        case off
        case ios
        case android
    }

    /// How `POST /_api/ff` bodies are handled by `WebViewBridge`.
    enum FfLockMode: String, CaseIterable {
        /// Mode 1 (default): Branch B schema; lock first body (hash → `deterministicBase36Hash`) and replay.
        case branchB_Locked
        /// Mode 2: Replace with Branch A Capacitor-shaped body (`hash` = `deterministicHex16`).
        case branchA_Capacitor
        /// Mode 3: Do not modify `ff` bodies.
        case passthrough
    }

    struct FfTelemetry: Equatable {
        var url: String
        var bodyJSON: String
        var status: Int?
        var recordedAt: Date
    }

    /// One hop in an offerwall / OAuth / App Store redirect chain (Step 3).
    struct RedirectHop: Equatable, Identifiable {
        let id: UUID
        let timestamp: Date
        let url: String
        /// HTTP status as string, or a type label (`navigation`, `AppStore`, `external`, `idfa-rewrite`).
        let statusCodeOrType: String
        let idfaInjected: Bool

        init(
            id: UUID = UUID(),
            timestamp: Date = Date(),
            url: String,
            statusCodeOrType: String,
            idfaInjected: Bool = false
        ) {
            self.id = id
            self.timestamp = timestamp
            self.url = url
            self.statusCodeOrType = statusCodeOrType
            self.idfaInjected = idfaInjected
        }
    }

    private static let maxRedirectLogs = 50

    private enum DefaultsKey {
        static let deviceHeaderMode = "gemsloot.deviceHeaderMode"
        static let lockFingerprintHash = "gemsloot.lockFingerprintHash"
        static let ffLockMode = "gemsloot.ffLockMode"
        static let lockedFfBodyJSON = "gemsloot.lockedFfBodyJSON"
    }

    private let defaults: UserDefaults
    private let identifiers: KeychainHelper.DeviceIdentifiers

    /// Standard UUID v4 string (Keychain master seed).
    var keychainUUID: String { identifiers.keychainUUID }

    /// Branch B–shaped hash: MurmurHash3→base36 of the master seed.
    var deterministicBase36Hash: String { identifiers.deterministicBase36Hash }

    /// Branch A–shaped id: 16-char lowercase hex derived from the master seed.
    var deterministicHex16: String { identifiers.deterministicHex16 }

    /// Back-compat alias used by Step 1 call sites.
    var deviceUUID: String { keychainUUID }

    private(set) var idfa: UUID?
    private(set) var lastFfTelemetry: FfTelemetry?

    /// Flat redirect / popup hop log (most recent ≤ 50). Used by the future Diagnostic HUD.
    private(set) var redirectLogs: [RedirectHop] = []

    /// Non-zero hardware IDFA string when ATT-authorized; otherwise `nil`.
    var hardwareIDFA: String? {
        guard let idfa else { return nil }
        let value = idfa.uuidString
        if value.lowercased().hasPrefix("00000000") { return nil }
        return value
    }

    /// Exact JSON string for Mode 1 replay (`{hash,data,formated_data}`), if captured.
    var lockedFfBodyJSON: String? {
        get { defaults.string(forKey: DefaultsKey.lockedFfBodyJSON) }
        set {
            if let newValue, !newValue.isEmpty {
                defaults.set(newValue, forKey: DefaultsKey.lockedFfBodyJSON)
            } else {
                defaults.removeObject(forKey: DefaultsKey.lockedFfBodyJSON)
            }
        }
    }

    private var isReconciling = false

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.identifiers = KeychainHelper.loadIdentifiers()
        self.idfa = Self.readIDFAIfAllowed()

        if defaults.string(forKey: DefaultsKey.deviceHeaderMode) == nil {
            defaults.set(DeviceHeaderMode.off.rawValue, forKey: DefaultsKey.deviceHeaderMode)
        }
        if defaults.string(forKey: DefaultsKey.ffLockMode) == nil {
            defaults.set(FfLockMode.branchB_Locked.rawValue, forKey: DefaultsKey.ffLockMode)
        }
        // Default Mode 1 ⇒ lockFingerprintHash true.
        if defaults.object(forKey: DefaultsKey.lockFingerprintHash) == nil {
            defaults.set(true, forKey: DefaultsKey.lockFingerprintHash)
        }
        reconcileLockFingerprintWithMode()
    }

    // MARK: - Preferences

    var deviceHeaderMode: DeviceHeaderMode {
        get {
            let raw = defaults.string(forKey: DefaultsKey.deviceHeaderMode) ?? DeviceHeaderMode.off.rawValue
            return DeviceHeaderMode(rawValue: raw) ?? .off
        }
        set { defaults.set(newValue.rawValue, forKey: DefaultsKey.deviceHeaderMode) }
    }

    var ffLockMode: FfLockMode {
        get {
            let raw = defaults.string(forKey: DefaultsKey.ffLockMode) ?? FfLockMode.branchB_Locked.rawValue
            return FfLockMode(rawValue: raw) ?? .branchB_Locked
        }
        set {
            defaults.set(newValue.rawValue, forKey: DefaultsKey.ffLockMode)
            reconcileLockFingerprintWithMode()
        }
    }

    /// Kept for Step 1 UI/prefs; kept in sync with `ffLockMode` (Mode 1/2 ⇒ true, passthrough ⇒ false).
    var lockFingerprintHash: Bool {
        get { defaults.bool(forKey: DefaultsKey.lockFingerprintHash) }
        set {
            defaults.set(newValue, forKey: DefaultsKey.lockFingerprintHash)
            guard !isReconciling else { return }
            isReconciling = true
            defer { isReconciling = false }
            if newValue {
                if ffLockMode == .passthrough {
                    defaults.set(FfLockMode.branchB_Locked.rawValue, forKey: DefaultsKey.ffLockMode)
                }
            } else if ffLockMode != .passthrough {
                defaults.set(FfLockMode.passthrough.rawValue, forKey: DefaultsKey.ffLockMode)
            }
        }
    }

    private func reconcileLockFingerprintWithMode() {
        isReconciling = true
        defer { isReconciling = false }
        switch ffLockMode {
        case .branchB_Locked, .branchA_Capacitor:
            defaults.set(true, forKey: DefaultsKey.lockFingerprintHash)
        case .passthrough:
            defaults.set(false, forKey: DefaultsKey.lockFingerprintHash)
        }
    }

    // MARK: - Mode 1 snapshot

    /// Persist the exact Mode 1 `ff` JSON body for forever-replay (idempotent if already locked).
    func lockFfBodyIfNeeded(exactJSON: String) {
        guard ffLockMode == .branchB_Locked else { return }
        guard lockedFfBodyJSON == nil else { return }
        lockedFfBodyJSON = exactJSON
    }

    func clearLockedFfBody() {
        lockedFfBodyJSON = nil
    }

    // MARK: - Telemetry (future Diagnostic HUD)

    func recordFfTelemetry(url: String, bodyJSON: String, status: Int?) {
        lastFfTelemetry = FfTelemetry(
            url: url,
            bodyJSON: bodyJSON,
            status: status,
            recordedAt: Date()
        )
    }

    /// Append a redirect hop on the main queue; keeps only the most recent 50.
    func appendRedirectHop(
        url: String,
        statusCodeOrType: String,
        idfaInjected: Bool = false
    ) {
        let hop = RedirectHop(url: url, statusCodeOrType: statusCodeOrType, idfaInjected: idfaInjected)
        let apply = { [weak self] in
            guard let self else { return }
            self.redirectLogs.append(hop)
            if self.redirectLogs.count > Self.maxRedirectLogs {
                self.redirectLogs.removeFirst(self.redirectLogs.count - Self.maxRedirectLogs)
            }
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    func clearRedirectLogs() {
        let clear = { [weak self] in self?.redirectLogs.removeAll() }
        if Thread.isMainThread {
            clear()
        } else {
            DispatchQueue.main.async(execute: clear)
        }
    }

    // MARK: - Branch A payload (Capacitor-shaped)

    /// Body for Mode 2 — see Branch A in `docs/step-1-ff-payload.md`.
    func branchAFfPayload() -> [String: Any] {
        let info = capacitorDeviceInfo()
        let name = info["name"] as? String
        let model = info["model"] as? String ?? "iPhone"
        let osVersion = info["osVersion"] as? String ?? UIDevice.current.systemVersion
        let isVirtual = info["isVirtual"] as? Bool ?? false
        let formated: [String: Any] = [
            "browser": name ?? "",
            "browser_ver": model,
            "os": "\(osVersion) virt=\(isVirtual)",
            "timezone": TimeZone.current.identifier,
            "language": Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
        ]
        return [
            "hash": deterministicHex16,
            "data": info,
            "formated_data": formated,
        ]
    }

    func capacitorDeviceInfo() -> [String: Any] {
        let device = UIDevice.current
        return [
            "memUsed": Self.processMemoryUsed(),
            "model": Self.machineIdentifier(),
            "operatingSystem": "ios",
            "osVersion": device.systemVersion,
            "platform": "ios",
            "manufacturer": "Apple",
            "isVirtual": Self.isVirtualDevice(),
            "name": device.name,
            "webViewVersion": Self.webViewVersionString(),
        ]
    }

    // MARK: - Bridge config

    func bridgeConfig(safeAreaTop: CGFloat) -> WebViewBridge.Config {
        WebViewBridge.Config(
            ffLockMode: ffLockMode.rawValue,
            deviceHeaderMode: deviceHeaderMode.rawValue,
            deterministicBase36Hash: deterministicBase36Hash,
            deterministicHex16: deterministicHex16,
            keychainUUID: keychainUUID,
            lockedFfBodyJSON: lockedFfBodyJSON,
            branchAPayload: branchAFfPayload(),
            safeAreaTop: safeAreaTop
        )
    }

    // MARK: - IDFA

    func refreshIDFA(trackingStatus: ATTrackingManager.AuthorizationStatus? = nil) {
        let status = trackingStatus ?? ATTrackingManager.trackingAuthorizationStatus
        switch status {
        case .authorized:
            idfa = ASIdentifierManager.shared().advertisingIdentifier
        case .notDetermined, .denied, .restricted:
            idfa = nil
        @unknown default:
            idfa = nil
        }
    }

    private static func readIDFAIfAllowed() -> UUID? {
        switch ATTrackingManager.trackingAuthorizationStatus {
        case .authorized:
            return ASIdentifierManager.shared().advertisingIdentifier
        default:
            return nil
        }
    }

    // MARK: - Device helpers

    private static func machineIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    private static func isVirtualDevice() -> Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    private static func processMemoryUsed() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }

    private static func webViewVersionString() -> String {
        // Approximate Safari/WebKit marketing version from the system; good enough for DeviceInfo shape.
        if let version = Bundle(identifier: "com.apple.WebKit")?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        {
            return version
        }
        return UIDevice.current.systemVersion
    }
}
