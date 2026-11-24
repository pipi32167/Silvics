import XCTest
@testable import Silvics

final class WikiScannerTests: XCTestCase {

    func testBasicLink() {
        let text = "但[[遗忘曲线]]决定了长期留存。"
        let links = WikiScanner.scan(text)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].target, "遗忘曲线")
        XCTAssertNil(links[0].display)
        XCTAssertEqual((text as NSString).substring(with: links[0].nsRange(in: text)), "[[遗忘曲线]]")
    }

    func testAliasAndAnchor() {
        let links = WikiScanner.scan("见 [[间隔重复|间隔法]] 与 [[遗忘曲线#遗忘曲线说明了什么]]")
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links[0].target, "间隔重复")
        XCTAssertEqual(links[0].display, "间隔法")
        XCTAssertEqual(links[1].target, "遗忘曲线")
        XCTAssertEqual(links[1].anchor, "遗忘曲线说明了什么")
    }

    func testSkipsFencedCode() {
        let text = """
        正文 [[真实引用]]

        ```swift
        let x = "[[代码块内不算]]"
        ```
        """
        let links = WikiScanner.scan(text)
        XCTAssertEqual(links.map(\.target), ["真实引用"])
    }

    func testSkipsInlineCode() {
        let text = "这里提到 `[[不是引用]]` 但这里是 [[是引用]]"
        let links = WikiScanner.scan(text)
        XCTAssertEqual(links.map(\.target), ["是引用"])
    }

    func testSkipsURL() {
        let text = "见 https://example.com/[[假引用]] 与 [[真引用]]"
        let links = WikiScanner.scan(text)
        XCTAssertEqual(links.map(\.target), ["真引用"])
    }

    func testUnclosedIgnored() {
        let links = WikiScanner.scan("未闭合 [[遗忘曲线 后面没有结束")
        XCTAssertTrue(links.isEmpty)
    }

    func testEmptyTargetIgnored() {
        XCTAssertTrue(WikiScanner.scan("空的 [[ ]] 不算").isEmpty)
    }

    /// 中文区间必须落在正确位置。这是 UTF-16 映射的回归测试。
    func testCJKRangeIsAccurate() {
        let text = "集中突击可以短期记住更多，但[[遗忘曲线]]决定了长期留存。"
        let links = WikiScanner.scan(text)
        XCTAssertEqual(links.count, 1)
        let ns = text as NSString
        XCTAssertEqual(ns.substring(with: links[0].nsRange(in: text)), "[[遗忘曲线]]")
    }
}

final class StylerTests: XCTestCase {

    /// 关键回归：`SourceLocation.column` 是 UTF-8 字节单位。
    /// 按字符映射会取错区间。
    func testStrongRangeUsesUTF8Columns() {
        let text = "集中突击可以短期记住更多，但[[遗忘曲线]]决定了**长期留存**。"
        let spans = MarkdownStyler.analyze(text)
        XCTAssertEqual(spans.strongs.count, 1)
        let ns = text as NSString
        guard let range = spans.strongs.first else { return XCTFail("没有粗体区间") }
        XCTAssertEqual(ns.substring(with: range), "**长期留存**")
    }

    func testHeadingRange() {
        let text = "# 稀疏重复优于集中突击\n\n正文一段。"
        let spans = MarkdownStyler.analyze(text)
        XCTAssertEqual(spans.headings.count, 1)
        XCTAssertEqual(spans.headings[0].level, 1)
        let ns = text as NSString
        XCTAssertTrue(ns.substring(with: spans.headings[0].range).hasPrefix("# 稀疏重复"))
    }

    func testByteToUTF16Map() {
        let text = "a中b"
        let map = MarkdownStyler.buildByteToUTF16Map(text)
        // "a" = 1 byte / 1 unit；"中" = 3 bytes / 1 unit；"b" = 1 byte / 1 unit
        XCTAssertEqual(map.count, text.utf8.count + 1)
        XCTAssertEqual(map[0], 0)
        XCTAssertEqual(map[1], 1)   // "中" 起始
        XCTAssertEqual(map[4], 2)   // "b" 起始
        XCTAssertEqual(map[5], 3)   // 结尾
    }

    func testLineStarts() {
        let text = "第一行\n第二行\n"
        let starts = MarkdownStyler.buildUTF8LineStarts(text)
        XCTAssertEqual(starts.count, 3)
        XCTAssertEqual(starts[0], 0)
        XCTAssertEqual(starts[1], "第一行".utf8.count + 1)
    }

    func testHeadingMarkers() {
        let text = "## 小标题\n正文"
        let markers = MarkdownStyler.headingMarkerRanges(in: text)
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0], NSRange(location: 0, length: 3))
    }
}

