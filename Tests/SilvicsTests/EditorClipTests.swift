import XCTest
@testable import Silvics

/// 剪藏的打开行为与编辑器/标题链路。命名沿用计划里的 EditorClipTests。
@MainActor
final class EditorClipTests: XCTestCase {

    private var vault: TempVault!
    private var db: AppDatabase!
    private var repo: GRDBNoteRepository!

    override func setUpWithError() throws {
        vault = TempVault("editor-clip")
        db = try AppDatabase.makeInMemory()
        repo = vault.repo(db)
    }

    override func tearDown() {
        repo = nil
        db = nil
        vault = nil
    }

    @discardableResult
    private func makeClip(title: String = "稀疏重复优于集中突击", body: String = "剪藏正文，包含 [[间隔重复对抗遗忘]] 作为字面示例。") throws -> Note {
        try repo.createClip(ClipDraft(
            url: "https://example.com/\(UUID().uuidString)",
            title: title,
            sourceTitle: title,
            site: "少数派",
            body: body,
            tags: ["记忆"],
            aiState: .done
        ))
    }

    func testOpeningClipMarksReadWhenEnabled() throws {
        let clip = try makeClip()
        let app = AppState(repo: repo)
        XCTAssertTrue(app.clipSettings.markReadOnOpen)

        app.selectClipScope(.clipAll)
        app.select(clip.id)

        let stored = try repo.clip(id: clip.id)
        XCTAssertEqual(stored?.metaFields[ClipFields.status], ClipStatus.read.rawValue)
    }

    func testOpeningClipKeepsUnreadWhenDisabled() throws {
        let clip = try makeClip()
        var settings = ClipSettings()
        settings.markReadOnOpen = false
        let app = AppState(repo: repo, clipSettings: settings)

        app.selectClipScope(.clipAll)
        app.select(clip.id)

        let stored = try repo.clip(id: clip.id)
        XCTAssertEqual(stored?.metaFields[ClipFields.status], ClipStatus.unread.rawValue)
    }

    func testOpeningConceptDoesNotTouchClipStatus() throws {
        let clip = try makeClip()
        let concept = try repo.create(title: "间隔重复对抗遗忘")
        let app = AppState(repo: repo)

        app.selectClipScope(.clipAll)
        // 切范围会按设置自动标已读；先改回未读，再验证「打开概念笔记」不会动剪藏状态。
        app.setClipStatus(id: clip.id, status: .unread)
        app.select(concept.id)

        XCTAssertEqual(try repo.clip(id: clip.id)?.metaFields[ClipFields.status], ClipStatus.unread.rawValue)
    }

    func testFileNameWinsForSmartTitleStrategy() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-title-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("从文件名来的标题.txt")
        try "正文内容，第一行不是标题。".write(to: file, atomically: true, encoding: .utf8)

        let draft = try ClipFileImport.draft(from: file)
        XCTAssertEqual(draft.sourceTitle, "从文件名来的标题", "文件名要进 sourceTitle，才能被智能策略优先采用")

        var settings = ClipSettings()
        settings.titleStrategy = .smart
        let suggestion = ClipSuggestion(
            title: "模型给的另一句话标题",
            summary: "这是一段足够长的摘要内容，用于通过校验。",
            tags: ["记忆"]
        )
        let result = ClipAIService.finalize(
            draft: draft,
            suggestion: suggestion,
            settings: settings,
            existingTags: [],
            isTaken: { _ in false }
        )
        XCTAssertEqual(result.draft.title, "从文件名来的标题")
        try? FileManager.default.removeItem(at: dir)
    }

    func testMissingProviderMarksPendingNotFailed() {
        let draft = ClipDraft(title: "", sourceTitle: "原文标题", site: "", body: "正文内容")
        var settings = ClipSettings()
        settings.autoSummarize = true

        let result = ClipAIService.finalize(
            draft: draft,
            suggestion: nil,
            settings: settings,
            existingTags: [],
            providerAvailable: false,
            isTaken: { _ in false }
        )
        XCTAssertEqual(result.draft.aiState, .pending, "没配模型是待整理，不是失败")
    }

    func testConfiguredProviderFailureMarksFailed() {
        let draft = ClipDraft(title: "", sourceTitle: "原文标题", site: "", body: "正文内容")
        let result = ClipAIService.finalize(
            draft: draft,
            suggestion: nil,
            settings: ClipSettings(),
            existingTags: [],
            providerAvailable: true,
            isTaken: { _ in false }
        )
        XCTAssertEqual(result.draft.aiState, .failed)
    }

    func testShortTitleFallsBack() {
        let title = ClipTitle.finalize(raw: "AI", source: "", body: "AI 与写作的关系\n正文") { _ in false }
        XCTAssertTrue(title.count >= ClipTitle.minLength, "少于 4 字要退回正文兜底")
    }

    func testRenameImpactIgnoresClipBody() throws {
        let concept = try repo.create(title: "间隔重复对抗遗忘")
        _ = try makeClip(body: "原文引用 [[间隔重复对抗遗忘]] 作为字面示例。")

        let impacts = try repo.renameImpact(noteId: concept.id, newTitle: "间隔重复优于集中突击")
        XCTAssertTrue(impacts.isEmpty, "剪藏不解析引用，改名预览不能把它算进去")
    }
}
