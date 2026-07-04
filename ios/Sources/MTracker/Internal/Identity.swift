import Foundation

/// Owns the durable device/install identity and first-launch determination
/// (docs/sdk-contract §4).
///
/// - `installId` is a ULID generated exactly once, on the very first launch after
///   install, and persisted in the Keychain. It is the join key for retention,
///   sessions, and every event (`install_id` field in the batch body).
/// - First launch of a fresh install => emit `install`.
/// - First launch after a delete→reinstall (Keychain survived the delete) => emit
///   `reinstall` with a *new* install_id, so cohorts distinguish re-acquisition
///   (docs/attribution.md §6: 재설치/리인게이지먼트 구분).
///
/// The `LaunchState` returned by `resolve()` tells the caller which lifecycle event,
/// if any, to enqueue.
final class Identity {

    enum LaunchState {
        case firstLaunch     // brand-new install; emit `install`
        case reinstall       // Keychain identity existed but app storage was wiped; emit `reinstall`
        case returning       // normal subsequent launch; emit nothing
    }

    private enum Key {
        static let installId = "mt_install_id"
        static let installedFlag = "mt_installed"        // set once we've recorded an install
        static let matchTokenRead = "mt_match_token_read" // one-shot clipboard guard
    }

    private let keychain: KeychainStore
    private let defaults: UserDefaults

    private(set) var installId: String = ""

    init(keychain: KeychainStore, defaults: UserDefaults = .standard) {
        self.keychain = keychain
        self.defaults = defaults
    }

    /// Resolves (and, if needed, creates + persists) the install identity, returning
    /// the launch state for the caller to translate into a lifecycle event.
    func resolve() -> LaunchState {
        let keychainInstallId = keychain.string(forKey: Key.installId)
        let keychainInstalled = keychain.bool(forKey: Key.installedFlag)

        // `UserDefaults` is wiped on app delete, the Keychain is not. Comparing the two
        // lets us tell a first install (neither present) from a reinstall (Keychain
        // present, defaults gone).
        let defaultsInstalled = defaults.bool(forKey: Key.installedFlag)

        if let existing = keychainInstallId, keychainInstalled {
            if defaultsInstalled {
                // Everything intact — a normal returning launch.
                installId = existing
                return .returning
            }
            // Keychain identity survived a delete but local storage was wiped:
            // treat as a reinstall and mint a fresh install_id for the new lifecycle.
            let newId = ULID.generate()
            installId = newId
            keychain.set(newId, forKey: Key.installId)
            keychain.setTrue(forKey: Key.installedFlag)
            defaults.set(true, forKey: Key.installedFlag)
            return .reinstall
        }

        // Brand-new install: mint and persist a fresh install_id.
        let newId = ULID.generate()
        installId = newId
        keychain.set(newId, forKey: Key.installId)
        keychain.setTrue(forKey: Key.installedFlag)
        defaults.set(true, forKey: Key.installedFlag)
        return .firstLaunch
    }

    // MARK: - One-shot clipboard guard

    /// True once the clipboard `match_token` read has been attempted this install, so
    /// relaunches never re-trigger the iOS paste banner (docs/attribution.md §2.2).
    var didReadMatchToken: Bool {
        keychain.bool(forKey: Key.matchTokenRead)
    }

    func markMatchTokenRead() {
        keychain.setTrue(forKey: Key.matchTokenRead)
    }
}
