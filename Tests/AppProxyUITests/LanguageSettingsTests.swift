import XCTest
import AppProxyKit
@testable import AppProxy

final class LanguageSettingsTests: XCTestCase {
    @MainActor func testSystemFollowingManualChoiceAndPersistence() async throws {
        let suite = "FlowLane.settings.test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var system = ["zh-TW"]
        let settings = LanguageSettings(defaults: defaults, systemLanguages: { system })
        XCTAssertEqual(settings.preference, .system)
        XCTAssertEqual(settings.language, .zhHant)
        settings.select(.language(.ar))
        XCTAssertEqual(settings.direction, .rightToLeft)
        XCTAssertEqual(LanguageSettings(defaults: defaults, systemLanguages: { system }).language, .ar)
        system = ["de-DE"]; settings.refreshSystemLanguage()
        XCTAssertEqual(settings.language, .ar)
        settings.select(.system)
        XCTAssertEqual(settings.language, .de)
        XCTAssertEqual(settings.direction, .leftToRight)
        system = ["ko-KR"]; settings.refreshSystemLanguage()
        XCTAssertEqual(settings.language, .ko)
    }
    @MainActor func testLanguageSwitchPreservesConfigurationAndRuntimeIdentity() async throws {
        let suite = "FlowLane.settings.test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let settings = LanguageSettings(defaults: defaults, systemLanguages: { ["en"] })
        let store = AppStore(directory: directory)
        store.addApplications([URL(fileURLWithPath: "/System/Applications/TextEdit.app")])
        let configuration = try Data(contentsOf: store.persistence.fileURL)
        let runtime = RuntimeController()
        let identity = ObjectIdentifier(runtime)
        for language in AppLanguage.allCases {
            settings.select(.language(language))
            XCTAssertEqual(ObjectIdentifier(runtime), identity)
            XCTAssertEqual(runtime.state.phase, .stopped)
            XCTAssertEqual(try Data(contentsOf: store.persistence.fileURL), configuration)
            XCTAssertNotEqual(settings.text("settings.language"), "settings.language")
        }
    }
}
