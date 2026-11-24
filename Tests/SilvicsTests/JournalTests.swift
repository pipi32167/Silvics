import XCTest
@testable import Silvics

/// 批次 3：模板与承接。
///
/// 文档编号对应 `docs/日记编辑器边界用例.md` 第 4 节 C01–C06 与第 3 节 T01–T06。
final class JournalTests: XCTestCase {

    private let vault = TempVault("journal")

    // MARK: - 夹具

    private func makeRepo(_ vault: TempVault? = nil) throws -> GRDBNoteRepository {
        (vault ?? self.vault).repo(try AppDatabase.makeInMemory())
    }

    private func journalFileURL(_ date: String, in vault: TempVault? = nil) -> URL {
        (vault ?? self.vault).url
            .appendingPathComponent(VaultFormat.noteDir(for: NoteTypes.journalID), isDirectory: true)
            .appendingPathComponent(VaultFormat.fileName(for: date))
    }

    /// 往 vault 里放一份模板。`order` 为 nil 时不写 order 字段。
    private func writeTemplate(_ name: String, order: Int?, in vault: TempVault? = nil) throws {
        let dir = (vault ?? self.vault).url
            .appendingPathComponent(VaultFormat.templatesDir, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var text = "---\ntemplate:\n  name: \(name)\n"
        if let order { text += "  order: \(order)\n" }
        text += "---\n"
        try text.write(
            to: dir.appendingPathComponent("\(name).md"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// 建一篇已有日记并灌正文。
    private func seedJournal(_ repo: GRDBNoteRepository, date: String, body: String) throws -> Note {
        var journal = try repo.journalNote(on: date, using: [])
        journal.body = body
        return try repo.save(journal)
    }

    // MARK: - C01 承接块结构

    func testC01CarryBlockStructure() throws {
        let repo = try makeRepo()
        _ = try seedJournal(repo, date: "2026-11-21", body: """
        ## 工作
        - [ ] 把保存链路倒过来
        - [x] 已经做完的一件事
        - [ ] 写承接的测试
        """)

        let today = try repo.journalNote(on: "2026-11-24", using: [])

        // 标题固定：`## 承接（来自 MM-DD）`，日期取后 5 位。
        XCTAssertEqual(today.body, """
        ## 承接（来自 11-21）
        - [ ] 把保存链路倒过来
        - [ ] 写承接的测试

        """, "承接块必须是标题 + 每条一行 `- [ ]`，末尾一个空行")

        let lines = today.body.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "## 承接（来自 11-21）")
        XCTAssertTrue(lines.dropFirst().filter { $0.hasPrefix("- [ ] ") }.count == 2, today.body)
        XCTAssertFalse(today.body.contains("- [x]"), "已完成项不该被搬过来")
    }

    // MARK: - C02 条数等于来源未完成数

    func testC02CarryCountMatchesSourceOpenTodos() throws {
        let repo = try makeRepo()
        _ = try seedJournal(repo, date: "2026-11-21", body: """
        - [ ] 一
        - [x] 二
        * [ ] 三
        + [X] 四
          - [ ] 五
        ```
        - [ ] 代码块里的不算
        ```
        """)
        let source = try XCTUnwrap(repo.note(id: NoteTypes.journalID(for: "2026-11-21")))
        let open = JournalCarry.openTodos(in: source.body)
        XCTAssertEqual(open.count, 3, "\(open)")

        let today = try repo.journalNote(on: "2026-11-24", using: [])
        let carried = today.body
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix("- [ ] ") }
        XCTAssertEqual(carried.count, open.count)
        XCTAssertEqual(carried, ["- [ ] 一", "- [ ] 三", "- [ ] 五"])
        XCTAssertEqual(today.metaFields["carryFrom"], "2026-11-21")
    }

    // MARK: - C03 上一个有日记的日子不是「昨天」

    func testC03CarryComesFromMostRecentJournalNotYesterday() throws {
        let repo = try makeRepo()
        _ = try seedJournal(repo, date: "2026-11-21", body: "- [ ] 二十一号的事")
        _ = try seedJournal(repo, date: "2026-11-23", body: "- [ ] 二十三号的事")

        XCTAssertEqual(try repo.previousJournal(before: "2026-11-24")?.metaFields["date"], "2026-11-23")

        let today = try repo.journalNote(on: "2026-11-24", using: [])
        XCTAssertTrue(today.body.hasPrefix("## 承接（来自 11-23）"), today.body)
        XCTAssertTrue(today.body.contains("- [ ] 二十三号的事"), today.body)
        XCTAssertFalse(today.body.contains("二十一号的事"), today.body)
        XCTAssertEqual(today.metaFields["carryFrom"], "2026-11-23")

        // 中间那天不存在时，跨过空缺取最近的 11-21。
        let gapVault = TempVault("journal-gap")
        let gapRepo = try makeRepo(gapVault)
        _ = try seedJournal(gapRepo, date: "2026-11-21", body: "- [ ] 二十一号的事")
        let gapToday = try gapRepo.journalNote(on: "2026-11-24", using: [])
        XCTAssertTrue(gapToday.body.hasPrefix("## 承接（来自 11-21）"), gapToday.body)
        XCTAssertEqual(gapToday.metaFields["carryFrom"], "2026-11-21")
    }

    func testC03DoesNotCarryFromFutureJournal() throws {
        let repo = try makeRepo()
        _ = try seedJournal(repo, date: "2026-11-25", body: "- [ ] 未来的事")
        let today = try repo.journalNote(on: "2026-11-24", using: [])
        XCTAssertNil(try repo.previousJournal(before: "2026-11-24"))
        XCTAssertFalse(today.body.contains("承接"), today.body)
    }

    // MARK: - C04 已有同名承接不重复插入

    func testC04ExistingCarrySectionIsNotDuplicated() throws {
        let repo = try makeRepo()
        _ = try seedJournal(repo, date: "2026-11-21", body: "- [ ] 只搬一次")

        let first = try repo.journalNote(on: "2026-11-24", using: [])
        let second = try repo.journalNote(on: "2026-11-24", using: [])

        XCTAssertEqual(second.id, first.id, "同一天只应有一篇日记")
        XCTAssertEqual(second.body, first.body, "已存在时返回原笔记，不覆盖、不重复承接")
        XCTAssertEqual(
            first.body.components(separatedBy: "## 承接（来自 11-21）").count - 1,
            1,
            first.body
        )

        // 正文里已经有同名承接段时，插入函数原样返回。
        let withCarry = first.body
        XCTAssertEqual(JournalCarry.insert(into: withCarry, from: "2026-11-21", items: ["再来一次"]), withCarry)
    }

    // MARK: - C05 来源那天没有未完成项

    func testC05NoCarryWhenSourceHasNoOpenTodos() throws {
        let repo = try makeRepo()
        _ = try seedJournal(repo, date: "2026-11-21", body: """
        ## 工作
        - [x] 做完了
        - [X] 也做完了
        """)

        let today = try repo.journalNote(on: "2026-11-24", using: [])
        XCTAssertEqual(today.body, "")
        XCTAssertNil(today.metaFields["carryFrom"])
        XCTAssertFalse(today.body.contains("承接"))
    }

    func testC05NoCarryWhenNoPreviousJournal() throws {
        let repo = try makeRepo()
        let today = try repo.journalNote(on: "2026-11-24", using: [])
        XCTAssertEqual(today.body, "")
        XCTAssertNil(today.metaFields["carryFrom"])
    }

    // MARK: - 模板

    func testTemplateSkeletonFollowsOrder() throws {
        try writeTemplate("生活", order: 2)
        try writeTemplate("工作", order: 1)
        try writeTemplate("复盘", order: 3)
        let repo = try makeRepo()

        // 点名顺序与 order 相反，结果必须按 order 升序。
        let today = try repo.journalNote(on: "2026-11-24", using: ["复盘", "生活", "工作"])
        XCTAssertEqual(today.body, """
        ## 工作

        ## 生活

        ## 复盘

        """, today.body)
    }

    func testMissingTemplateIsSkippedWithoutError() throws {
        try writeTemplate("工作", order: 1)
        let repo = try makeRepo()

        let today = try repo.journalNote(on: "2026-11-24", using: ["工作", "不存在的模板"])
        XCTAssertEqual(today.body, "## 工作\n")
    }

    func testTemplateOrderFallsBackToNameWhenMissing() throws {
        try writeTemplate("b", order: nil)
        try writeTemplate("a", order: nil)
        let repo = try makeRepo()

        let today = try repo.journalNote(on: "2026-11-24", using: ["b", "a"])
        XCTAssertEqual(today.body, "## a\n\n## b\n")
    }

    func testTemplateAndCarryCombineWithCarryFirst() throws {
        try writeTemplate("工作", order: 1)
        let repo = try makeRepo()
        _ = try seedJournal(repo, date: "2026-11-21", body: "- [ ] 昨天没做完的事")

        let today = try repo.journalNote(on: "2026-11-24", using: ["工作"])
        XCTAssertEqual(today.body, """
        ## 承接（来自 11-21）
        - [ ] 昨天没做完的事

        ## 工作

        """, today.body)
    }

    func testTemplateNameDefaultsToFileName() throws {
        let dir = vault.url.appendingPathComponent(VaultFormat.templatesDir, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\ntemplate:\n  order: 1\n---\n".write(
            to: dir.appendingPathComponent("没有名字.md"),
            atomically: true,
            encoding: .utf8
        )
        let repo = try makeRepo()
        let today = try repo.journalNote(on: "2026-11-24", using: ["没有名字"])
        XCTAssertEqual(today.body, "## 没有名字\n")
    }

    // MARK: - 确定性 id

    func testJournalIDIsStableAcrossCallsAndDatesDiffer() {
        XCTAssertEqual(NoteTypes.journalID(for: "2026-11-24"), "j20261124")
        XCTAssertEqual(NoteTypes.journalID(for: "2026-11-24"), NoteTypes.journalID(for: "2026-11-24"))
        XCTAssertNotEqual(NoteTypes.journalID(for: "2026-11-24"), NoteTypes.journalID(for: "2026-11-25"))
        XCTAssertNotEqual(NoteTypes.journalID(for: "2026-11-24"), NoteTypes.journalID(for: "2026-12-24"))
    }

    func testJournalNoteUsesDateDerivedID() throws {
        let repo = try makeRepo()
        let today = try repo.journalNote(on: "2026-11-24", using: [])
        XCTAssertEqual(today.id, "j20261124", "id 只由日期决定，跨设备必须一致")
        XCTAssertEqual(today.title, "2026-11-24")
        XCTAssertEqual(today.type, NoteTypes.journalID)
        XCTAssertEqual(today.metaFields["date"], "2026-11-24")
    }

    func testInvalidDateIsRejected() throws {
        let repo = try makeRepo()
        XCTAssertThrowsError(try repo.journalNote(on: "2026-13-01", using: []))
        XCTAssertThrowsError(try repo.journalNote(on: "20261124", using: []))
        XCTAssertThrowsError(try repo.journalNote(on: "2026-02-30", using: []))
        XCTAssertTrue(try repo.summaries().isEmpty, "日期不合法时不能建出笔记")
    }

    // MARK: - 落 journal/ 目录

    func testJournalFileLandsInJournalDirectory() throws {
        let repo = try makeRepo()
        _ = try repo.journalNote(on: "2026-11-24", using: [])

        let file = journalFileURL("2026-11-24")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), file.path)
        XCTAssertEqual(file.lastPathComponent, "2026-11-24.md")
        XCTAssertEqual(file.deletingLastPathComponent().lastPathComponent, "journal")

        let notesFile = vault.notesURL.appendingPathComponent(journalFileURL("2026-11-24").lastPathComponent)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: notesFile.path),
            "日记不该落在 notes/：\(notesFile.path)"
        )
    }

    func testJournalExportImportKeepsJournalDirectory() throws {
        let source = TempVault("journal-src")
        let repo = try makeRepo(source)
        _ = try seedJournal(repo, date: "2026-11-21", body: "- [ ] 导出往返也要带上")
        let journal = try repo.journalNote(on: "2026-11-24", using: [])

        let mirror = TempVault("journal-dst")
        var settings = SyncSettings()
        settings.vaultPath = mirror.url.path

        try VaultSync(repo: repo, settings: settings).exportAll()
        let exported = mirror.url.appendingPathComponent("journal/2026-11-24.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.path), exported.path)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: mirror.url.appendingPathComponent("notes/2026-11-24.md").path
            ),
            "导出不能把日记写到 notes/"
        )

        // 空库导入同一份 vault，再导一次，仍在 journal/。
        let fresh = try makeRepo(mirror)
        let restore = VaultSync(repo: fresh, settings: settings)
        _ = try restore.importAll()
        let restored = try XCTUnwrap(fresh.note(id: journal.id))
        XCTAssertEqual(restored.type, NoteTypes.journalID)
        XCTAssertEqual(restored.body, journal.body)
        XCTAssertEqual(restored.metaFields["date"], "2026-11-24")

        try FileManager.default.removeItem(at: exported)
        try restore.exportAll()
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.path), "重新导出要回到 journal/")
        XCTAssertEqual(try restore.readVaultNotes().count, 2)
    }

    // MARK: - 索引：不提及、不可引用

    func testJournalProducesNoMentions() throws {
        let repo = try makeRepo()
        var note = try repo.create(title: "间隔重复优于集中突击")
        note.body = "间隔重复优于集中突击。"
        _ = try repo.save(note)

        let journal = try repo.journalNote(on: "2026-11-24", using: [])
        var edited = journal
        edited.body = """
        今天又想到间隔重复优于集中突击，还有间隔重复优于集中突击。
        """
        edited = try repo.save(edited)

        let mentions = try repo.mentions(in: edited.id)
        XCTAssertTrue(mentions.isEmpty, "日记不跑提及扫描：\(mentions)")
        let groups = try repo.mentionGroups()
        XCTAssertTrue(groups.allSatisfy { $0.targetId != edited.id }, "日记不能当提及目标：\(groups)")
    }

    func testJournalIsNotALinkTarget() throws {
        let repo = try makeRepo()
        var note = try repo.create(title: "稀疏重复优于集中突击")
        note.body = "指向 [[2026-11-24]] 的引用应保持悬空。"
        _ = try repo.save(note)

        // 先有悬空引用，后建日记：边必须仍然是悬空的。
        let journal = try repo.journalNote(on: "2026-11-24", using: [])

        let outgoing = try repo.outgoing(from: note.id)
        XCTAssertEqual(outgoing.count, 1)
        XCTAssertEqual(outgoing.first?.rawTarget, "2026-11-24")
        XCTAssertNil(outgoing.first?.toId, "日记不可被引用")
        XCTAssertEqual(outgoing.first?.status, .dangling)
        XCTAssertTrue(try repo.backlinks(to: journal.id).isEmpty)

        // 日记自己要能正常保存，不受影响。
        XCTAssertEqual(try repo.note(id: journal.id)?.type, NoteTypes.journalID)
    }
}
