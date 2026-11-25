import XCTest
@testable import Silvics

/// 导航模型：模块、三套范围、每模块记忆、按类型搜索。
///
/// 这组测试守住三件事：
/// 1. 一个模块的范围改不到别的模块。
/// 2. 切走再切回，选中与搜索词还在。
/// 3. 搜索只查传进去的类型，不串。
@MainActor
final class NavigationTests: XCTestCase {

    private var vault: TempVault!
    private var db: AppDatabase!
    private var repo: GRDBNoteRepository!

    override func setUpWithError() throws {
        vault = TempVault("navigation")
        db = try AppDatabase.makeInMemory()
        repo = vault.repo(db)
    }

    override func tearDown() {
        repo = nil
        db = nil
        vault = nil
    }

    // MARK: - 纯状态

    func testScopeChangeDoesNotLeakAcrossModules() {
        var nav = NavigationState()

        // 当前是笔记模块，剪藏范围应被忽略。
        nav.setScope(.clip(.archived))
        XCTAssertEqual(nav.noteScope, .all)
        XCTAssertEqual(nav.active, .notes)

        nav.enter(.clips)
        nav.setScope(.clip(.archived))
        XCTAssertEqual(nav.clipScope, .archived)

        nav.enter(.notes)
        XCTAssertEqual(nav.noteScope, .all)
        XCTAssertEqual(nav.scope.title, "全部")
    }

    func testSelectionAndQueryArePerModule() {
        var nav = NavigationState()
        nav.setSelection("n1")
        nav.setQuery("链接")

        nav.enter(.clips)
        XCTAssertNil(nav.selection)
        XCTAssertEqual(nav.query, "")
        nav.setSelection("c1")
        nav.setQuery("间隔")

        nav.enter(.journal)
        nav.setSelection("j1")

        nav.enter(.notes)
        XCTAssertEqual(nav.selection, "n1")
        XCTAssertEqual(nav.query, "链接")

        nav.enter(.clips)
        XCTAssertEqual(nav.selection, "c1")
        XCTAssertEqual(nav.query, "间隔")

        nav.enter(.journal)
        XCTAssertEqual(nav.selection, "j1")
    }

    func testEnterWithMismatchedScopeOnlySwitchesModule() {
        var nav = NavigationState()
        nav.enter(.journal, scope: .clip(.archived))
        XCTAssertEqual(nav.active, .journal)
        XCTAssertEqual(nav.journalScope, .today)
    }

    func testLegacyScopeRoundTrip() {
        let cases: [SidebarScope] = [
            .all, .orphans, .tag("设计"),
            .journal,
            .clipUnread, .clipAll, .clipArchived, .clipTag("阅读"),
        ]
        for legacy in cases {
            let scope = ModuleScope(legacy: legacy)
            XCTAssertEqual(scope?.legacy, legacy, "\(legacy) 往返不一致")
        }
    }

    // MARK: - 按类型搜索

    func testSearchOnlyReturnsRequestedTypes() throws {
        var note = Note.draft(title: "间隔重复的边界")
        note.body = "间隔重复要靠复述检验。"
        note.bodyHash = TextNormalizer.bodyHash(note.body)
        _ = try repo.save(note)

        let journal = try repo.journalNote(on: "2026-11-24", using: [])
        var updated = journal
        updated.body = "间隔重复今天没做到。"
        _ = try repo.save(updated)

        _ = try repo.createClip(ClipDraft(
            url: "https://example.com/nav",
            title: "间隔重复的三种做法",
            sourceTitle: "间隔重复的三种做法",
            site: "少数派",
            body: "间隔重复分三种节奏。",
            tags: [],
            aiState: .done
        ))

        let onlyClips = try repo.search("间隔重复", types: [NoteTypes.clipID])
        XCTAssertEqual(onlyClips.count, 1)
        XCTAssertEqual(onlyClips.first?.title, "间隔重复的三种做法")

        let onlyJournals = try repo.search("间隔重复", types: [NoteTypes.journalID])
        XCTAssertEqual(onlyJournals.map(\.type), [NoteTypes.journalID])

        let notesAndJournals = try repo.search("间隔重复", types: [NoteTypes.noteID, NoteTypes.journalID])
        XCTAssertEqual(notesAndJournals.count, 2)
    }

