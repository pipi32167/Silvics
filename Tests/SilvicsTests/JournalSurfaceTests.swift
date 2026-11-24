import XCTest
@testable import Silvics

/// 批次 6：日记接到界面（侧栏范围、⌘P、待办总览、搜索范围、提及开关、计数）。
///
/// 全部落在 store 层：界面只负责把这里的结果画出来。
final class JournalSurfaceTests: XCTestCase {

    // 日记提及开关存在真实 UserDefaults 里，测试必须用独立 suite，
    // 否则本机的设置会改变索引行为，导致用例互相干扰（甚至数组越界崩溃）。
    override func setUp() {
        super.setUp()
        JournalMentionSettings.defaults = UserDefaults(suiteName: "silvics.tests.\(UUID().uuidString)") ?? .standard
    }

    override func tearDown() {
        JournalMentionSettings.defaults = .standard
        super.tearDown()
    }

    private let vault = TempVault("surface")

    // MARK: - 夹具

    private func makeRepo() throws -> GRDBNoteRepository {
        vault.repo(try AppDatabase.makeInMemory())
    }

    @discardableResult
    private func seedJournal(_ repo: GRDBNoteRepository, date: String, body: String) throws -> Note {
        var journal = try repo.journalNote(on: date, using: [])
        journal.body = body
        return try repo.save(journal)
    }

    // MARK: - 计数：日记不算孤儿，也不占「全部」

