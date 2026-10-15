import XCTest
@testable import AppProxyKit

final class LocalizationCatalogTests: XCTestCase {
    func testAllElevenInterfaceCatalogsHaveIdenticalKeysAndPlaceholders() throws {
        XCTAssertEqual(AppLanguage.allCases.count, 11)
        for table in LocalizationTable.allCases {
            let english = Localization.catalog(language: .en, table: table)
            XCTAssertFalse(english.isEmpty, "Empty base table: \(table)")
            for language in AppLanguage.allCases {
                let translated = Localization.catalog(language: language, table: table)
                XCTAssertEqual(Set(translated.keys), Set(english.keys), "\(language.rawValue)/\(table.rawValue)")
                for (key, base) in english {
                    let value = try XCTUnwrap(translated[key], "\(language.rawValue): \(key)")
                    XCTAssertFalse(value.isEmpty)
                    XCTAssertEqual(placeholders(base), placeholders(value), "\(language.rawValue): \(key)")
                }
            }
        }
    }
    private func placeholders(_ text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "\\{[0-9]+\\}")
        let source = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: source.length)).map { source.substring(with: $0.range) }.sorted()
    }
}
