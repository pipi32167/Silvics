import XCTest
@testable import Silvics

final class TagScannerTests: XCTestCase {

    private func names(_ text: String) -> [String] {
        TagScanner.scan(text).map(\.name)
    }

    func testBasicTags() {
        let text = "本文属于 #记忆 与 #学习。"
        XCTAssertEqual(names(text), ["记忆", "学习"])
    }

    func testRangeCoversHashAndName() {
        let text = "前面 #记忆 后面"
        let hit = TagScanner.scan(text).first!
        XCTAssertEqual((text as NSString).substring(with: hit.range), "#记忆")
    }

    /// ATX 标题的 `#` 后面是空格，不是标签。
    func testHeadingIsNotTag() {
        XCTAssertTrue(names("# 稀疏重复优于集中突击").isEmpty)
        XCTAssertTrue(names("## 二级标题").isEmpty)
    }

    func testFencedCodeIgnored() {
        let text = """
        正文 #真标签

        ```
        #假标签
        ```
        """
        XCTAssertEqual(names(text), ["真标签"])
    }

    func testInlineCodeIgnored() {
        XCTAssertEqual(names("写 `#假标签` 但 #真标签"), ["真标签"])
    }

    func testWikiLinkIgnored() {
        XCTAssertEqual(names("见 [[笔记标题#小标题]] 与 #真标签"), ["真标签"])
    }

    func testURLIgnored() {
        XCTAssertEqual(names("见 https://example.com/#anchor 与 #真标签"), ["真标签"])
    }

    func testDuplicateDeduped() {
        XCTAssertEqual(names("#记忆 和 #记忆 和 #记忆"), ["记忆"])
    }

    func testAllowedCharacters() {
        XCTAssertEqual(names("#间隔-重复_法/v2"), ["间隔-重复_法/v2"])
    }

    func testHashPrecededByLetterIgnored() {
        XCTAssertTrue(names("C# 与 a#b").isEmpty)
    }

    func testHashAloneIgnored() {
        XCTAssertTrue(names("单独的 # 号").isEmpty)
        XCTAssertTrue(names("#").isEmpty)
    }

    func testChinesePunctuationEndsTag() {
        XCTAssertEqual(names("#记忆，然后继续。"), ["记忆"])
    }
}

final class TagAndListTests: XCTestCase {

    private let vault = TempVault("repo")

    private func makeRepo() throws -> (AppDatabase, GRDBNoteRepository) {
        let db = try AppDatabase.makeInMemory()
        return (db, vault.repo(db))
    }

    // MARK: - 标签索引

    func testTagsWrittenOnSave() throws {
        let (_, repo) = try makeRepo()
        var note = try repo.create(title: "稀疏重复优于集中突击")
        note.body = "属于 #记忆 与 #学习方法。"
        _ = try repo.save(note)

        let tags = try repo.allTags()
        XCTAssertEqual(Set(tags.map(\.name)), ["记忆", "学习方法"])
        XCTAssertEqual(tags.first(where: { $0.name == "记忆" })?.count, 1)
    }

    func testTagRemovedWhenBodyChanges() throws {
        let (_, repo) = try makeRepo()
        var note = try repo.create(title: "稀疏重复优于集中突击")
        note.body = "#记忆"
        _ = try repo.save(note)
        XCTAssertEqual(try repo.allTags().count, 1)

        note.body = "不再带标签"
        _ = try repo.save(note)
        XCTAssertTrue(try repo.allTags().isEmpty)
    }

    func testSummariesTagged() throws {
        let (_, repo) = try makeRepo()
        var a = try repo.create(title: "稀疏重复优于集中突击")
        a.body = "#记忆"
        _ = try repo.save(a)
        _ = try repo.create(title: "写作是最有效的思考方式")

        let tagged = try repo.summaries(tagged: "记忆")
        XCTAssertEqual(tagged.count, 1)
        XCTAssertEqual(tagged[0].id, a.id)
    }

    func testTagCountAcrossNotes() throws {
        let (_, repo) = try makeRepo()
        for title in ["稀疏重复优于集中突击", "间隔重复能提高长期留存"] {
            var note = try repo.create(title: title)
            note.body = "#记忆"
            _ = try repo.save(note)
        }
        XCTAssertEqual(try repo.allTags().first?.count, 2)
    }

    func testRebuildIndexesRestoresTags() throws {
        let (db, repo) = try makeRepo()
        var note = try repo.create(title: "稀疏重复优于集中突击")
        note.body = "#记忆"
        _ = try repo.save(note)

        try db.writer.write { conn in
            try conn.execute(sql: "DELETE FROM tag")
        }
        XCTAssertTrue(try repo.allTags().isEmpty)

        try repo.rebuildAllIndexes()
        XCTAssertEqual(try repo.allTags().first?.name, "记忆")
    }

