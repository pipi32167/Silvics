import XCTest
@testable import Silvics

final class MentionDatabaseTests: XCTestCase {

    private let vault = TempVault("repo")

    private func makeRepo() throws -> (AppDatabase, GRDBNoteRepository) {
        let db = try AppDatabase.makeInMemory()
        return (db, vault.repo(db))
    }

    // MARK: - 写入

    func testMentionRecordedOnSave() throws {
        let (_, repo) = try makeRepo()
        let target = try repo.create(title: "遗忘曲线决定长期留存")
        var source = try repo.create(title: "稀疏重复优于集中突击")
        source.body = "集中突击短期有效，但遗忘曲线决定长期留存。"
        _ = try repo.save(source)

        let mentions = try repo.mentions(in: source.id)
        XCTAssertEqual(mentions.count, 1)
        XCTAssertEqual(mentions[0].targetId, target.id)
        XCTAssertEqual(mentions[0].kind, .exact)
        XCTAssertTrue(mentions[0].snippet.contains("遗忘曲线"))
        XCTAssertEqual((source.body as NSString).substring(with: NSRange(location: mentions[0].location, length: mentions[0].length)), "遗忘曲线决定长期留存")
    }

    func testSelfMentionIgnored() throws {
        let (_, repo) = try makeRepo()
        var note = try repo.create(title: "稀疏重复优于集中突击")
        note.body = "这条笔记讲的是稀疏重复优于集中突击。"
        _ = try repo.save(note)
        XCTAssertTrue(try repo.mentions(in: note.id).isEmpty)
    }

    func testCodeBlockMentionIgnored() throws {
        let (_, repo) = try makeRepo()
        _ = try repo.create(title: "遗忘曲线决定长期留存")
        var source = try repo.create(title: "稀疏重复优于集中突击")
        source.body = """
        正文提到遗忘曲线决定长期留存。

        ```
        遗忘曲线决定长期留存
        ```
        """
        _ = try repo.save(source)
        XCTAssertEqual(try repo.mentions(in: source.id).count, 1)
    }

    func testExistingWikiLinkNotAMention() throws {
        let (_, repo) = try makeRepo()
        _ = try repo.create(title: "遗忘曲线决定长期留存")
        var source = try repo.create(title: "稀疏重复优于集中突击")
        source.body = "见[[遗忘曲线决定长期留存]]。"
        _ = try repo.save(source)
        XCTAssertTrue(try repo.mentions(in: source.id).isEmpty)
    }

    func testReindexDropsStaleMention() throws {
        let (_, repo) = try makeRepo()
        _ = try repo.create(title: "遗忘曲线决定长期留存")
        var source = try repo.create(title: "稀疏重复优于集中突击")
        source.body = "遗忘曲线决定长期留存"
        _ = try repo.save(source)
        XCTAssertEqual(try repo.mentions(in: source.id).count, 1)

        source.body = "改写成[[遗忘曲线决定长期留存]]了"
        _ = try repo.save(source)
        XCTAssertTrue(try repo.mentions(in: source.id).isEmpty)
    }

    func testDismissSurvivesReindex() throws {
        let (_, repo) = try makeRepo()
        _ = try repo.create(title: "遗忘曲线决定长期留存")
        var source = try repo.create(title: "稀疏重复优于集中突击")
        source.body = "遗忘曲线决定长期留存"
        _ = try repo.save(source)

        let mention = try XCTUnwrap(try repo.mentions(in: source.id).first)
        try repo.dismissMention(id: mention.id)
        XCTAssertTrue(try repo.mentions(in: source.id).isEmpty)

        source.body = "还是那句：遗忘曲线决定长期留存。"
        _ = try repo.save(source)
        XCTAssertTrue(try repo.mentions(in: source.id).isEmpty, "忽略状态要保留")
    }

    // MARK: - 转换