    func testOrphanAndNoteCountsExcludeJournal() throws {
        let repo = try makeRepo()
        _ = try repo.create(title: "没有链接的笔记")
        _ = try repo.journalNote(on: "2026-11-24")

        XCTAssertEqual(try repo.orphanCount(), 1, "日记没有链接，但不算孤儿")
        XCTAssertEqual(try repo.orphans().map(\.type), [NoteTypes.noteID])
        XCTAssertEqual(try repo.noteCount(), 1, "「全部」= 普通笔记数")

        // 库里确实是两条：排除只发生在计数与列表，不是丢数据。
        let all = try repo.summaries()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.filter(\.isJournal).count, 1)
    }

    // MARK: - ⌘P 数据源

    func testQuickOpenExcludesJournal() throws {
        let repo = try makeRepo()
        _ = try repo.create(title: "稀疏重复优于集中突击")
        let journal = try repo.journalNote(on: "2026-11-24")

        // 空查询走「最近打开」，同样不能带日记。
        let recent = try repo.quickOpen(query: "")
        XCTAssertFalse(recent.contains { $0.id == journal.id })
        XCTAssertEqual(recent.map(\.title), ["稀疏重复优于集中突击"])

        // 按日期搜也搜不到日记。
        XCTAssertFalse(try repo.quickOpen(query: "2026-11-24").contains { $0.id == journal.id })
        // 普通笔记照常能搜到。
        XCTAssertEqual(try repo.quickOpen(query: "稀疏重复").first?.title, "稀疏重复优于集中突击")
    }

    // MARK: - 待办总览

    func testTodoOverviewKeepsLatestDayStateAndDropsFinishedItems() throws {
        let repo = try makeRepo()
        _ = try seedJournal(repo, date: "2026-11-20", body: """
        - [ ] 买咖啡豆
        - [ ] 写测试
        - [ ] 早睡
        """)
        // 11-21：买咖啡豆已完成，其余仍未完成。
        _ = try seedJournal(repo, date: "2026-11-21", body: """
        - [x] 买咖啡豆
        - [ ] 写测试
        """)
        // 11-22：早睡已完成，写测试仍未完成。
        _ = try seedJournal(repo, date: "2026-11-22", body: """
        - [ ] 写测试
        - [x] 早睡
        """)

        let rows = try repo.todoOverview()

        // 只有「写测试」最近一次出现仍未完成。
        XCTAssertEqual(rows.map(\.text), ["写测试"])
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.firstDate, "2026-11-20")
        XCTAssertEqual(row.lastDate, "2026-11-22")
        XCTAssertEqual(row.dayCount, 3)
        XCTAssertEqual(row.detail, "最早 11-20 · 最近 11-22 · 共 3 天")
    }

    func testTodoOverviewCountsDistinctDaysAndIgnoresCodeBlocks() throws {
        let repo = try makeRepo()
        _ = try seedJournal(repo, date: "2026-11-24", body: """
        - [ ] 每天同一件事
        - [ ] 每天同一件事
        ```
        - [ ] 代码块里的不算
        ```
        """)
        _ = try seedJournal(repo, date: "2026-11-25", body: """
        - [ ] 每天同一件事
        """)

        let rows = try repo.todoOverview()
        XCTAssertEqual(rows.map(\.text), ["每天同一件事"])
        XCTAssertEqual(rows.first?.dayCount, 2, "同一天写两遍只算一天")
        XCTAssertEqual(rows.first?.lastDate, "2026-11-25")
    }

    // MARK: - 侧栏日记列表

    func testJournalEntriesAreSortedWithWeekdayAndOpenCount() throws {
        let repo = try makeRepo()
        _ = try seedJournal(repo, date: "2026-11-20", body: "- [ ] 一件没做的事\n")
        _ = try seedJournal(repo, date: "2026-11-24", body: """
        - [ ] 两件事之一
        - [ ] 两件事之二
        - [x] 已经做完的
        """)

        let entries = try repo.journalEntries()
        XCTAssertEqual(entries.map(\.date), ["2026-11-24", "2026-11-20"])
        XCTAssertEqual(entries.first?.weekday, "周二")
        XCTAssertEqual(entries.first?.openTodoCount, 2)
        XCTAssertEqual(entries.last?.openTodoCount, 1)
    }

    // MARK: - 搜索范围

    func testSearchIncludesJournalOnlyWhenAsked() throws {
        let repo = try makeRepo()
        var note = try repo.create(title: "记忆笔记")
        note.body = "跑步能改善记忆。"
        note = try repo.save(note)

        var journal = try repo.journalNote(on: "2026-11-24")
        journal.body = "## 生活\n今天跑了 5 公里，跑步让思路清楚。"
        journal = try repo.save(journal)

        let notesOnly = try repo.search("跑步", includeJournal: false)
        XCTAssertEqual(notesOnly.map(\.id), [note.id])

        let withJournal = try repo.search("跑步", includeJournal: true)
        XCTAssertEqual(Set(withJournal.map(\.id)), Set([note.id, journal.id]))
        let hit = try XCTUnwrap(withJournal.first { $0.isJournal })
        XCTAssertTrue(hit.snippet.contains("跑步"), "日记命中要给出正文片段：\(hit.snippet)")
    }

    // MARK: - 提及开关

    func testJournalMentionsFollowToggle() throws {
        var repo = try makeRepo()
        _ = try repo.create(title: "稀疏重复优于集中突击")

        var journal = try repo.journalNote(on: "2026-11-24")
        journal.body = "今天重读 稀疏重复优于集中突击 的论证。"
        journal = try repo.save(journal)

        // 默认关：日记不产生提及。
        XCTAssertTrue(try repo.mentions(in: journal.id).isEmpty)

        // 保存链路在开关关闭时也不会写提及（上面断言已覆盖）。

        // 打开：重扫后能扫到。
        repo.journalScanMentions = true
        try repo.reindexJournalMentions()
        let mentions = try repo.mentions(in: journal.id)
        XCTAssertEqual(mentions.count, 1)
        XCTAssertEqual(mentions.first?.targetTitle, "稀疏重复优于集中突击")

        // 开关打开后的保存链路也扫（不止显式重扫）。
        var nextDay = try repo.journalNote(on: "2026-11-25", using: [])
        nextDay.body = "又把 稀疏重复优于集中突击 想了一遍。"
        nextDay = try repo.save(nextDay)
        XCTAssertEqual(try repo.mentions(in: nextDay.id).count, 1)

        // 再关掉：旧提及要清掉，不能只做到「不新增」。
        repo.journalScanMentions = false
        try repo.reindexJournalMentions()
        XCTAssertTrue(try repo.mentions(in: journal.id).isEmpty)
        XCTAssertTrue(try repo.mentions(in: nextDay.id).isEmpty)
    }

    // MARK: - 模板选择

    func testDefaultTemplateNamesTakeTwoSmallestOrders() throws {
        let dir = vault.url.appendingPathComponent(VaultFormat.templatesDir, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, order) in [("生活", 3), ("工作", 1), ("复盘", 2)] {
            let text = "---\ntemplate:\n  name: \(name)\n  order: \(order)\n---\n"
            try text.write(to: dir.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(JournalTemplates.defaultNames(in: vault.url, limit: 2), ["工作", "复盘"])

        // 没有模板时返回空，调用方得到空骨架。
        let empty = TempVault("surface-empty")
        XCTAssertEqual(JournalTemplates.defaultNames(in: empty.url, limit: 2), [])
        XCTAssertEqual(JournalTemplates.skeleton(named: [], in: empty.url), "")
    }
}
