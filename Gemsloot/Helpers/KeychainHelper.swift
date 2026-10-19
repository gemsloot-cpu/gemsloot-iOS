import Foundation
import Security
import CryptoKit

/// Keychain-backed master seed and the three deterministic device-id formats used by Step 2.
///
/// **Master seed:** a UUID v4 string persisted once in the Keychain (`UUID().uuidString`).
///
/// Derived formats (see also `docs/step-1-ff-payload.md`):
/// 1. `keychainUUID` — the seed itself (`xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx`)
/// 2. `deterministicBase36Hash` — `ZB(seed)` / MurmurHash3_x86_32 → base-36 (Branch B `hash` shape)
/// 3. `deterministicHex16` — first 16 lowercase hex chars of SHA-256(seed UTF-8) (Branch A `ANDROID_ID` shape)
enum KeychainHelper {
    private static let service = "com.gemsloot.ios.device"
    private static let masterSeedAccount = "masterSeed"
    /// Legacy Step 1 account — migrated to `masterSeed` on first read.
    private static let legacyUUIDAccount = "deviceUUID"

    struct DeviceIdentifiers: Equatable {
        let keychainUUID: String
        let deterministicBase36Hash: String
        let deterministicHex16: String
    }

    /// Load or create the master seed, then return all three derived formats.
    static func loadIdentifiers() -> DeviceIdentifiers {
        let seed = getOrCreateMasterSeed()
        return derive(from: seed)
    }

    /// Returns the Keychain master seed (UUID v4 string), creating it if needed.
    static func getOrCreateMasterSeed() -> String {
        if let existing = read(account: masterSeedAccount), isUUIDString(existing) {
            return existing
        }
        // Migrate Step 1 key if present.
        if let legacy = read(account: legacyUUIDAccount), isUUIDString(legacy) {
            try? write(account: masterSeedAccount, value: legacy)
            return legacy
        }

        let seed = UUID().uuidString
        do {
            try write(account: masterSeedAccount, value: seed)
        } catch {
            assertionFailure("Keychain write failed: \(error)")
        }
        return seed
    }

    static func derive(from seed: String) -> DeviceIdentifiers {
        DeviceIdentifiers(
            keychainUUID: seed,
            deterministicBase36Hash: MurmurHash3.hashBase36(seed),
            deterministicHex16: sha256Hex16(seed)
        )
    }

    // MARK: - Derivation

    /// SHA-256(seed UTF-8), first 8 bytes as 16 lowercase hex chars (ANDROID_ID-length).
    private static func sha256Hex16(_ seed: String) -> String {
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func isUUIDString(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }

    // MARK: - Keychain I/O

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
