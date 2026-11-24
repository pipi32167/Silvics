import XCTest
@testable import Silvics

final class LineMergeTests: XCTestCase {

    func testIdenticalSidesPassThrough() {
        let r = LineMerge.merge(base: "a\nb", ours: "a\nb", theirs: "a\nb")
        XCTAssertEqual(r?.text, "a\nb")
        XCTAssertEqual(r?.conflictCount, 0)
    }

    func testFastForwardFromBase() {
        // 只有远端改了
        let r = LineMerge.merge(base: "a\nb", ours: "a\nb", theirs: "a\nb\nc")
        XCTAssertEqual(r?.text, "a\nb\nc")
        XCTAssertEqual(r?.conflictCount, 0)
    }

    func testDisjointEditsBothKept() {
        let base = "一\n二\n三\n四"
        let ours = "一改了\n二\n三\n四"
        let theirs = "一\n二\n三\n四加了"
        let r = LineMerge.merge(base: base, ours: ours, theirs: theirs)
        XCTAssertEqual(r?.conflictCount, 0)
        XCTAssertEqual(r?.text, "一改了\n二\n三\n四加了")
    }

    func testInsertionsAtDifferentPlaces() {
        let base = "a\nb"
        let ours = "new-top\na\nb"
        let theirs = "a\nb\nnew-bottom"
        let r = LineMerge.merge(base: base, ours: ours, theirs: theirs)
        XCTAssertEqual(r?.conflictCount, 0)
        XCTAssertEqual(r?.text, "new-top\na\nb\nnew-bottom")
    }

    func testSameLineChangedDifferentlyConflicts() {
        let base = "标题句\n正文"
        let ours = "标题句\n正文改了 A"
        let theirs = "标题句\n正文改了 B"
        let r = LineMerge.merge(base: base, ours: ours, theirs: theirs)
        XCTAssertNotNil(r)
        XCTAssertGreaterThan(r?.conflictCount ?? 0, 0)
        // 冲突时保留本地版本，不写冲突标记
        XCTAssertEqual(r?.text, ours)
        XCTAssertFalse((r?.text ?? "").contains("<<<<<<<"))
    }

    func testSameChangeOnBothSidesIsNotConflict() {
        let base = "a\nb"
        let ours = "a\nb!\nc"
        let theirs = "a\nb!\nc"
        let r = LineMerge.merge(base: base, ours: ours, theirs: theirs)
        XCTAssertEqual(r?.conflictCount, 0)
        XCTAssertEqual(r?.text, "a\nb!\nc")
    }

    func testDeletionOnOneSideEditOnOtherConflicts() {
        let base = "a\nb\nc"
        let ours = "a\nc"           // 删了 b
        let theirs = "a\nb改了\nc"   // 改了 b
        let r = LineMerge.merge(base: base, ours: ours, theirs: theirs)
        XCTAssertGreaterThan(r?.conflictCount ?? 0, 0)
    }

    func testTrailingNewlinePreserved() {
        let r = LineMerge.merge(base: "a\n", ours: "a\n", theirs: "a\nb\n")
        XCTAssertEqual(r?.text, "a\nb\n")
    }

    func testTooLargeReturnsNil() {
        let big = (0..<800).map { "第\($0)行" }.joined(separator: "\n")
        let big2 = (0..<800).map { "改\($0)行" }.joined(separator: "\n")
        XCTAssertNil(LineMerge.merge(base: big, ours: big2, theirs: big + "\n尾"))
    }
}
