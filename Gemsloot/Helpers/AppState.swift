import Foundation
import AdSupport
import AppTrackingTransparency

/// Process-wide app preferences and device identity for later WebView / `ff` wiring.
final class AppState {
    static let shared = AppState()

    enum DeviceHeaderMode: String, CaseIterable {
        /// No custom `Device` header on API requests.
        case off
        /// Send `Device: ios`.
        case ios
        /// Send `Device: android` (Android APK parity).
        case android
    }

    private enum DefaultsKey {
        static let deviceHeaderMode = "gemsloot.deviceHeaderMode"
        static let lockFingerprintHash = "gemsloot.lockFingerprintHash"
    }

    private let defaults: UserDefaults

    /// Permanent device id (Keychain). Capacitor-style UUID string — see `KeychainHelper`.
    let deviceUUID: String

    /// Advertising identifier from `ASIdentifierManager`, or `nil` when tracking is denied / unavailable.
    private(set) var idfa: UUID?

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.deviceUUID = KeychainHelper.getOrCreateDeviceUUID()
        self.idfa = Self.readIDFAIfAllowed()

        // Defaults: lock fingerprint hash on; header mode off until product chooses ios/android.
        if defaults.object(forKey: DefaultsKey.lockFingerprintHash) == nil {
            defaults.set(true, forKey: DefaultsKey.lockFingerprintHash)
        }
        if defaults.string(forKey: DefaultsKey.deviceHeaderMode) == nil {
            defaults.set(DeviceHeaderMode.off.rawValue, forKey: DefaultsKey.deviceHeaderMode)
        }
    }

    // MARK: - Preferences (UserDefaults)

    var deviceHeaderMode: DeviceHeaderMode {
        get {
            let raw = defaults.string(forKey: DefaultsKey.deviceHeaderMode) ?? DeviceHeaderMode.off.rawValue
            return DeviceHeaderMode(rawValue: raw) ?? .off
        }
        set {
            defaults.set(newValue.rawValue, forKey: DefaultsKey.deviceHeaderMode)
        }
    }

    /// When `true` (default), prefer a stable device hash over a fresh browser fingerprint each launch.
    var lockFingerprintHash: Bool {
        get { defaults.bool(forKey: DefaultsKey.lockFingerprintHash) }
        set { defaults.set(newValue, forKey: DefaultsKey.lockFingerprintHash) }
    }

    // MARK: - IDFA

    /// Refresh IDFA after an ATT prompt (or when returning to the app).
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
}
