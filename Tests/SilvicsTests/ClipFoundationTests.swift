import XCTest
@testable import Silvics

/// 剪藏接入类型层的回归测试：单向引用、隔离、标签、元数据同步、模型用途。
final class ClipFoundationTests: XCTestCase {

    private var vault: TempVault!
    private var db: AppDatabase!
    private var repo: GRDBNoteRepository!

    override func setUpWithError() throws {
        vault = TempVault("clip-foundation")
        db = try AppDatabase.makeInMemory()
        repo = vault.repo(db)
    }

    override func tearDown() {
        repo = nil
        db = nil
        vault = nil
    }

    // MARK: - 工具

    @discardableResult
    private func makeClip(
        title: String,
        body: String = "这是一段剪藏正文。",
        tags: [String] = [],
        meta: [String: String] = [:]
    ) throws -> Note {
        var note = Note.draft(title: title)
        note.type = NoteTypes.clipID
        note.body = body
        note.bodyHash = TextNormalizer.bodyHash(body)
        note.setMetaFields(meta)
        note.setTagNames(tags)
        return try repo.save(note)
    }

    @discardableResult
    private func makeConcept(title: String, body: String = "") throws -> Note {
        let note = try repo.create(title: title)
        guard !body.isEmpty else { return note }
        var updated = note
        updated.body = body
        return try repo.save(updated)
    }

    // MARK: - 描述符

    func testClipDescriptorFlags() {
        let clip = NoteTypes.clip
        XCTAssertTrue(clip.linkable, "剪藏要能被 [[ ]] 指向")
        XCTAssertFalse(clip.emitsLinks, "剪藏不产出引用边")
        XCTAssertFalse(clip.isMentionTarget, "剪藏标题不进提及自动机")
        XCTAssertFalse(clip.inMainList, "剪藏不进「全部」")
        XCTAssertFalse(clip.inQuickOpen)
        XCTAssertFalse(clip.countsAsOrphan)
        XCTAssertFalse(clip.scanMentions)
        XCTAssertFalse(clip.tagsInBody, "剪藏标签来自元数据")
        XCTAssertEqual(clip.fileDir, "clips")
        XCTAssertEqual(clip.metaNamespace, "clip")
    }

    func testExistingTypesKeepTheirFlags() {
        XCTAssertTrue(NoteTypes.note.emitsLinks)
        XCTAssertTrue(NoteTypes.journal.emitsLinks)
        XCTAssertTrue(NoteTypes.note.isMentionTarget)
        XCTAssertFalse(NoteTypes.journal.isMentionTarget)
        XCTAssertTrue(NoteTypes.note.inMainList)
        XCTAssertFalse(NoteTypes.journal.inMainList)
    }

    // MARK: - 单向引用

    func testConceptCanReferenceClip() throws {
        let clip = try makeClip(title: "稀疏重复优于集中突击")
        let concept = try makeConcept(
            title: "间隔重复对抗遗忘",
            body: "参考 [[稀疏重复优于集中突击]] 的论述。"
        )

        let outgoing = try repo.outgoing(from: concept.id)
        XCTAssertEqual(outgoing.count, 1)
        XCTAssertEqual(outgoing.first?.toId, clip.id)
        XCTAssertEqual(outgoing.first?.status, .resolved)

        let backlinks = try repo.backlinks(to: clip.id)
        XCTAssertEqual(backlinks.map(\.sourceId), [concept.id])
    }

    func testJournalCanReferenceClip() throws {
        let clip = try makeClip(title: "稀疏重复优于集中突击")
        let journal = try repo.journalNote(on: "2026-11-24", using: [])
        var withBody = journal
        withBody.body = (journal.body.isEmpty ? "" : journal.body + "\n") + "今天重读 [[稀疏重复优于集中突击]]。"
        _ = try repo.save(withBody)

        let outgoing = try repo.outgoing(from: journal.id)
        XCTAssertEqual(outgoing.first?.toId, clip.id)
        XCTAssertEqual(try repo.backlinks(to: clip.id).map(\.sourceId), [journal.id])
    }

    func testClipBodyDoesNotProduceLinks() throws {
        let concept = try makeConcept(title: "间隔重复对抗遗忘")
        let clip = try makeClip(
            title: "稀疏重复优于集中突击",
            body: "原文提到 [[间隔重复对抗遗忘]]，但剪藏不解析引用。"
        )

        XCTAssertTrue(try repo.outgoing(from: clip.id).isEmpty)
        XCTAssertTrue(try repo.backlinks(to: concept.id).isEmpty)
    }

