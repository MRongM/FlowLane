import Foundation

public enum LanguagePreference: Hashable, Sendable {
    case system
    case language(AppLanguage)
    public var rawValue: String {
        switch self { case .system: return "system"; case .language(let value): return value.rawValue }
    }
    public init(rawValue: String) {
        self = AppLanguage(rawValue: rawValue).map(Self.language) ?? .system
    }
    public func resolved(systemLanguages: [String]) -> AppLanguage {
        switch self { case .system: return AppLanguage.resolve(preferredLanguages: systemLanguages); case .language(let value): return value }
    }
}

public struct LanguagePreferences {
    public static let preferenceKey = "interfaceLanguage"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var preference: LanguagePreference { LanguagePreference(rawValue: defaults.string(forKey: Self.preferenceKey) ?? "system") }
    public func save(_ preference: LanguagePreference) {
        defaults.set(preference.rawValue, forKey: Self.preferenceKey)
        switch preference {
        case .system: defaults.removeObject(forKey: "AppleLanguages")
        case .language(let language): defaults.set([language.rawValue], forKey: "AppleLanguages")
        }
    }
    public static func systemLanguages() -> [String] {
        // Read the global domain explicitly: app-local AppleLanguages must not feed back into system mode.
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
        return global?.isEmpty == false ? global! : ["en"]
    }
}
