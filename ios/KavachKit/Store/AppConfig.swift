import Foundation

/// Backend and branding configuration. Values come from the xcconfig via each target's Info.plist
/// (see Config/Kavach.xcconfig); the Settings screen can override the backend URLs at runtime
/// (stored in the App Group) so a real iPhone can point at the Mac's LAN IP without a rebuild.
public struct AppConfig: Sendable, Equatable {
    public var displayName: String
    public var spacetimeURL: URL
    public var databaseName: String
    public var agentURL: URL
    public var hotlineNumber: String
    public var appGroup: String

    public static let defaultAppGroup = "group.com.hack.kavach.app"

    public init(displayName: String, spacetimeURL: URL, databaseName: String, agentURL: URL,
                hotlineNumber: String = "", appGroup: String = AppConfig.defaultAppGroup) {
        self.displayName = displayName
        self.spacetimeURL = spacetimeURL
        self.databaseName = databaseName
        self.agentURL = agentURL
        self.hotlineNumber = hotlineNumber
        self.appGroup = appGroup
    }

    /// Info.plist values with App Group overrides applied.
    public static var current: AppConfig {
        var c = fromInfoPlist(Bundle.main.infoDictionary ?? [:])
        let store = SharedStore(appGroup: c.appGroup)
        if let s = store.string(.spacetimeURLOverride), let u = URL(string: s), !s.isEmpty { c.spacetimeURL = u }
        if let s = store.string(.agentURLOverride), let u = URL(string: s), !s.isEmpty { c.agentURL = u }
        if let s = store.string(.databaseOverride), !s.isEmpty { c.databaseName = s }
        return c
    }

    public static func fromInfoPlist(_ info: [String: Any]) -> AppConfig {
        func str(_ k: String) -> String {
            let v = (info[k] as? String ?? "").trimmingCharacters(in: .whitespaces)
            return v.hasPrefix("$(") ? "" : v
        }
        let name = str("KavachAppDisplayName").isEmpty ? (str("CFBundleDisplayName").isEmpty ? "Kavach" : str("CFBundleDisplayName")) : str("KavachAppDisplayName")
        return AppConfig(
            displayName: name,
            spacetimeURL: URL(string: str("KavachSpacetimeURL")) ?? URL(string: "http://127.0.0.1:3000")!,
            databaseName: str("KavachSpacetimeDB").isEmpty ? "kavach" : str("KavachSpacetimeDB"),
            agentURL: URL(string: str("KavachAgentURL")) ?? URL(string: "http://127.0.0.1:8088")!,
            hotlineNumber: str("KavachHotlineNumber"),
            appGroup: str("KavachAppGroup").isEmpty ? defaultAppGroup : str("KavachAppGroup")
        )
    }
}
