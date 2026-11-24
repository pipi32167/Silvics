import XCTest
import AppKit
@testable import Silvics

final class AppearanceSettingsTests: XCTestCase {

    override func tearDown() {
        Theme.apply(AppearanceSettings())
        super.tearDown()
    }

    // MARK: - 默认值与夹取

    func testDefaults() {
        let settings = AppearanceSettings()
        XCTAssertEqual(settings.bodySize, 15)
        XCTAssertEqual(settings.codeSize, 13.5)
        XCTAssertEqual(settings.lineSpacing, 5)
        XCTAssertEqual(settings.fontFamily, .system)
        XCTAssertTrue(settings.isDefault)
    }

    func testClampOnDecode() throws {
        let json = #"{"bodySize":99,"codeSize":2,"lineSpacing":40,"fontFamily":"serif"}"#
        let decoded = try JSONDecoder().decode(AppearanceSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.bodySize, 19)
        XCTAssertEqual(decoded.codeSize, 11)
        XCTAssertEqual(decoded.lineSpacing, 9)
        XCTAssertEqual(decoded.fontFamily, .serif)
    }

    func testMissingFieldsFallBackToDefaults() throws {
        let decoded = try JSONDecoder().decode(AppearanceSettings.self, from: Data(#"{"bodySize":17}"#.utf8))
        XCTAssertEqual(decoded.bodySize, 17)
        XCTAssertEqual(decoded.codeSize, 13.5)
        XCTAssertEqual(decoded.fontFamily, .system)
    }

    func testClampedProperty() {
        var settings = AppearanceSettings()
        settings.bodySize = 100
        XCTAssertEqual(settings.clamped.bodySize, 19)
        XCTAssertEqual(settings.bodySize, 100, "clamped 不应修改原值")
    }

    // MARK: - 持久化

    func testSaveAndLoad() {
        let suite = UserDefaults(suiteName: "silvics.tests.appearance")!
        suite.removePersistentDomain(forName: "silvics.tests.appearance")

        var settings = AppearanceSettings()
        settings.bodySize = 18
        settings.fontFamily = .serif
        settings.save(to: suite)

        let loaded = AppearanceSettings.load(from: suite)
        XCTAssertEqual(loaded, settings)

        AppearanceSettings.clear(from: suite)
        XCTAssertEqual(AppearanceSettings.load(from: suite), AppearanceSettings())
        suite.removePersistentDomain(forName: "silvics.tests.appearance")
    }

    func testLoadFallsBackOnGarbage() {
        let suite = UserDefaults(suiteName: "silvics.tests.appearance.bad")!
        suite.set(Data("not json".utf8), forKey: AppearanceSettings.defaultsKey)
        XCTAssertEqual(AppearanceSettings.load(from: suite), AppearanceSettings())
        suite.removePersistentDomain(forName: "silvics.tests.appearance.bad")
    }

    // MARK: - 标题比例

    func testHeadingSizesScaleWithBody() {
        var settings = AppearanceSettings()
        settings.bodySize = 15
        XCTAssertEqual(settings.headingSize(level: 1), 26)
        XCTAssertEqual(settings.headingSize(level: 6), 15)

        settings.bodySize = 18
        XCTAssertEqual(settings.headingSize(level: 1), 31.2, accuracy: 0.01)
        XCTAssertEqual(settings.headingSize(level: 6), 18, accuracy: 0.01)
    }

    func testHeadingLevelOutOfRangeIsClamped() {
        let settings = AppearanceSettings()
        XCTAssertEqual(settings.headingSize(level: 0), settings.headingSize(level: 1))
        XCTAssertEqual(settings.headingSize(level: 99), settings.headingSize(level: 6))
    }
}

final class ThemeSettingsTests: XCTestCase {

    override func tearDown() {
        Theme.apply(AppearanceSettings())
        super.tearDown()
    }

    func testBodyFontFollowsSettings() {
        var settings = AppearanceSettings()
        settings.bodySize = 18
        settings.lineSpacing = 7
        Theme.apply(settings)

        XCTAssertEqual(Theme.bodyFont.pointSize, 18)
        XCTAssertEqual(Theme.bodyParagraph().lineSpacing, 7)
        XCTAssertEqual(Theme.headingFont(level: 1).pointSize, 31.2, accuracy: 0.01)
    }

    func testCodeFontFollowsSettings() {
        var settings = AppearanceSettings()
        settings.codeSize = 12
        Theme.apply(settings)

        XCTAssertEqual(Theme.codeFont.pointSize, 12)
        XCTAssertTrue(
            Theme.codeFont.fontDescriptor.symbolicTraits.contains(.monoSpace),
            "代码字体必须是等宽"
        )
    }

    func testSerifFamilyChangesFont() {
        let systemName = NSFont.systemFont(ofSize: 15).fontName
        var settings = AppearanceSettings()
        settings.fontFamily = .serif
        Theme.apply(settings)

        XCTAssertNotEqual(Theme.bodyFont.fontName, systemName, "衬线族应换成不同字体")
        XCTAssertEqual(Theme.bodyFont.pointSize, 15)
    }

    func testMonoFamilyIsMonospaced() {
        var settings = AppearanceSettings()
        settings.fontFamily = .mono
        Theme.apply(settings)

        XCTAssertTrue(Theme.bodyFont.fontDescriptor.symbolicTraits.contains(.monoSpace))
    }

    func testBaseAttributesCarryCurrentFont() {
        var settings = AppearanceSettings()
        settings.bodySize = 13
        Theme.apply(settings)

        let font = Theme.baseAttributes()[.font] as? NSFont
        XCTAssertEqual(font?.pointSize, 13)
    }
}
