import XCTest
@testable import AppProxyKit

final class LocalizationTests: XCTestCase {
    func testPreferredLanguageMatchingAndFallback() {
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["zh-TW"]), .zhHant)
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["zh-Hant-HK"]), .zhHant)
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["zh-CN"]), .zhHans)
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["en-GB"]), .en)
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["fr-CA"]), .fr)
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["pt-PT"]), .ptBR)
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["xx-ZZ", "ko-KR"]), .ko)
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: ["xx-ZZ"]), .en)
        XCTAssertEqual(AppLanguage.resolve(preferredLanguages: []), .en)
        XCTAssertTrue(AppLanguage.ar.isRightToLeft)
        XCTAssertFalse(AppLanguage.en.isRightToLeft)
    }
    func testPreferencePersistsAndAppOverrideDoesNotChangeGlobalLanguage() {
        let suite = "FlowLane.language.test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let before = defaults.persistentDomain(forName: UserDefaults.globalDomain)
        let store = LanguagePreferences(defaults: defaults)
        XCTAssertEqual(store.preference, .system)
        store.save(.language(.ja))
        XCTAssertEqual(LanguagePreferences(defaults: defaults).preference, .language(.ja))
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["ja"])
        store.save(.system)
        XCTAssertNil(defaults.persistentDomain(forName: suite)?["AppleLanguages"])
        XCTAssertEqual(defaults.persistentDomain(forName: UserDefaults.globalDomain) as NSDictionary?, before as NSDictionary?)
    }
    func testInvalidStoredLanguageReturnsToSystem() {
        let suite = "FlowLane.language.test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("invalid-language", forKey: LanguagePreferences.preferenceKey)
        XCTAssertEqual(LanguagePreferences(defaults: defaults).preference, .system)
    }
    func testSafeInterpolationDoesNotReinterpretUserTextOrPercentSigns() {
        XCTAssertEqual(Localization.interpolate("{1} / {0}", arguments: ["{1}%@/用户", "代理"]), "代理 / {1}%@/用户")
        XCTAssertEqual(Localization.text("apps.main_process", language: .en, arguments: ["/Applications/示例.app"]), "Main process: /Applications/示例.app")
        XCTAssertEqual(Localization.text("apps.main_process", language: .zhHans, arguments: ["/Applications/Example.app"]), "主进程：/Applications/Example.app")
    }
    func testMissingTranslationFallsBackToEnglishAndMissingKeyStaysInspectable() {
        XCTAssertEqual(Localization.text("missing.key", language: .en), "missing.key")
        XCTAssertEqual(Localization.text("settings.system", language: .en), "Follow system")
        XCTAssertEqual(LocalizedMessage.verbatim("untranslated third-party detail").rendered(in: .zhHans), "untranslated third-party detail")
    }
    func testMessageRoundTripRetainsArgumentsAndCanChangeLanguage() throws {
        let message = LocalizedMessage("apps.main_process", arguments: ["/Applications/示例.app"], table: .interface)
        let decoded = try JSONDecoder().decode(LocalizedMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(message, decoded)
        XCTAssertTrue(decoded.rendered(in: .en).hasPrefix("Main process:"))
        XCTAssertTrue(decoded.rendered(in: .zhHans).hasPrefix("主进程："))
    }
}