    func testSearchWithEmptyTypesReturnsNothing() throws {
        var note = Note.draft(title: "空的类型集")
        note.body = "空的类型集不该命中任何东西。"
        _ = try repo.save(note)

        XCTAssertTrue(try repo.search("类型集", types: []).isEmpty)
    }

    // MARK: - AppState 集成

    func testClipScopesFilterByStatusAndAIState() throws {
        let unread = try repo.createClip(ClipDraft(
            url: "https://example.com/1", title: "未读的剪藏", sourceTitle: "未读的剪藏",
            site: "少数派", body: "正文一。", tags: [], aiState: .done
        ))
        let archived = try repo.createClip(ClipDraft(
            url: "https://example.com/2", title: "归档的剪藏", sourceTitle: "归档的剪藏",
            site: "少数派", body: "正文二。", tags: [], aiState: .done
        ))
        _ = try repo.updateClipStatus(id: archived.id, status: .archived)
        let pending = try repo.createClip(ClipDraft(
            url: "https://example.com/3", title: "待整理的剪藏", sourceTitle: "待整理的剪藏",
            site: "少数派", body: "正文三。", tags: [], aiState: .pending
        ))

        let app = AppState(repo: repo)

        // 未读按状态算，不看模型整理到哪一步；待整理那条也是未读。
        app.enterModule(.clips, scope: .clip(.unread))
        XCTAssertTrue(app.visibleClips.map(\.id).contains(unread.id))
        XCTAssertFalse(app.visibleClips.map(\.id).contains(archived.id))

        app.enterModule(.clips, scope: .clip(.archived))
        XCTAssertEqual(app.visibleClips.map(\.id), [archived.id])

        app.enterModule(.clips, scope: .clip(.pending))
        XCTAssertTrue(app.visibleClips.map(\.id).contains(pending.id))
        XCTAssertFalse(app.visibleClips.map(\.id).contains(unread.id))

        app.enterModule(.clips, scope: .clip(.all))
        XCTAssertEqual(app.visibleClips.count, 3)
    }

    func testJournalModuleSearchesOnlyJournals() throws {
        var note = Note.draft(title: "跑步与写作")
        note.body = "跑步之后写东西更顺。"
        note.bodyHash = TextNormalizer.bodyHash(note.body)
        _ = try repo.save(note)

        let journal = try repo.journalNote(on: "2026-11-24", using: [])
        var updated = journal
        updated.body = "跑步四十分钟。"
        _ = try repo.save(updated)

        let app = AppState(repo: repo)
        app.enterModule(.journal, scope: .journal(.all))
        app.searchQuery = "跑步"

        let hits = app.visibleSummaries()
        XCTAssertEqual(hits.map(\.type), [NoteTypes.journalID])
    }

    func testSwitchingModulesKeepsEachSelection() throws {
        var note = Note.draft(title: "记住我")
        note.body = "切走再切回要还在。"
        _ = try repo.save(note)
        let clip = try repo.createClip(ClipDraft(
            url: "https://example.com/keep", title: "剪藏也要记住", sourceTitle: "剪藏也要记住",
            site: "少数派", body: "正文。", tags: [], aiState: .done
        ))

        let app = AppState(repo: repo)
        app.select(note.id)
        app.enterModule(.clips, scope: .clip(.all))
        app.select(clip.id)

        app.enterModule(.notes, scope: .note(.all))
        XCTAssertEqual(app.selection, note.id)

        app.enterModule(.clips, scope: .clip(.all))
        XCTAssertEqual(app.selection, clip.id)
    }
}