final class TitleValidationTests: XCTestCase {

    func testRejectsDateTitle() {
        XCTAssertNotNil(TextNormalizer.validateTitle("2026-10-31"))
        XCTAssertNotNil(TextNormalizer.validateTitle("10月31日"))
        XCTAssertNotNil(TextNormalizer.validateTitle("第3章"))
    }

    func testRejectsBureaucraticPrefix() {
        XCTAssertNotNil(TextNormalizer.validateTitle("读书笔记 认知天性"))
    }

    func testRejectsShortTitle() {
        XCTAssertNotNil(TextNormalizer.validateTitle("遗忘"))
    }

    func testRejectsBrackets() {
        XCTAssertNotNil(TextNormalizer.validateTitle("关于[遗忘]曲线的说明"))
    }

    func testAcceptsGoodTitle() {
        XCTAssertNil(TextNormalizer.validateTitle("稀疏重复优于集中突击"))
    }

    func testKeyNormalization() {
        XCTAssertEqual(TextNormalizer.key("  Hello   World "), "hello world")
        XCTAssertEqual(TextNormalizer.key("ＡＢＣ"), "abc")   // 全角转半角
    }
}

final class DatabaseTests: XCTestCase {

    /// 保存先写 vault 文件，测试要落到临时目录。
    private let vault = TempVault("db")

    func testCreateAndBacklink() throws {
        let db = try AppDatabase.makeInMemory()
        let repo = vault.repo(db)

        let a = try repo.create(title: "间隔重复能提高长期留存")
        _ = try repo.create(title: "遗忘曲线决定复习时机")

        var updated = a
        updated.body = "集中突击效果差，因为[[遗忘曲线决定复习时机]]。"
        _ = try repo.save(updated)

        let backlinks = try repo.backlinks(to: repo.summaries().first { $0.title.hasPrefix("遗忘曲线") }!.id)
        XCTAssertEqual(backlinks.count, 1)
        XCTAssertTrue(backlinks[0].sourceTitle.hasPrefix("间隔重复"))
        XCTAssertTrue(backlinks[0].snippet.contains("遗忘曲线"))
    }

    func testDanglingLink() throws {
        let db = try AppDatabase.makeInMemory()
        let repo = vault.repo(db)
        var note = try repo.create(title: "主动回忆比重读有效")
        note.body = "参见[[还没写的概念]]。"
        _ = try repo.save(note)

        let out = try repo.outgoing(from: note.id)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].status, .dangling)
    }

    /// 先写引用、后建目标笔记，边必须自动接上。
    func testDanglingResolvesWhenTargetCreatedLater() throws {
        let db = try AppDatabase.makeInMemory()
        let repo = vault.repo(db)

        var source = try repo.create(title: "笔记应该密集链接")
        source.body = "理由见[[联想式组织优于层级分类]]。"
        _ = try repo.save(source)

        var out = try repo.outgoing(from: source.id)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].status, .dangling)
        XCTAssertNil(out[0].toId)

        let target = try repo.create(title: "联想式组织优于层级分类")

        out = try repo.outgoing(from: source.id)
        XCTAssertEqual(out[0].status, .resolved)
        XCTAssertEqual(out[0].toId, target.id)

        let back = try repo.backlinks(to: target.id)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].sourceId, source.id)
    }

    /// 目标笔记改名后，旧引用必须退回悬空。
    func testResolvedBecomesDanglingAfterRename() throws {
        let db = try AppDatabase.makeInMemory()
        let repo = vault.repo(db)

        var target = try repo.create(title: "联想式组织优于层级分类")
        var source = try repo.create(title: "笔记应该密集链接")
        source.body = "见[[联想式组织优于层级分类]]。"
        _ = try repo.save(source)

        var out = try repo.outgoing(from: source.id)
        XCTAssertEqual(out[0].status, .resolved)

        target.title = "图结构优于树结构"
        _ = try repo.save(target)

        out = try repo.outgoing(from: source.id)
        XCTAssertEqual(out[0].status, .dangling)
        XCTAssertNil(out[0].toId)
    }

    func testDuplicateTitleRejected() throws {
        let db = try AppDatabase.makeInMemory()
        let repo = vault.repo(db)
        _ = try repo.create(title: "稀疏重复优于集中突击")
        XCTAssertThrowsError(try repo.create(title: "稀疏重复优于集中突击"))
    }

    func testSearchChinese() throws {
        let db = try AppDatabase.makeInMemory()
        let repo = vault.repo(db)
        var note = try repo.create(title: "间隔重复能提高长期留存")
        note.body = "稀疏重复优于集中突击。"
        _ = try repo.save(note)

        let hits = try repo.search("集中突击")
        XCTAssertEqual(hits.count, 1)
    }
}
