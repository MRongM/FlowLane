import AppKit
import AppProxyKit
import SwiftUI

@MainActor
final class LanguageSettings: ObservableObject {
    @Published private(set) var preference: LanguagePreference
    @Published private var currentSystemLanguages: [String]
    private let preferences: LanguagePreferences
    private let preferredLanguages: () -> [String]
    private var observers: [NSObjectProtocol] = []
    var language: AppLanguage { preference.resolved(systemLanguages: currentSystemLanguages) }
    var locale: Locale { language.locale }
    var direction: LayoutDirection { language.isRightToLeft ? .rightToLeft : .leftToRight }
    init(defaults: UserDefaults = .standard, systemLanguages: @escaping () -> [String] = LanguagePreferences.systemLanguages) {
        preferences = LanguagePreferences(defaults: defaults)
        preference = preferences.preference
        preferredLanguages = systemLanguages; currentSystemLanguages = systemLanguages()
        // App-local AppleLanguages is solely for native menus on the next launch.
        preferences.save(preference)
        for name in [NSLocale.currentLocaleDidChangeNotification, NSApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshSystemLanguage() }
            })
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    func select(_ preference: LanguagePreference) {
        preferences.save(preference)
        self.preference = preference
        refreshSystemLanguage()
    }
    func refreshSystemLanguage() {
        let current = preferredLanguages()
        if current != currentSystemLanguages { currentSystemLanguages = current }
    }
    func text(_ key: String, arguments: [String] = []) -> String {
        Localization.text(key, language: language, arguments: arguments)
    }
    func render(_ message: LocalizedMessage) -> String { message.rendered(in: language) }
}

struct LanguageSettingsView: View {
    @EnvironmentObject private var settings: LanguageSettings
    var body: some View {
        Form {
            Section {
                Picker(settings.text("settings.language"), selection: Binding(get: { settings.preference }, set: settings.select)) {
                    Text(settings.text("settings.system")).tag(LanguagePreference.system)
                    Divider()
                    ForEach(AppLanguage.allCases) { language in
                        Text(verbatim: language.nativeName).tag(LanguagePreference.language(language))
                    }
                }.accessibilityIdentifier("interface-language")
                Text(settings.text("settings.resolved", arguments: [settings.language.nativeName])).foregroundStyle(.secondary)
            } header: { Text(settings.text("settings.appearance")) }
            Section {
                Text(settings.text("settings.instant"))
                Text(settings.text("settings.native_restart")).foregroundStyle(.secondary)
                Text(settings.text("settings.fallback")).foregroundStyle(.secondary)
            } header: { Text(settings.text("settings.languages")) }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, idealWidth: 620)
        .padding(12)
    }
}
