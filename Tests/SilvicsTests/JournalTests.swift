import XCTest
@testable import Silvics

/// 批次 3：模板与待办融合（issue #48）。
///
/// 文档编号对应 `docs/日记编辑器边界用例.md` 第 4 节 M01–M12 与第 3 节 T01–T06。
/// 细则用例在 `JournalMergeTests`，这里只验收新建链路与日期来源。
final class JournalTests: XCTestCase {

    // 日记提及开关存在真实 UserDefaults 里，测试必须用独立 suite，
    // 否则本机的设置会改变索引行为，导致用例互相干扰（甚至数组越界崩溃）。
    override func setUp() {
        super.setUp()
        JournalMentionSettings.defaults = UserDefaults(suiteName: "silvics.tests.\(UUID().uuidString)") ?? .standard
        // 模板记忆同样要被隔离：本机记住的模板会改变「新建时用哪些模板」。
        JournalTemplateMemory.defaults = UserDefaults(suiteName: "silvics.tests.templates.\(UUID().uuidString)") ?? .standard
    }

    override func tearDown() {
        JournalMentionSettings.defaults = .standard
        JournalTemplateMemory.defaults = .standard
        super.tearDown()
    }

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

    // MARK: - M13 新建日记：未完成项并进同名段

    func testM13NewJournalMergesOpenTodosIntoSections() throws {
        try writeTemplate("工作", order: 1)
        try writeTemplate("生活", order: 2)
        let repo = try makeRepo()
        _ = try seedJournal(repo, date: "2026-11-21", body: """
        ## 工作
        - [ ] 把保存链路倒过来
        - [x] 已经做完的一件事
        ## 生活
        - [ ] 买咖啡豆
        """)

        let today = try repo.journalNote(on: "2026-11-24", using: ["工作", "生活"])
        XCTAssertEqual(today.body, """
        ## 工作
        - [ ] 把保存链路倒过来

        ## 生活
        - [ ] 买咖啡豆

        """, today.body)
        XCTAssertFalse(today.body.contains("承接"), "不再有独立承接段")
        XCTAssertFalse(today.body.contains("已经做完的一件事"), "已完成的不搬")
        XCTAssertEqual(today.metaFields["carryFrom"], "2026-11-21")
    }

    // MARK: - M14 条数等于来源未完成数

    func testM14MergeCountMatchesSourceOpenTodos() throws {
        try writeTemplate("工作", order: 1)
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
        let open = JournalMerge.openTodos(in: source.body)
        XCTAssertEqual(open.map(\.text), ["一", "三", "五"], "\(open)")

        let today = try repo.journalNote(on: "2026-11-24", using: ["工作"])
        let merged = JournalMerge.openTodos(in: today.body)
        XCTAssertEqual(merged.map(\.text), ["一", "三", "五"], "条数等于来源未完成数：\(today.body)")
        XCTAssertTrue(today.body.contains("- [ ] 一"), "标记与缩进按原文搬：\(today.body)")
        XCTAssertFalse(today.body.contains("代码块里的不算"))
    }

    // MARK: - M15 上一个有日记的日子不是「昨天」

    /// 用**真实日期**走一遍「昨天 → 今天」，验证不是只有合成日期能过。
    func testMergeFromYesterdayIntoTodayWithRealDates() throws {
        let repo = try makeRepo()
        let today = JournalDate.today()
        let yesterday = JournalDate.today(Date().addingTimeInterval(-24 * 3600))

        var prev = try repo.journalNote(on: yesterday, using: [])
        prev.body = """
        ## 工作
        - [ ] 昨天没做完 A
        - [ ] 昨天没做完 B
        - [x] 昨天已经做完 C
        """
        _ = try repo.save(prev)

        let todayNote = try repo.journalNote(on: today, using: [])
        XCTAssertTrue(todayNote.body.contains("- [ ] 昨天没做完 A"), todayNote.body)
        XCTAssertTrue(todayNote.body.contains("- [ ] 昨天没做完 B"), todayNote.body)
        XCTAssertFalse(todayNote.body.contains("昨天已经做完 C"), "已完成的不能带过来")
        XCTAssertFalse(todayNote.body.contains("承接"))
        XCTAssertEqual(todayNote.metaFields["carryFrom"], yesterday)
        XCTAssertEqual(JournalTodos.openCount(in: todayNote.body), 2)
    }