    func testClipIsNotMentionTarget() throws {
        let clip = try makeClip(title: "稀疏重复优于集中突击")
        let concept = try makeConcept(
            title: "间隔重复对抗遗忘",
            body: "读到一篇讲稀疏重复优于集中突击的文章。"
        )

        XCTAssertFalse(try repo.mentions(in: concept.id).contains { $0.targetId == clip.id })
        let patterns = try db.reader.read { conn in try MentionIndex.patterns(in: conn) }
        XCTAssertFalse(patterns.contains { $0.targetId == clip.id })
    }

    // MARK: - 隔离

    func testClipStaysOutOfMainListQueries() throws {
        try makeClip(title: "稀疏重复优于集中突击", tags: ["记忆"])
        let concept = try makeConcept(title: "间隔重复对抗遗忘", body: "#学习方法 正文")

        XCTAssertEqual(try repo.noteCount(), 1)
        XCTAssertEqual(try repo.orphans().map(\.id), [concept.id])
        XCTAssertEqual(try repo.allTags().map(\.name), ["学习方法"])

        let clipTags = try repo.allTags(types: [NoteTypes.clipID])
        XCTAssertEqual(clipTags.map(\.name), ["记忆"])

        XCTAssertFalse(try repo.quickOpen(query: "稀疏").contains { $0.title.contains("稀疏") })
        XCTAssertTrue(try repo.search("稀疏").isEmpty)
    }

    func testClipDoesNotCountAsOrphan() throws {
        try makeClip(title: "稀疏重复优于集中突击")
        XCTAssertEqual(try repo.orphanCount(), 0)
    }

    // MARK: - 补全

    func testCompletionIncludesClipAndExcludesJournal() throws {
        try makeClip(title: "稀疏重复优于集中突击")
        try repo.journalNote(on: "2026-11-24", using: [])

        let clipHits = try repo.completionItems(query: "稀疏")
        XCTAssertEqual(clipHits.first?.type, NoteTypes.clipID)
        XCTAssertTrue(clipHits.first?.isClip ?? false)

        let journalHits = try repo.completionItems(query: "2026")
        XCTAssertTrue(journalHits.filter { !$0.isCreate }.isEmpty, "日记不该出现在 [[ 补全里")
    }

    // MARK: - 改名

    func testRenameRewritesConceptButNotClipBody() throws {
        let concept = try makeConcept(title: "间隔重复对抗遗忘")
        let clip = try makeClip(
            title: "稀疏重复优于集中突击",
            body: "原文引用 [[间隔重复对抗遗忘]] 作为字面示例。"
        )
        let source = try makeConcept(
            title: "写作与记忆",
            body: "参见 [[间隔重复对抗遗忘]]。"
        )

        _ = try repo.rename(noteId: concept.id, newTitle: "间隔重复优于集中突击")

        let updatedSource = try repo.note(id: source.id)
        XCTAssertEqual(updatedSource?.body, "参见 [[间隔重复优于集中突击]]。")

        let untouchedClip = try repo.note(id: clip.id)
        XCTAssertEqual(untouchedClip?.body, "原文引用 [[间隔重复对抗遗忘]] 作为字面示例。")
    }

    // MARK: - 标签与元数据

    func testClipTagsRoundTripThroughVaultFile() throws {
        let clip = try makeClip(title: "稀疏重复优于集中突击", tags: ["记忆", "学习方法"])
        let file = vault.url
            .appendingPathComponent("clips", isDirectory: true)
            .appendingPathComponent(VaultFormat.fileName(for: clip.id))
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("type: clip"))
        XCTAssertTrue(text.contains("tags:"))
        XCTAssertTrue(text.contains("  - 记忆"))