    func testConvertSingleMention() throws {
        let (_, repo) = try makeRepo()
        _ = try repo.create(title: "遗忘曲线决定长期留存")
        var source = try repo.create(title: "稀疏重复优于集中突击")
        source.body = "集中突击短期有效，但遗忘曲线决定长期留存。"
        _ = try repo.save(source)

        let mention = try XCTUnwrap(try repo.mentions(in: source.id).first)
        let conversions = try repo.convertMentions(occurrenceIds: [mention.id])
        XCTAssertEqual(conversions.count, 1)
        XCTAssertEqual(conversions[0].insertedCount, 1)
        XCTAssertEqual(conversions[0].previousBody, source.body)

        let saved = try XCTUnwrap(try repo.note(id: source.id))
        XCTAssertEqual(saved.body, "集中突击短期有效，但[[遗忘曲线决定长期留存]]。")
        XCTAssertTrue(try repo.mentions(in: source.id).isEmpty)

        let links = try repo.outgoing(from: source.id)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].status, .resolved)
    }

    func testConvertBatchAcrossNotes() throws {
        let (_, repo) = try makeRepo()
        let target = try repo.create(title: "遗忘曲线决定长期留存")

        var a = try repo.create(title: "稀疏重复优于集中突击")
        a.body = "遗忘曲线决定长期留存。再看遗忘曲线决定长期留存。"
        _ = try repo.save(a)

        var b = try repo.create(title: "主动回忆比重读有效")
        b.body = "因为遗忘曲线决定长期留存。"
        _ = try repo.save(b)

        let ids = try (repo.mentions(in: a.id) + repo.mentions(in: b.id)).map(\.id)
        XCTAssertEqual(ids.count, 3)

        let conversions = try repo.convertMentions(occurrenceIds: ids)
        XCTAssertEqual(conversions.count, 2)

        let savedA = try XCTUnwrap(try repo.note(id: a.id))
        XCTAssertEqual(savedA.body, "[[遗忘曲线决定长期留存]]。再看[[遗忘曲线决定长期留存]]。")
        let savedB = try XCTUnwrap(try repo.note(id: b.id))
        XCTAssertEqual(savedB.body, "因为[[遗忘曲线决定长期留存]]。")

        var backlinks = try repo.backlinks(to: target.id)
        XCTAssertEqual(Set(backlinks.map(\.sourceId)), [a.id, b.id])
        backlinks = try repo.backlinks(to: target.id)
        XCTAssertEqual(backlinks.count, 2)
    }

    func testRestoreBodiesUndoesConversion() throws {
        let (_, repo) = try makeRepo()
        _ = try repo.create(title: "遗忘曲线决定长期留存")
        var source = try repo.create(title: "稀疏重复优于集中突击")
        source.body = "但遗忘曲线决定长期留存。"
        _ = try repo.save(source)

        let mention = try XCTUnwrap(try repo.mentions(in: source.id).first)
        let conversions = try repo.convertMentions(occurrenceIds: [mention.id])
        var undo: [String: String] = [:]
        for conversion in conversions { undo[conversion.id] = conversion.previousBody }
        try repo.restoreBodies(undo)

        let saved = try XCTUnwrap(try repo.note(id: source.id))
        XCTAssertEqual(saved.body, "但遗忘曲线决定长期留存。")
        XCTAssertEqual(try repo.mentions(in: source.id).count, 1)
        XCTAssertTrue(try repo.outgoing(from: source.id).isEmpty)
    }

    func testMentionGroupsAggregate() throws {
        let (_, repo) = try makeRepo()
        _ = try repo.create(title: "遗忘曲线决定长期留存")
        var a = try repo.create(title: "稀疏重复优于集中突击")
        a.body = "遗忘曲线决定长期留存"
        _ = try repo.save(a)
        var b = try repo.create(title: "主动回忆比重读有效")
        b.body = "遗忘曲线决定长期留存，遗忘曲线决定长期留存"
        _ = try repo.save(b)

        let groups = try repo.mentionGroups()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].count, 3)
        XCTAssertEqual(groups[0].noteCount, 2)
    }

    // MARK: - 别名

    func testAliasProducesMentionAndResolvesLink() throws {
        let (_, repo) = try makeRepo()
        let target = try repo.create(title: "遗忘曲线决定长期留存")
        let error = try repo.addAlias(noteId: target.id, name: "遗忘规律")
        XCTAssertNil(error)
        XCTAssertEqual(try repo.aliases(noteId: target.id), ["遗忘规律"])

        var source = try repo.create(title: "稀疏重复优于集中突击")
        source.body = "本质是遗忘规律在起作用，见[[遗忘规律]]。"
        _ = try repo.save(source)

        let mentions = try repo.mentions(in: source.id)
        XCTAssertEqual(mentions.count, 1)
        XCTAssertEqual(mentions[0].kind, .alias)
        XCTAssertEqual(mentions[0].targetId, target.id)

        let links = try repo.outgoing(from: source.id)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].toId, target.id)
    }

    func testAliasRejectedOnConflict() throws {
        let (_, repo) = try makeRepo()
        let a = try repo.create(title: "遗忘曲线决定长期留存")
        _ = try repo.create(title: "稀疏重复优于集中突击")

        XCTAssertNotNil(try repo.addAlias(noteId: a.id, name: "稀疏重复优于集中突击"), "与已有标题冲突要拒绝")
        XCTAssertNotNil(try repo.addAlias(noteId: a.id, name: "遗忘"), "太短要拒绝")
        XCTAssertNil(try repo.addAlias(noteId: a.id, name: "遗忘曲线"))
        XCTAssertTrue(try repo.removeAlias(noteId: a.id, name: "遗忘曲线"))
        XCTAssertTrue(try repo.aliases(noteId: a.id).isEmpty)
    }

    // MARK: - 改名

    func testRenameImpactPreview() throws {
        let (_, repo) = try makeRepo()
        let target = try repo.create(title: "稀疏重复优于集中突击")
        var source = try repo.create(title: "间隔重复能提高长期留存")
        source.body = "见[[稀疏重复优于集中突击]]与[[稀疏重复优于集中突击|旧说法]]。"
        _ = try repo.save(source)

        let impact = try repo.renameImpact(noteId: target.id, newTitle: "间隔重复优于集中突击")
        XCTAssertEqual(impact.count, 1)
        XCTAssertEqual(impact[0].noteId, source.id)
        XCTAssertEqual(impact[0].occurrences, 2)
    }

    func testRenameRewritesBodies() throws {
        let (_, repo) = try makeRepo()
        let target = try repo.create(title: "稀疏重复优于集中突击")
        var source = try repo.create(title: "间隔重复能提高长期留存")
        source.body = "见[[稀疏重复优于集中突击]]与[[稀疏重复优于集中突击|旧说法]]，还有[[稀疏重复优于集中突击#原因]]。"
        _ = try repo.save(source)

        let changed = try repo.rename(noteId: target.id, newTitle: "分散重复优于集中突击")
        XCTAssertEqual(changed, 1)

        let saved = try XCTUnwrap(try repo.note(id: source.id))
        XCTAssertEqual(saved.body, "见[[分散重复优于集中突击]]与[[分散重复优于集中突击|旧说法]]，还有[[分散重复优于集中突击#原因]]。")

        let links = try repo.outgoing(from: source.id)
        XCTAssertEqual(links.count, 3)
        XCTAssertTrue(links.allSatisfy { $0.status == .resolved })
    }

    /// 改名后旧标题自动成为别名，外部旧引用不会变悬空。
    func testRenameKeepsOldTitleResolvable() throws {
        let (_, repo) = try makeRepo()
        let target = try repo.create(title: "稀疏重复优于集中突击")
        _ = try repo.rename(noteId: target.id, newTitle: "分散重复优于集中突击")

        XCTAssertEqual(try repo.aliases(noteId: target.id), ["稀疏重复优于集中突击"])

        var late = try repo.create(title: "间隔重复能提高长期留存")
        late.body = "旧写法是[[稀疏重复优于集中突击]]。"
        _ = try repo.save(late)

        let links = try repo.outgoing(from: late.id)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].toId, target.id)
        XCTAssertEqual(links[0].status, .resolved)
    }

    func testRenameRejectsInvalidTitle() throws {
        let (_, repo) = try makeRepo()
        let target = try repo.create(title: "稀疏重复优于集中突击")
        XCTAssertThrowsError(try repo.rename(noteId: target.id, newTitle: "2026-10-31"))
        XCTAssertThrowsError(try repo.rename(noteId: target.id, newTitle: "短"))
    }

    func testRenameReindexesMentions() throws {
        let (_, repo) = try makeRepo()
        let target = try repo.create(title: "稀疏重复优于集中突击")
        var source = try repo.create(title: "间隔重复能提高长期留存")
        source.body = "结论是稀疏重复优于集中突击。"
        _ = try repo.save(source)
        XCTAssertEqual(try repo.mentions(in: source.id).count, 1)

        _ = try repo.rename(noteId: target.id, newTitle: "分散重复优于集中突击")
        // 正文里写的是旧标题，它现在是别名，仍是提及，但指向同一条笔记
        let mentions = try repo.mentions(in: source.id)
        XCTAssertEqual(mentions.count, 1)
        XCTAssertEqual(mentions[0].targetId, target.id)
        XCTAssertEqual(mentions[0].kind, .alias)
    }

    // MARK: - 搜索转义

    func testSearchLikeEscapesWildcards() throws {
        let (_, repo) = try makeRepo()
        var note = try repo.create(title: "稀疏重复优于集中突击")
        note.body = "100% 的注意力都花在这里"
        _ = try repo.save(note)

        XCTAssertEqual(try repo.search("100%").count, 1)
        XCTAssertEqual(try repo.search("100%").first?.id, note.id)
        XCTAssertTrue(try repo.search("%%不存在%%").isEmpty)
    }
}
