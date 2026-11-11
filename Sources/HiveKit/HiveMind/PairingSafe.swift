import Foundation
#if canImport(Security)
import Security
#endif

/// Where the pairing lives. The Keychain in the apps, memory in tests.
public protocol PairingStore: Sendable {
    func read() -> HubConfig?
    func write(_ config: HubConfig) throws
    func clear()
}

/// The hub pairing every Hive app shares, so a phone paired once in HiveMind lets HiveBeat's coach ask the hub too.
/// It lives in the same shared Keychain group as the GitHub token (service `com.noahdabney.hive`, group from the
/// app's Info.plist key `HiveKeychainGroup`), under the account `hivemind-pairing`. Without the group (a simulator
/// build without the entitlement) or off Apple platforms there is nothing shared: `load()` returns nil.
public enum PairingSafe {
    /// The shared store for this app, or `nil` when the app has no `HiveKeychainGroup` or there is no Keychain.
    public static func hive(bundle: Bundle = .main) -> (any PairingStore)? {
        #if canImport(Security)
        guard let group = bundle.object(forInfoDictionaryKey: "HiveKeychainGroup") as? String,
              !group.isEmpty, !group.hasPrefix("$(") else { return nil }
        return KeychainPairingStore(service: KeychainPairingStore.service, accessGroup: group)
        #else
        return nil
        #endif
    }

    /// The saved pairing, or nil when there is none (or no shared store).
    public static func load(from store: (any PairingStore)? = PairingSafe.hive()) -> HubConfig? {
        store?.read()
    }

    /// Throws `KeychainError` when the Keychain refuses, or `PairingError.noSharedStore` when there is no store.
    public static func save(_ config: HubConfig, to store: (any PairingStore)? = PairingSafe.hive()) throws {
        guard let store else { throw PairingError.noSharedStore }
        try store.write(config)
    }

    /// Forgets the pairing for every Hive app (it is the one shared item).
    public static func clear(from store: (any PairingStore)? = PairingSafe.hive()) {
        store?.clear()
    }
}

public enum PairingError: Error, Equatable {
    /// No `HiveKeychainGroup` in Info.plist, or no Keychain on this platform.
    case noSharedStore
}

#if canImport(Security)
/// The Keychain item: readable after the first unlock, never synced or restored to another device.
public struct KeychainPairingStore: PairingStore {
    static let service = "com.noahdabney.hive"
    static let account = "hivemind-pairing"
    let service: String
    let accessGroup: String?

    public init(service: String = "com.noahdabney.hive", accessGroup: String?) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private var query: [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: Self.account]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    public func read() -> HubConfig? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(HubConfig.self, from: data)
    }

    public func write(_ config: HubConfig) throws {
        clear()
        var q = query
        q[kSecValueData as String] = try JSONEncoder().encode(config)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        if status != errSecSuccess { throw KeychainError(status: status) }
    }

    public func clear() {
        SecItemDelete(query as CFDictionary)
    }
}
#endif
