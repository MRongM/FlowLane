import Foundation

public enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case en, zhHans = "zh-Hans", zhHant = "zh-Hant", ja, ko, fr, de, es, ptBR = "pt-BR", ru, ar
    public var id: String { rawValue }
    public var locale: Locale { Locale(identifier: rawValue) }
    public var isRightToLeft: Bool { self == .ar }
    public var nativeName: String {
        switch self {
        case .en: return "English"
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .fr: return "Français"
        case .de: return "Deutsch"
        case .es: return "Español"
        case .ptBR: return "Português (Brasil)"
        case .ru: return "Русский"
        case .ar: return "العربية"
        }
    }
    public static func resolve(preferredLanguages: [String]) -> Self {
        for identifier in preferredLanguages {
            let parts = identifier.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").map(String.init)
            guard let base = parts.first else { continue }
            if base == "zh" {
                if parts.contains("hant") { return .zhHant }
                if parts.contains("hans") { return .zhHans }
                return parts.contains(where: { ["tw", "hk", "mo"].contains($0) }) ? .zhHant : .zhHans
            }
            if base == "pt" { return .ptBR }
            if let matched = allCases.first(where: { $0.rawValue.lowercased() == base }) { return matched }
        }
        return .en
    }
}

public enum LocalizationTable: String, Codable, CaseIterable, Sendable {
    case interface = "Interface", runtime = "Runtime"
}

/// Language-neutral messages cross process boundaries; values are never localization keys.
public struct LocalizedMessage: Codable, Equatable, Sendable {
    public let key: String?
    public let arguments: [LocalizedMessage]
    public let table: LocalizationTable
    private let literal: String?
    public init(_ key: String, arguments: [String] = [], table: LocalizationTable = .runtime) {
        self.key = key; self.arguments = arguments.map(Self.verbatim); self.table = table; literal = nil
    }
    public init(_ key: String, values: [LocalizedMessage], table: LocalizationTable = .runtime) {
        self.key = key; arguments = values; self.table = table; literal = nil
    }
    private init(literal: String) { key = nil; arguments = []; table = .runtime; self.literal = literal }
    public static func verbatim(_ text: String) -> Self { Self(literal: text) }
    public static func from(_ error: Error) -> Self {
        if let error = error as? AppProxyError { return error.content }
        return .verbatim(error.localizedDescription)
    }
    public func rendered(in language: AppLanguage) -> String {
        guard let key else { return literal ?? "" }
        return Localization.text(key, language: language, table: table, arguments: arguments.map { $0.rendered(in: language) })
    }
}

public enum Localization {
    /// Packaged apps resolve their own resources before SwiftPM's development fallback.
    public static let resourceBundle: Bundle = {
        let name = "AppProxy_AppProxyKit.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/" + name),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/" + name)
        ].compactMap { $0 }
        for url in candidates { if let bundle = Bundle(url: url) { return bundle } }
        return Bundle.module
    }()
    private static let catalogs: [AppLanguage: [LocalizationTable: [String: String]]] = {
        var result: [AppLanguage: [LocalizationTable: [String: String]]] = [:]
        let roots = [resourceBundle.resourceURL, resourceBundle.bundleURL].compactMap { $0 }
        let directories = roots.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
        for language in AppLanguage.allCases {
            var tables: [LocalizationTable: [String: String]] = [:]
            for table in LocalizationTable.allCases {
                // SwiftPM canonicalizes locale folder names to lowercase. Do not ask Bundle
                // for a localized lookup here: that may silently resolve a different language.
                guard let folder = directories.first(where: { $0.lastPathComponent.lowercased() == language.rawValue.lowercased() + ".lproj" }),
                      let data = try? Data(contentsOf: folder.appendingPathComponent(table.rawValue + ".strings")),
                      let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: String] else { continue }
                tables[table] = value
            }
            result[language] = tables
        }
        return result
    }()
    public static func catalog(language: AppLanguage, table: LocalizationTable) -> [String: String] { catalogs[language]?[table] ?? [:] }
    public static func text(_ key: String, language: AppLanguage, table: LocalizationTable = .interface, arguments: [String] = []) -> String {
        let template = catalog(language: language, table: table)[key] ?? catalog(language: .en, table: table)[key] ?? key
        return interpolate(template, arguments: arguments)
    }
    /// Walk the original template once, so inserted user data is never parsed as a template.
    public static func interpolate(_ template: String, arguments: [String]) -> String {
        let expression = try! NSRegularExpression(pattern: "\\{([0-9]+)\\}")
        let source = template as NSString
        var result = ""; var end = 0
        for match in expression.matches(in: template, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: end, length: match.range.location - end))
            if let index = Int(source.substring(with: match.range(at: 1))), arguments.indices.contains(index) { result += arguments[index] }
            else { result += source.substring(with: match.range) }
            end = NSMaxRange(match.range)
        }
        result += source.substring(from: end)
        return result
    }
}
