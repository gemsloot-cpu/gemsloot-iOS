import Foundation
import Security

/// Minimal Keychain wrapper for a permanent app-scoped device identifier.
///
/// Capacitor `Device.getId()` formats (Phase 1):
/// - **Android (this APK):** `Settings.Secure.ANDROID_ID` — typically 16-char hex (not GAID).
/// - **Capacitor web fallback:** UUID v4 string in `localStorage["_capuid"]`.
/// - **Capacitor iOS:** `UIDevice.identifierForVendor?.uuidString` — standard UUID string.
///
/// This helper persists a **UUID string** (`UUID().uuidString`) in the Keychain so it survives
/// reinstalls better than `identifierForVendor` alone, matching the common Capacitor UUID shape
/// used as `hash` / push `aid` on native boot paths.
enum KeychainHelper {
    private static let service = "com.gemsloot.ios.device"
    private static let account = "deviceUUID"

    /// Returns the existing Keychain UUID, or creates and stores a new one.
    static func getOrCreateDeviceUUID() -> String {
        if let existing = read(account: account), !existing.isEmpty {
            return existing
        }

        let uuid = UUID().uuidString
        do {
            try write(account: account, value: uuid)
        } catch {
            // Extremely rare; still return a stable-for-session value so callers never crash.
            assertionFailure("Keychain write failed: \(error)")
        }
        return uuid
    }

    // MARK: - Private

    private static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func write(account: String, value: String) throws {
        let data = Data(value.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw KeychainError.unhandledStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unhandledStatus(addStatus)
        }
    }

    enum KeychainError: Error {
        case unhandledStatus(OSStatus)
    }
}