    func testMergeComesFromMostRecentJournalNotYesterday() throws {
        let repo = try makeRepo()
        _ = try seedJournal(repo, date: "2026-11-21", body: "- [ ] 二十一号的事")
        _ = try seedJournal(repo, date: "2026-11-23", body: "- [ ] 二十三号的事")

        XCTAssertEqual(try repo.previousJournal(before: "2026-11-24")?.metaFields["date"], "2026-11-23")

        let today = try repo.journalNote(on: "2026-11-24", using: [])
        XCTAssertEqual(today.body, "- [ ] 二十三号的事\n", today.body)
        XCTAssertEqual(today.metaFields["carryFrom"], "2026-11-23")

        // 中间那天不存在时，跨过空缺取最近的 11-21。
        let gapVault = TempVault("journal-gap")
        let gapRepo = try makeRepo(gapVault)
        _ = try seedJournal(gapRepo, date: "2026-11-21", body: "- [ ] 二十一号的事")
        let gapToday = try gapRepo.journalNote(on: "2026-11-24", using: [])
        XCTAssertEqual(gapToday.body, "- [ ] 二十一号的事\n", gapToday.body)
        XCTAssertEqual(gapToday.metaFields["carryFrom"], "2026-11-21")
    }

    func testDoesNotMergeFromFutureJournal() throws {
        let repo = try makeRepo()
        _ = try seedJournal(repo, date: "2026-11-25", body: "- [ ] 未来的事")
        let today = try repo.journalNote(on: "2026-11-24", using: [])
        XCTAssertNil(try repo.previousJournal(before: "2026-11-24"))
        XCTAssertEqual(today.body, "")
        XCTAssertNil(today.metaFields["carryFrom"])
    }

    // MARK: - M16 同一天重复新建不重复融合

    func testM16ExistingJournalIsNotMergedTwice() throws {
        let repo = try makeRepo()
        _ = try seedJournal(repo, date: "2026-11-21", body: "- [ ] 只搬一次")

        let first = try repo.journalNote(on: "2026-11-24", using: [])
        let second = try repo.journalNote(on: "2026-11-24", using: [])

        XCTAssertEqual(second.id, first.id, "同一天只应有一篇日记")
        XCTAssertEqual(second.body, first.body, "已存在时返回原笔记，不覆盖、不重复融合")
        let text = "- [ ] 只搬一次"
        XCTAssertEqual(first.body.components(separatedBy: text).count - 1, 1, first.body)

        // 再融合一次：全部已存在，正文一个字都不改。
        let again = JournalMerge.merge(into: first.body, from: JournalMerge.openTodos(in: "- [ ] 只搬一次"))
        XCTAssertEqual(again.added, 0)
        XCTAssertEqual(again.skipped, 1)
        XCTAssertEqual(again.body, first.body)
    }

    // MARK: - M17 来源那天没有未完成项

    func testM17NoMergeWhenSourceHasNoOpenTodos() throws {
        let repo = try makeRepo()
        _ = try seedJournal(repo, date: "2026-11-21", body: """
        ## 工作
        - [x] 做完了
        - [X] 也做完了
        """)

        let today = try repo.journalNote(on: "2026-11-24", using: [])
        XCTAssertEqual(today.body, "")
        XCTAssertNil(today.metaFields["carryFrom"])
    }

