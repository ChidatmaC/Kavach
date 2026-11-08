import Foundation
import Security

/// App Group storage shared by the app and its extensions: config overrides, display preferences,
/// cached person id, and the caller-label feed for the Call Directory extension.
public struct SharedStore: Sendable {
    public enum Key: String, Sendable {
        case spacetimeURLOverride, agentURLOverride, databaseOverride
        case personId, personName, accessibilityMode, spokenVerdicts, largerText
        case labelsVersion, apnsToken
    }

    public let appGroup: String
    public init(appGroup: String = AppConfig.defaultAppGroup) { self.appGroup = appGroup }

    private var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    public func string(_ k: Key) -> String? { defaults.string(forKey: k.rawValue) }
    public func set(_ v: String?, _ k: Key) { defaults.set(v, forKey: k.rawValue) }
    public func bool(_ k: Key) -> Bool { defaults.bool(forKey: k.rawValue) }
    public func set(_ v: Bool, _ k: Key) { defaults.set(v, forKey: k.rawValue) }
    public func uint64(_ k: Key) -> UInt64 { UInt64(defaults.string(forKey: k.rawValue) ?? "") ?? 0 }
    public func set(_ v: UInt64, _ k: Key) { defaults.set(String(v), forKey: k.rawValue) }
    public func remove(_ k: Key) { defaults.removeObject(forKey: k.rawValue) }

    /// Shared container directory (falls back to Caches when the App Group is unavailable,
    /// e.g. unsigned simulator builds).
    public var containerURL: URL {
        if let u = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) { return u }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    // MARK: Caller labels (Call Directory feed)

    public var labelsFileURL: URL { containerURL.appendingPathComponent("caller_labels.json") }

    public func saveCallerLabels(_ labels: [CallerLabel]) throws {
        let data = try JSONEncoder().encode(labels)
        try data.write(to: labelsFileURL, options: .atomic)
    }

    public func loadCallerLabels() -> [CallerLabel] {
        guard let data = try? Data(contentsOf: labelsFileURL) else { return [] }
        return (try? JSONDecoder().decode([CallerLabel].self, from: data)) ?? []
    }

    // MARK: Token (Keychain, shared with extensions)

    public static let keychainService = "com.hack.kavach.spacetime"
    public static let keychainAccount = "app-token"

    /// Stores the SpacetimeDB token in the Keychain. Tries the shared access group first (so the
    /// extensions can read it), then the app's default group. Unsigned simulator builds have no
    /// keychain entitlement; there we fall back to the App Group defaults (MVP only).
    public func saveToken(_ token: String) {
        let data = Data(token.utf8)
        for group in Self.accessGroups {
            var q = Self.baseQuery(group: group)
            SecItemDelete(q as CFDictionary)
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            if SecItemAdd(q as CFDictionary, nil) == errSecSuccess { defaults.removeObject(forKey: "fallbackToken"); return }
        }
        defaults.set(token, forKey: "fallbackToken")
    }

    public func loadToken() -> String? {
        for group in Self.accessGroups {
            var q = Self.baseQuery(group: group)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
               let s = String(data: d, encoding: .utf8) { return s }
        }
        return defaults.string(forKey: "fallbackToken")
    }

    public func clearToken() {
        for group in Self.accessGroups { SecItemDelete(Self.baseQuery(group: group) as CFDictionary) }
        defaults.removeObject(forKey: "fallbackToken")
        remove(.personId)
    }

    private static var accessGroups: [String?] {
        // $(AppIdentifierPrefix)com.hack.kavach.shared: the prefix is the team id, read from any
        // existing item is not possible up front, so try the bare app group access as well.
        [sharedAccessGroup, nil]
    }

    private static var sharedAccessGroup: String? {
        guard let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String, !prefix.isEmpty
        else { return nil }
        return prefix + "com.hack.kavach.shared"
    }

    private static func baseQuery(group: String?) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        if let group { q[kSecAttrAccessGroup as String] = group }
        return q
    }
}