    // MARK: - 孤儿

    func testOrphans() throws {
        let (_, repo) = try makeRepo()
        let linked = try repo.create(title: "遗忘曲线决定长期留存")
        var source = try repo.create(title: "稀疏重复优于集中突击")
        source.body = "见[[遗忘曲线决定长期留存]]。"
        _ = try repo.save(source)
        let lonely = try repo.create(title: "每日回顾能激活沉睡的笔记")

        let orphans = try repo.orphans()
        XCTAssertEqual(orphans.map(\.id), [lonely.id])
        XCTAssertFalse(orphans.contains { $0.id == linked.id })
    }

    // MARK: - Quick Open

    func testQuickOpenPrefixRanksFirst() throws {
        let (_, repo) = try makeRepo()
        _ = try repo.create(title: "间隔重复能提高长期留存")
        let target = try repo.create(title: "稀疏重复优于集中突击")
        _ = try repo.create(title: "写作是最有效的思考方式")

        let items = try repo.quickOpen(query: "稀疏")
        XCTAssertEqual(items.first?.id, target.id)
    }

    func testQuickOpenFuzzy() throws {
        let (_, repo) = try makeRepo()
        let target = try repo.create(title: "稀疏重复优于集中突击")
        _ = try repo.create(title: "中文输入是笔记应用的关键路径")

        let items = try repo.quickOpen(query: "重复突击")
        XCTAssertTrue(items.contains { $0.id == target.id })
    }

    func testQuickOpenEmptyReturnsRecent() throws {
        let (_, repo) = try makeRepo()
        _ = try repo.create(title: "稀疏重复优于集中突击")
        usleep(3_000)   // 两条笔记的 updatedAt 免于落在同一毫秒
        let latest = try repo.create(title: "写作是最有效的思考方式")
        XCTAssertEqual(try repo.quickOpen(query: "").first?.id, latest.id)
    }

    func testQuickOpenCarriesTags() throws {
        let (_, repo) = try makeRepo()
        var note = try repo.create(title: "稀疏重复优于集中突击")
        note.body = "#记忆 #学习"
        _ = try repo.save(note)

        let items = try repo.quickOpen(query: "稀疏")
        XCTAssertEqual(items.first?.tags.sorted(), ["学习", "记忆"])
    }

    // MARK: - 搜索摘要与性能

    func testSearchSnippetCentersOnMatch() throws {
        let (_, repo) = try makeRepo()
        var note = try repo.create(title: "稀疏重复优于集中突击")
        note.body = String(repeating: "前面这段是无关的铺垫文字。", count: 20)
            + "这里出现了关键短语集中突击。"
            + String(repeating: "后面还有很多内容。", count: 20)
        _ = try repo.save(note)

        let result = try repo.search("集中突击")
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].snippet.contains("集中突击"))
        XCTAssertTrue(result[0].snippet.hasPrefix("…"))
    }

    /// P3 验收：1000 条数据下搜索首屏不超过 100 ms。
    ///
    /// 用裸 SQL 灌数据，不经过 `save`（否则会跑 1000 次索引重算）。
    func testSearchFirstScreenUnderBudgetWithThousandNotes() throws {
        let (db, repo) = try makeRepo()
        try db.writer.write { conn in
            for i in 0..<1000 {
                var note = Note.draft(title: "第\(i)条关于记忆与写作的断言标题")
                note.body = "笔记正文第\(i)条。集中突击可以短期记住更多，"
                    + "但遗忘曲线决定长期留存，所以稀疏重复优于集中突击。"
                try note.insert(conn)
                let rowid = try Int64.fetchOne(conn, sql: "SELECT rowid FROM note WHERE id = ?", arguments: [note.id])!
                try conn.execute(
                    sql: "INSERT INTO note_fts(rowid, title, body) VALUES (?, ?, ?)",
                    arguments: [rowid, note.title, note.body]
                )
            }
        }

        let rounds = 10
        let start = CFAbsoluteTimeGetCurrent()
        var hits = 0
        for _ in 0..<rounds {
            hits += try repo.search("集中突击", limit: 50).count
        }
        let averageMs = (CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(rounds)
        print(String(format: "[Search] 1000 notes, avg %.2f ms, hits/round %d", averageMs, hits / rounds))

        XCTAssertEqual(hits / rounds, 50, "应有 50 条结果（limit 上限）")
        #if DEBUG
        XCTAssertLessThan(averageMs, 300, "Debug 构建搜索预算 300 ms")
        #else
        XCTAssertLessThan(averageMs, 100, "Release 构建搜索预算 100 ms")
        #endif
    }
}