        let decoded = try VaultFormat.decode(text)
        XCTAssertEqual(decoded.tags, ["记忆", "学习方法"])
        XCTAssertEqual(decoded.type, NoteTypes.clipID)
    }

    func testTagsKeyOnConceptIsPreservedAsUnknown() throws {
        var note = VaultFormat.Note(
            id: "n1001abc",
            title: "间隔重复对抗遗忘",
            status: .seedling,
            createdAt: 1_700_000_000_000,
            updatedAt: 1_700_000_500_000,
            aliases: [],
            dismissed: [],
            body: "正文"
        )
        note.type = NoteTypes.noteID
        note.extra.lists["tags"] = ["外部导入"]
        let text = VaultFormat.encode(note)
        let decoded = try VaultFormat.decode(text)
        XCTAssertEqual(decoded.extra.lists["tags"], ["外部导入"], "概念笔记的 tags: 不能丢")
        XCTAssertTrue(decoded.tags.isEmpty)
    }

    func testContentHashCoversMetadata() throws {
        let clip = try makeClip(title: "稀疏重复优于集中突击", tags: ["记忆"], meta: [ClipFields.summary: "旧摘要"])
        let before = try XCTUnwrap(try repo.vaultNotes().first { $0.id == clip.id })

        var changed = clip
        var meta = changed.metaFields
        meta[ClipFields.summary] = "新摘要"
        changed.setMetaFields(meta)
        let updated = try repo.save(changed)
        let after = try XCTUnwrap(try repo.vaultNotes().first { $0.id == updated.id })

        XCTAssertEqual(before.body, after.body)
        XCTAssertNotEqual(
            VaultFormat.contentHash(before),
            VaultFormat.contentHash(after),
            "只改摘要也要让整篇哈希变化"
        )
    }

    func testImportCountsMetadataOnlyChangeAsUpdated() throws {
        let clip = try makeClip(title: "稀疏重复优于集中突击", meta: [ClipFields.summary: "旧摘要"])
        var incoming = try XCTUnwrap(try repo.vaultNotes().first { $0.id == clip.id })
        incoming.meta[ClipFields.summary] = "新摘要"

        let report = try repo.importVaultNotes([incoming])
        XCTAssertEqual(report.unchanged, 0)
        XCTAssertEqual(report.updated, 1)
        XCTAssertEqual(try repo.note(id: clip.id)?.metaFields[ClipFields.summary], "新摘要")
    }

    // MARK: - 三方集合合并

    func testMergeSetKeepsLocalDeletion() {
        let merged = VaultSync.mergeSet(
            base: ["a", "b"],
            local: ["a"],
            remote: ["a", "b"]
        )
        XCTAssertEqual(merged, ["a"], "本地删掉的标签不能被远端复活")
    }

    func testMergeSetKeepsBothAdditions() {
        let merged = VaultSync.mergeSet(
            base: ["a"],
            local: ["a", "b"],
            remote: ["a", "c"]
        )
        XCTAssertEqual(merged, ["a", "b", "c"])
    }

    func testMergeSetKeepsRemoteAddWhenLocalDeletesOther() {
        let merged = VaultSync.mergeSet(
            base: ["a"],
            local: [],
            remote: ["a", "b"]
        )
        XCTAssertEqual(merged, ["b"], "一边删一边加：保留新增")
    }

    // MARK: - 模型用途

    func testClipRoleFollowsChatWhenUnbound() {
        var settings = ProviderSettings()
        let chat = ProviderConfig(name: "对话", kind: .openAICompatible, baseURL: "https://a.com/v1", chatModel: "m")
        settings.providers = [chat]
        settings.chatProviderId = chat.id
        XCTAssertEqual(settings.bound(.clip)?.id, chat.id)

        var bound = settings
        let clipOnly = ProviderConfig(name: "剪藏", kind: .openAICompatible, baseURL: "https://b.com/v1", chatModel: "m2")
        bound.providers.append(clipOnly)
        bound.clipProviderId = clipOnly.id
        XCTAssertEqual(bound.bound(.clip)?.id, clipOnly.id)
    }

    func testClipRoleUsesChatEndpoint() {
        XCTAssertTrue(ProviderRole.clip.usesChatEndpoint)
        XCTAssertTrue(ProviderRole.chat.usesChatEndpoint)
        XCTAssertFalse(ProviderRole.embedding.usesChatEndpoint)
    }

    func testClipRoleProbeBuildsChatRequest() {
        let config = ProviderConfig(
            name: "剪藏", kind: .openAICompatible,
            baseURL: "https://a.com/v1", chatModel: "m"
        )
        guard case .success(let request) = ProviderProbe.request(config: config, key: "k", role: .clip) else {
            return XCTFail("应该能拼出对话请求")
        }
        XCTAssertEqual(request.url.path, "/v1/chat/completions")
    }

    func testDeletingProviderClearsClipBinding() {
        let defaults = UserDefaults(suiteName: "clip-role-\(UUID().uuidString)")!
        let service = ProviderService(secrets: InMemorySecretStore(), defaults: defaults)
        let config = ProviderConfig(
            name: "剪藏", kind: .openAICompatible,
            baseURL: "https://a.com/v1", chatModel: "m"
        )
        XCTAssertTrue(service.upsert(config).isEmpty)
        service.bind(.clip, to: config.id)
        XCTAssertEqual(service.settings.clipProviderId, config.id)

        service.delete(config.id)
        XCTAssertNil(service.settings.clipProviderId)
        defaults.removePersistentDomain(forName: defaults.description)
    }
}
