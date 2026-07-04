import Foundation
import Security

/// Thin wrapper over the iOS Keychain for the small pieces of durable identity the
/// SDK must survive app reinstalls and relaunches without loss (docs/sdk-contract §4:
/// "first-launch 판정: Keychain에 install_id + 플래그 영속").
///
/// Keychain (rather than UserDefaults) is deliberate:
///   - `install_id` and the first-launch flag must persist across app *deletes* on the
///     same device so a delete→reinstall is detectable as a `reinstall` rather than a
///     brand-new install (Keychain items outlive app deletion; UserDefaults do not).
///   - `kSecAttrAccessibleAfterFirstUnlockThisDeviceThisDeviceOnly` keeps items usable
///     after first unlock (so background launches work) but never syncs to iCloud and
///     never migrates to another device.
///
/// All operations are best-effort and never throw to the host app.
final class KeychainStore {

    private let service: String

    /// - Parameter service: keychain service namespace. Scoped per SDK key so two
    ///   tenants embedded in one app do not collide.
    init(service: String) {
        self.service = service
    }

    // MARK: - String values

    func string(forKey key: String) -> String? {
        guard let data = data(forKey: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func set(_ value: String, forKey key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return set(data, forKey: key)
    }

    // MARK: - Data values

    func data(forKey key: String) -> Data? {
        var query = baseQuery(forKey: key)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    func set(_ data: Data, forKey key: String) -> Bool {
        // Try update first; if the item does not exist, add it.
        let matchQuery = baseQuery(forKey: key)
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(matchQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery(forKey: key)
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            return addStatus == errSecSuccess
        }
        return false
    }

    // MARK: - Bool flags

    func bool(forKey key: String) -> Bool {
        string(forKey: key) == "1"
    }

    @discardableResult
    func setTrue(forKey key: String) -> Bool {
        set("1", forKey: key)
    }

    // MARK: - Removal

    @discardableResult
    func remove(forKey key: String) -> Bool {
        let status = SecItemDelete(baseQuery(forKey: key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Private

    private func baseQuery(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            // Never sync to iCloud Keychain; keep device-local for privacy.
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }
}
