import XCTest
@testable import Silvics

final class LineDiffTests: XCTestCase {

    func testNoChange() {
        XCTAssertTrue(LineDiff.changes(old: "a\nb", new: "a\nb").isEmpty)
    }

    func testSingleLineChanged() {
        let changes = LineDiff.changes(
            old: "第一行\n遗忘曲线说明长期留存。\n第三行",
            new: "第一行\n[[遗忘曲线说明长期留存]]。\n第三行"
        )
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].oldLine, "遗忘曲线说明长期留存。")
        XCTAssertEqual(changes[0].newLine, "[[遗忘曲线说明长期留存]]。")
    }

    func testInsertedLine() {
        let changes = LineDiff.changes(old: "一行", new: "一行\n新增一行")
        XCTAssertEqual(changes.count, 1)
        XCTAssertNil(changes[0].oldLine)
        XCTAssertEqual(changes[0].newLine, "新增一行")
    }

    func testDeletedLine() {
        let changes = LineDiff.changes(old: "一行\n旧行", new: "一行")
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].oldLine, "旧行")
        XCTAssertNil(changes[0].newLine)
    }

    func testTwoSeparateChanges() {
        let changes = LineDiff.changes(
            old: "一\n二\n三\n四",
            new: "一\n二改\n三\n四改"
        )
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes[0].oldLine, "二")
        XCTAssertEqual(changes[0].newLine, "二改")
        XCTAssertEqual(changes[1].oldLine, "四")
        XCTAssertEqual(changes[1].newLine, "四改")
    }

    /// 批量转换的真实形态：同一行插两处引用。
    func testTwoReferencesInSameLine() {
        let changes = LineDiff.changes(
            old: "因为遗忘曲线决定长期留存，所以稀疏重复优于集中突击。",
            new: "因为[[遗忘曲线决定长期留存]]，所以[[稀疏重复优于集中突击]]。"
        )
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].newLine, "因为[[遗忘曲线决定长期留存]]，所以[[稀疏重复优于集中突击]]。")
    }
}