    func testM17NoMergeWhenNoPreviousJournal() throws {
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

    func testTemplateAndMergeCombineInsideSection() throws {
        try writeTemplate("工作", order: 1)
        let repo = try makeRepo()
        _ = try seedJournal(repo, date: "2026-11-21", body: "- [ ] 昨天没做完的事")

        // 来源没有标题，条目落到当天第一个标题所在段。
        let today = try repo.journalNote(on: "2026-11-24", using: ["工作"])
        XCTAssertEqual(today.body, """
        ## 工作
        - [ ] 昨天没做完的事

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

    // MARK: - 行号与 UTF-16 偏移

    func testCaretLineHelpersUseUTF16Offsets() throws {
        // 一行里有中文与 emoji：按 UTF-16 数才和 NSTextView 的光标位置一致。
        let body = "第一行😀\n第二行\n第三行"
        XCTAssertEqual(JournalCaret.lineIndex(ofUTF16Offset: 0, in: body), 0)
        XCTAssertEqual(JournalCaret.lineIndex(ofUTF16Offset: (body as NSString).range(of: "第二行").location, in: body), 1)
        XCTAssertEqual(JournalCaret.lineIndex(ofUTF16Offset: (body as NSString).length, in: body), 2)
        XCTAssertEqual(JournalCaret.lineIndex(ofUTF16Offset: 9_999, in: body), 2, "越界夹到末行")

        XCTAssertEqual(JournalCaret.utf16Offset(ofLine: 0, in: body), 0)
        XCTAssertEqual(JournalCaret.utf16Offset(ofLine: 1, in: body), ("第一行😀\n" as NSString).length)
        XCTAssertNil(JournalCaret.utf16Offset(ofLine: 3, in: body))

        // 行号 → 偏移 → 行号 往返一致。
        for line in 0..<3 {
            let offset = try XCTUnwrap(JournalCaret.utf16Offset(ofLine: line, in: body))
            XCTAssertEqual(JournalCaret.lineIndex(ofUTF16Offset: offset, in: body), line)
        }
    }

    // MARK: - 模板记忆

    func testTemplateMemoryOrderFollowsTemplateOrder() throws {
        try writeTemplate("生活", order: 2)
        try writeTemplate("工作", order: 1)

        JournalTemplateMemory.names = ["生活", "工作"]
        XCTAssertEqual(JournalTemplateMemory.names, ["生活", "工作"], "记忆按写入顺序保存")

        let repo = try makeRepo()
        // 记住的是「生活、工作」，骨架必须按 order 排：工作在生活之前。
        let names = JournalTemplates.newJournalNames(in: vault.url)
        XCTAssertEqual(names, ["工作", "生活"])

        let today = try repo.journalNote(on: "2026-11-24", using: names)
        XCTAssertEqual(today.body, "## 工作\n\n## 生活\n")
    }

    func testTemplateMemorySkipsDeletedTemplate() throws {
        try writeTemplate("工作", order: 1)
        try writeTemplate("生活", order: 2)
        JournalTemplateMemory.names = ["生活", "已删除的模板"]

        let names = JournalTemplates.newJournalNames(in: vault.url)
        XCTAssertEqual(names, ["生活"], "文件没了的模板跳过，不报错也不留空标题")

        let repo = try makeRepo()
        let today = try repo.journalNote(on: "2026-11-24", using: names)
        XCTAssertEqual(today.body, "## 生活\n")
        XCTAssertFalse(today.body.contains("已删除的模板"))
    }

    func testTemplateMemoryFallsBackWhenAllStale() throws {
        try writeTemplate("工作", order: 1)
        try writeTemplate("生活", order: 2)
        try writeTemplate("复盘", order: 3)
        JournalTemplateMemory.names = ["已删除", "也没了"]

        XCTAssertEqual(JournalTemplates.newJournalNames(in: vault.url), ["工作", "生活"], "一个都不剩就退回 order 最小的前两个")

        let repo = try makeRepo()
        let today = try repo.journalNote(on: "2026-11-24", using: JournalTemplates.newJournalNames(in: vault.url))
        XCTAssertEqual(today.body, "## 工作\n\n## 生活\n")
    }

    func testTemplateOverrideAppliesToNextCreateOnly() throws {
        try writeTemplate("工作", order: 1)
        try writeTemplate("生活", order: 2)
        try writeTemplate("复盘", order: 3)
        let repo = try makeRepo()

        // 先记住「工作」，新建 11-24。
        JournalTemplateMemory.names = ["工作"]
        let first = try repo.journalNote(on: "2026-11-24", using: JournalTemplates.newJournalNames(in: vault.url))
        XCTAssertEqual(first.body, "## 工作\n")

        // 「模板…」保存：勾选改成「复盘、生活」（这一步就是把 UserDefaults 里的名单覆盖掉）。
        JournalTemplateMemory.names = ["复盘", "生活"]
        XCTAssertEqual(JournalTemplateMemory.names, ["复盘", "生活"])

        // 下一次新建用新选择，顺序仍按 order。
        let second = try repo.journalNote(on: "2026-11-25", using: JournalTemplates.newJournalNames(in: vault.url))
        XCTAssertEqual(second.body, "## 生活\n\n## 复盘\n")

        // 已有日记的正文一个字都不改。
        XCTAssertEqual(try repo.note(id: first.id)?.body, "## 工作\n")

        // 清空记忆 → 下一次回到默认前两个。
        JournalTemplateMemory.reset()
        XCTAssertEqual(JournalTemplates.newJournalNames(in: vault.url), ["工作", "生活"])
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

    // MARK: - 标题被普通笔记占住

    func testJournalDateTakenByPlainNoteIsNotOverwritten() throws {
        let repo = try makeRepo()
        var plain = try repo.create(title: "2026-11-24")
        plain.body = "这是普通笔记，不是日记。"
        plain = try repo.save(plain)
        let before = try XCTUnwrap(repo.note(id: plain.id))

        XCTAssertThrowsError(try repo.journalNote(on: "2026-11-24", using: [])) { error in
            guard case NoteWriter.SaveError.titleTaken = error else {
                return XCTFail("应为 titleTaken，实际：\(error)")
            }
        }

        let after = try XCTUnwrap(repo.note(id: plain.id))
        XCTAssertEqual(after.body, before.body, "被占住的那篇正文不能动")
        XCTAssertEqual(after.type, NoteTypes.noteID, "不能把它改成日记")
        XCTAssertEqual(after.title, "2026-11-24")
        XCTAssertEqual(try repo.summaries().count, 1, "不能额外建出一篇")
        XCTAssertNil(try repo.journal(on: "2026-11-24"))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: journalFileURL("2026-11-24").path),
            "不能留下 journal/2026-11-24.md：\(journalFileURL("2026-11-24").path)"
        )
    }

    // MARK: - 同一 id 的两份文件

    /// 往 `dir/` 里写一份「同一个 id 的旧文件」，模拟旧版本把日记写在 `notes/`。
    /// 旧版本的文件名是 id，不是日期。
    private func writeStaleCopy(
        id: String,
        body: String,
        updatedAt: Int64,
        dir: String = VaultFormat.notesDir
    ) throws -> URL {
        let url = vault.url
            .appendingPathComponent(dir, isDirectory: true)
            .appendingPathComponent(VaultFormat.fileName(for: id))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let note = VaultFormat.Note(
            id: id,
            title: "2026-11-24",
            status: .seedling,
            createdAt: updatedAt,
            updatedAt: updatedAt,
            aliases: [],
            dismissed: [],
            body: body,
            type: NoteTypes.journalID,
            meta: ["date": "2026-11-24"]
        )
        try VaultFormat.encode(note).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func trashFiles() -> [String] {
        let dir = vault.url.appendingPathComponent(VaultFormat.trashDir, isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    /// 旧目录那份更旧：进 `.trash/`，活文件是新写的这份。
    func testStaleCopyInNotesIsArchivedNotDeleted() throws {
        let repo = try makeRepo()
        var journal = try repo.journalNote(on: "2026-11-24", using: [])
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let stale = journal.id
        let staleURL = try writeStaleCopy(id: stale, body: "手改过的旧版", updatedAt: now - 600_000)

        journal.body = "库里新写的一版"
        journal = try repo.save(journal)

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path), "旧目录那份不能留在原位")
        let live = try VaultFormat.decode(
            String(contentsOf: journalFileURL("2026-11-24"), encoding: .utf8)
        )
        XCTAssertEqual(live.body, "库里新写的一版")

        let archived = trashFiles()
        XCTAssertEqual(archived.count, 1, "\(archived)")
        XCTAssertTrue(archived[0].hasSuffix("stale-copy.md"), archived[0])
        let trashText = try String(
            contentsOf: vault.url
                .appendingPathComponent(VaultFormat.trashDir, isDirectory: true)
                .appendingPathComponent(archived[0]),
            encoding: .utf8
        )
        XCTAssertEqual(try VaultFormat.decode(trashText).body, "手改过的旧版", "旧内容必须完整留在 .trash，不能直接删")
    }

    /// 旧目录那份更新（用户手改过且 `updated:` 更晚）：以它为准，刚写的那份进 `.trash/`。
    func testNewerStaleCopyWinsAndOlderSaveIsArchived() throws {
        let repo = try makeRepo()
        var journal = try repo.journalNote(on: "2026-11-24", using: [])
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let staleURL = try writeStaleCopy(
            id: journal.id, body: "手改过的新版", updatedAt: now + 600_000
        )

        journal.body = "库里写的旧一版"
        journal = try repo.save(journal)

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path))
        let live = try VaultFormat.decode(
            String(contentsOf: journalFileURL("2026-11-24"), encoding: .utf8)
        )
        XCTAssertEqual(live.body, "手改过的新版", "较新的那份要活下来")
        XCTAssertEqual(live.updatedAt, now + 600_000)

        // 库跟着文件走，否则下次保存又把旧的写回去。
        let stored = try XCTUnwrap(repo.note(id: journal.id))
        XCTAssertEqual(stored.body, "手改过的新版")
        XCTAssertEqual(journal.body, "手改过的新版", "返回给调用方的也是较新的这份")

        let archived = trashFiles()
        XCTAssertEqual(archived.count, 1, "\(archived)")
        XCTAssertTrue(archived[0].hasSuffix("superseded.md"), archived[0])
        let trashText = try String(
            contentsOf: vault.url
                .appendingPathComponent(VaultFormat.trashDir, isDirectory: true)
                .appendingPathComponent(archived[0]),
            encoding: .utf8
        )
        XCTAssertEqual(try VaultFormat.decode(trashText).body, "库里写的旧一版")
    }
}
