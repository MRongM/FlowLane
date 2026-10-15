import XCTest
@testable import AppProxyKit

final class RuntimeLocalizationTests: XCTestCase {
    func testLegacyStatusDecodesWithoutMessageMetadata() throws {
        let data = Data(#"{"phase":"failed","message":"legacy diagnostic","logs":[],"restoration":"legacy restore"}"#.utf8)
        let status = try JSONDecoder().decode(SessionStatus.self, from: data)
        XCTAssertNil(status.messageContent); XCTAssertNil(status.restorationContent)
        XCTAssertEqual(status.message, "legacy diagnostic"); XCTAssertEqual(status.restoration, "legacy restore")
    }
    func testStructuredStatusCanRerenderAfterRoundTrip() throws {
        let content = LocalizedMessage("helper.core.exited", arguments: ["17"])
        let restoration = LocalizedMessage("snapshot.unchanged")
        let status = SessionStatus(phase: .failed, content: content, restorationContent: restoration)
        let decoded = try JSONDecoder().decode(SessionStatus.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(decoded.messageContent, content); XCTAssertEqual(decoded.restorationContent, restoration)
        XCTAssertEqual(decoded.message, content.rendered(in: .en))
        XCTAssertNotEqual(content.rendered(in: .en), content.rendered(in: .zhHans))
        XCTAssertTrue(content.rendered(in: .en).contains("17")); XCTAssertTrue(content.rendered(in: .zhHans).contains("17"))
    }
    func testErrorsRetainMetadataAndRawFixtureCompatibility() throws {
        let error = AppProxyError(localized: "error.proxy.name")
        XCTAssertEqual(LocalizedMessage.from(error), error.content)
        XCTAssertEqual(error.message, error.content.rendered(in: .en))
        XCTAssertNotEqual(error.content.rendered(in: .en), error.content.rendered(in: .zhHans))
        let raw = AppProxyError("fixture raw diagnostic %@ {0}")
        XCTAssertEqual(raw.message, "fixture raw diagnostic %@ {0}")
        XCTAssertEqual(LocalizedMessage.from(raw).rendered(in: .ar), raw.message)
        let system = NSError(domain: "fixture", code: 5, userInfo: [NSLocalizedDescriptionKey: "system detail"])
        XCTAssertEqual(LocalizedMessage.from(system).rendered(in: .ja), "system detail")
        let interface = LocalizedMessage("apps.unassigned", table: .interface)
        XCTAssertEqual(AppProxyError(content: interface).content, interface)
    }
    func testRuntimeStateRetainsContentForLanguageChanges() throws {
        var state = RuntimeStateMachine()
        try state.apply(.start)
        XCTAssertEqual(state.message, state.content.rendered(in: .en))
        XCTAssertNotEqual(state.content.rendered(in: .en), state.content.rendered(in: .zhHans))
        let failure = LocalizedMessage("helper.core.exited", arguments: ["3"])
        try state.apply(.failureMessage(failure))
        XCTAssertEqual(state.content, failure); XCTAssertEqual(state.phase, .failed)
        try state.apply(.failure("legacy raw")); XCTAssertEqual(state.message, "legacy raw")
    }
    func testSnapshotIdentityAndComparisonAreLanguageIndependent() {
        let before = NetworkSnapshot(values: ["routes.ipv4": "route-a", "routes.ipv6": "route", "dns": "dns", "system.proxy": "direct"])
        let after = NetworkSnapshot(values: ["routes.ipv4": "route-b", "routes.ipv6": "route", "dns": "<unavailable>", "system.proxy": "direct"])
        let message = before.comparisonContent(to: after)
        XCTAssertEqual(before.comparison(to: after), message.rendered(in: .en))
        XCTAssertTrue(message.rendered(in: .en).contains("IPv4")); XCTAssertTrue(message.rendered(in: .zhHans).contains("IPv4"))
        XCTAssertNotEqual(message.rendered(in: .en), message.rendered(in: .zhHans))
        XCTAssertFalse(before.matches(after))
        XCTAssertEqual(Set(before.values.keys), Set(["routes.ipv4", "routes.ipv6", "dns", "system.proxy"]))
    }
    func testAllRuntimeCatalogsHaveMatchingKeysAndPlaceholders() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AppProxyKit/Resources")
        func catalog(_ name: String) throws -> [String: String] {
            let data = try Data(contentsOf: root.appendingPathComponent(name + ".lproj/Runtime.strings"))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        }
        let english = try catalog("en")
        XCTAssertGreaterThan(english.count, 70)
        let pattern = try NSRegularExpression(pattern: #"\{\d+\}"#)
        func placeholders(_ value: String) -> Set<String> {
            Set(pattern.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap { Range($0.range, in: value).map { String(value[$0]) } })
        }
        for language in ["zh-Hans", "zh-Hant", "ja", "ko", "fr", "de", "es", "pt-BR", "ru", "ar"] {
            let translated = try catalog(language)
            XCTAssertEqual(Set(translated.keys), Set(english.keys), language)
            for (key, value) in english {
                XCTAssertEqual(placeholders(translated[key] ?? ""), placeholders(value), language + ": " + key)
            }
        }
    }
    func testStartupRequestSchemaDoesNotIncludeLanguageOrMessageMetadata() throws {
        let request = SessionRequest(configuration: AppConfiguration(), passwords: [:], parentPID: 7, ownerUID: 501, token: "fixture")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["configuration", "passwords", "parentPID", "ownerUID", "token"]))
    }

}
