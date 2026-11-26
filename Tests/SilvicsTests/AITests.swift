import XCTest
@testable import Silvics

// MARK: - 设置

final class AISettingsTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "silvics-ai-settings-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testDefaults() {
        let settings = AISettings()
        XCTAssertFalse(settings.systemPrompt.isEmpty)
        XCTAssertEqual(settings.bodyLimit, 8000)
        XCTAssertEqual(settings.historyRounds, 10)
        XCTAssertEqual(settings.panel, .details)
        XCTAssertEqual(settings.prompts.count, 4)
        XCTAssertTrue(settings.prompts.allSatisfy(\.builtin))
    }

    func testMissingFieldsUseDefaults() throws {
        let json = #"{"bodyLimit":4000}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AISettings.self, from: json)
        XCTAssertEqual(decoded.bodyLimit, 4000)
        XCTAssertEqual(decoded.historyRounds, 10)
        XCTAssertEqual(decoded.prompts.count, 4, "缺 prompts 时要点回内置项")
        XCTAssertFalse(decoded.systemPrompt.isEmpty)
    }

    func testOutOfRangeValuesAreClamped() throws {
        let json = #"{"bodyLimit":123,"historyRounds":99,"panelTab":"nope"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AISettings.self, from: json)
        XCTAssertEqual(decoded.bodyLimit, 8000)
        XCTAssertEqual(decoded.historyRounds, 10)
        XCTAssertEqual(decoded.panel, .details)
    }

    func testEmptySystemPromptFallsBack() throws {
        let json = #"{"systemPrompt":"   "}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AISettings.self, from: json)
        XCTAssertEqual(decoded.systemPrompt, AISettings.defaultSystemPrompt)
    }

    func testBuiltinPromptsStayFirstAndCannotBeDropped() throws {
        var settings = AISettings()
        settings.prompts = [AIPromptTemplate(id: "custom-1", title: "自定义", body: "正文", builtin: false)]
        let repaired = settings.repaired()
        XCTAssertEqual(repaired.prompts.count, 5)
        XCTAssertEqual(repaired.prompts.first?.id, "builtin-summary")
        XCTAssertEqual(repaired.prompts.first?.body, AISettings.builtinPrompts[0].body,
                       "内置项被删掉时要补回默认正文")
        XCTAssertEqual(repaired.prompts.last?.id, "custom-1")
    }

    func testResetPromptsRestoresBuiltinsAndDropsCustom() {
        var settings = AISettings()
        settings.prompts[0].body = "改过的正文"
        settings.prompts.append(AIPromptTemplate(id: "custom-1", title: "自定义", body: "正文"))
        let reset = AISettings.resetPrompts(settings)
        XCTAssertEqual(reset.prompts.count, 4)
        XCTAssertEqual(reset.prompts[0].body, AISettings.builtinPrompts[0].body)
    }

    func testSaveLoadAndClear() {
        var settings = AISettings()
        settings.bodyLimit = 0
        settings.historyRounds = 3
        settings.panelTab = AISettings.PanelTab.ai.rawValue
        settings.save(to: defaults)

        let loaded = AISettings.load(from: defaults)
        XCTAssertEqual(loaded.bodyLimit, 0)
        XCTAssertEqual(loaded.historyRounds, 3)
        XCTAssertEqual(loaded.panel, .ai)

        AISettings.clear(from: defaults)
        XCTAssertEqual(AISettings.load(from: defaults), AISettings())
    }
}

// MARK: - JSONL 与会话合并

final class AIConversationTests: XCTestCase {

    private func message(_ role: String, _ content: String, at: Int64, id: String? = nil) -> AIMessage {
        AIMessage(id: id ?? UUID().uuidString, at: at, role: role, content: content)
    }

    func testJSONLRoundTripKeepsNewlinesAndChinese() {
        let quote = AIQuote(noteID: "n1", noteTitle: "标题", text: "引用")
        var user = AIMessage.user("第一行\n第二行「引号」", at: 1000, quote: quote)
        user.evidences = [AIEvidence(url: "https://example.com/a", title: "页面", text: "正文")]
        user.model = "deepseek-chat"
        user.inputTokens = 1200
        user.outputTokens = 380
        let messages = [user, AIMessage.assistant("回答\n换行", at: 2000)]

        let text = AIConversation.encode(messages)
        XCTAssertEqual(text.split(separator: "\n").count, 2, "一条消息必须只有一行")

        let decoded = AIConversation.decode(text)
        XCTAssertTrue(decoded.badLines.isEmpty)
        XCTAssertEqual(decoded.messages, messages, "元数据与换行都要原样回来")
    }

    func testEncodeIsStable() {
        let message = message("user", "内容", at: 500, id: "fixed-id")
        XCTAssertEqual(AIConversation.encode([message]), AIConversation.encode([message]))
    }

    func testBadLinesAreSkipped() {
        let good = AIConversation.encode([message("user", "好的", at: 100)])
        let text = good + "这不是 JSON\n" + #"{"id":"","at":1,"role":"user"}"# + "\n"
        let decoded = AIConversation.decode(text)
        XCTAssertEqual(decoded.messages.count, 1)
        XCTAssertEqual(decoded.badLines.count, 2, "空 id 也算坏行")
    }

    func testDecodeSortsByTime() {
        let messages = [
            message("assistant", "二", at: 2000),
            message("user", "一", at: 1000),
        ]
        let decoded = AIConversation.decode(AIConversation.encode(messages))
        XCTAssertEqual(decoded.messages.map(\.content), ["一", "二"])
    }

    func testMergeUnionsBothSides() {
        let base: [AIMessage] = []
        let local = [message("user", "本地", at: 1000)]
        let remote = [message("user", "远端", at: 2000)]
        let merged = AIConversation.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(merged.map(\.content), ["本地", "远端"])
    }

    func testMergeDeduplicatesByID() {
        let shared = message("user", "同一条", at: 1000, id: "same")
        let merged = AIConversation.merge(base: [shared], local: [shared], remote: [shared])
        XCTAssertEqual(merged.count, 1)
    }

    func testMergeKeepsLocalOnSameIDConflict() {
        let local = message("user", "本地版本", at: 1000, id: "same")
        let remote = message("user", "远端版本", at: 1000, id: "same")
        let merged = AIConversation.merge(base: [], local: [local], remote: [remote])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.content, "本地版本")
    }

    func testMergeDropsMessagesBeforeLatestClear() {
        let old = message("user", "旧问题", at: 1000)
        let answer = message("assistant", "旧回答", at: 2000)
        let clear = AIMessage.clear(at: 3000)
        let fresh = message("user", "新问题", at: 4000)

        // 一端清了空，另一端还在追加旧的。
        let local = [old, answer, clear]
        let remote = [old, answer]
        let merged = AIConversation.merge(base: [], local: local, remote: remote)
        XCTAssertTrue(merged.contains(where: \.isClear))
        XCTAssertFalse(merged.contains(where: { $0.content == "旧问题" }))
        XCTAssertFalse(merged.contains(where: { $0.content == "旧回答" }))

        let merged2 = AIConversation.merge(base: [], local: [old, answer, clear, fresh], remote: [old, answer])
        XCTAssertEqual(AIConversation.visible(merged2).map(\.content), ["新问题"])
    }

    func testClearAtSameMillisecondAlsoDrops() {
        let old = message("user", "同毫秒", at: 3000)
        let clear = AIMessage.clear(at: 3000)
        let merged = AIConversation.merge(base: [], local: [old, clear], remote: [])
        XCTAssertTrue(AIConversation.visible(merged).isEmpty)
    }

    func testTrimKeepsLatest() {
        let messages = (0..<250).map { message("user", "第\($0)条", at: Int64($0)) }
        let trimmed = AIConversation.trim(messages)
        XCTAssertEqual(trimmed.count, AISettings.maxMessages)
        XCTAssertEqual(trimmed.last?.content, "第249条")
    }

    func testTrimCapsFileBytes() {
        // 每条 ~12 KB，40 条远超 200 KB 上限。
        let big = String(repeating: "字", count: 4000)
        let messages = (0..<40).map {
            AIMessage(id: "m\($0)", at: Int64($0), role: AIMessage.roleUser, content: big)
        }
        let trimmed = AIConversation.trim(messages)
        let bytes = AIConversation.encode(trimmed).utf8.count
        XCTAssertLessThanOrEqual(bytes, AISettings.maxFileBytes)
        XCTAssertLessThan(trimmed.count, messages.count)
        XCTAssertEqual(trimmed.last?.id, "m39", "丢的是最早的")
    }

    func testTrimKeepsAtLeastOneMessage() {
        let huge = AIMessage(id: "only", at: 1, role: AIMessage.roleUser,
                             content: String(repeating: "字", count: 200_000))
        XCTAssertEqual(AIConversation.trim([huge]).count, 1, "不能裁到一条不剩")
    }

    func testFileNameRoundTrip() {
        XCTAssertEqual(AIConversation.fileName(for: "n123"), "n123.jsonl")
        XCTAssertEqual(AIConversation.noteID(fromFileName: "n123.jsonl"), "n123")
        XCTAssertNil(AIConversation.noteID(fromFileName: "n123.md"))
        XCTAssertEqual(AIConversation.noteID(fromFileName: AIConversation.fileName(for: "_global")), "_global")
    }
}

// MARK: - 上下文拼装

final class AIContextBuilderTests: XCTestCase {

    private func request(
        body: String = "正文",
        limit: Int = 8000,
        rounds: Int = 10,
        history: [AIMessage] = [],
        quote: AIQuote? = nil,
        evidences: [AIEvidence] = []
    ) -> AIContextRequest {
        AIContextRequest(
            systemPrompt: "系统提示",
            noteTitle: "笔记标题",
            noteBody: body,
            quote: quote,
            evidences: evidences,
            history: history,
            question: "问题",
            bodyLimit: limit,
            historyRounds: rounds
        )
    }

    func testBodyTruncationKeepsHeadAndTail() {
        let body = String(repeating: "甲", count: 20_000)
        let out = AIContextBuilder.truncateBody(body, limit: 8000)
        XCTAssertTrue(out.contains("中间省略"))
        XCTAssertLessThan(out.count, 8100)
        XCTAssertTrue(out.hasPrefix("甲"))
    }

    func testBodyLimitZeroDropsBody() {
        XCTAssertEqual(AIContextBuilder.truncateBody("正文内容", limit: 0), "")
        let messages = AIContextBuilder.build(request(body: "正文内容", limit: 0))
        XCTAssertFalse(messages[0].content.contains("笔记正文"))
    }

    func testQuoteTruncation() {
        let quote = String(repeating: "乙", count: 800)
        let out = AIContextBuilder.truncateQuote(quote)
        XCTAssertTrue(out.contains("中间省略 300 字"))
        XCTAssertLessThan(out.count, 550, "头 300 加尾 200，再加提示")
        XCTAssertTrue(out.hasPrefix("乙"))
        XCTAssertEqual(AIContextBuilder.truncateQuote("短片段"), "短片段", "不超限就不动")
    }

    func testHistoryTrimKeepsLatestRounds() {
        var history: [AIMessage] = []
        for index in 0..<20 {
            history.append(.user("问\(index)", at: Int64(index * 2)))
            history.append(.assistant("答\(index)", at: Int64(index * 2 + 1)))
        }
        let trimmed = AIContextBuilder.trimHistory(history, rounds: 10)
        XCTAssertEqual(trimmed.count, 20, "10 轮 = 20 条")
        XCTAssertEqual(trimmed.first?.content, "问10")
        XCTAssertEqual(trimmed.last?.content, "答19")
    }

    func testHistoryTrimDropsLeadingAssistant() {
        let history: [AIMessage] = [
            .assistant("孤立的回答", at: 1),
            .user("问", at: 2),
            .assistant("答", at: 3),
        ]
        let trimmed = AIContextBuilder.trimHistory(history, rounds: 2)
        XCTAssertEqual(trimmed.first?.role, AIMessage.roleUser)
    }

    func testSystemCarriesContextAndQuote() {
        let quote = AIQuote(noteID: "n1", noteTitle: "剪藏标题", text: "选中片段")
        let messages = AIContextBuilder.build(request(quote: quote))
        XCTAssertEqual(messages.first?.role, "system")
        let system = messages[0].content
        XCTAssertTrue(system.contains("系统提示"))
        XCTAssertTrue(system.contains("笔记标题"))
        XCTAssertTrue(system.contains("正文"))
        XCTAssertTrue(system.contains("选中片段"))
        XCTAssertTrue(system.contains("剪藏标题"))
    }

    func testEmptyBodyDoesNotInsertEmptyBlock() {
        let messages = AIContextBuilder.build(request(body: "   "))
        XCTAssertFalse(messages[0].content.contains("笔记正文"))
    }

    func testEvidenceOnlyInFinalUserMessage() {
        let evidence = AIEvidence(url: "https://example.com/a", title: "页面", text: "网页正文")
        let request = request(evidences: [evidence])
        let messages = AIContextBuilder.build(request)
        XCTAssertEqual(messages.last?.role, "user")
        XCTAssertTrue(messages.last?.content.contains("网页正文") ?? false)
        XCTAssertTrue(messages.last?.content.contains("https://example.com/a") ?? false)
        XCTAssertTrue(messages.last?.content.contains("不可信数据") ?? false)

        // 证据不能出现在系统消息里，否则每一轮都会重发。
        XCTAssertFalse(messages[0].content.contains("网页正文"))
    }

    func testHistoryMessagesArePassedThrough() {
        let history: [AIMessage] = [.user("上一问", at: 1), .assistant("上一答", at: 2)]
        let messages = AIContextBuilder.build(request(history: history))
        XCTAssertEqual(messages.count, 1 + 2 + 1)
        XCTAssertEqual(messages[1].role, "user")
        XCTAssertEqual(messages[1].content, "上一问")
        XCTAssertEqual(messages[2].content, "上一答")
    }

    func testOrderIsStableForAllProviders() {
        // 三种协议族都按 messages 数组顺序发，所以顺序只需在拼装处定死。
        let messages = AIContextBuilder.build(request())
        XCTAssertEqual(messages.first?.role, "system")
        XCTAssertEqual(messages.last?.role, "user")
    }
}

// MARK: - 会话文件

final class AIConversationStoreTests: XCTestCase {

    private var vault: TempVault!
    private var store: AIConversationStore!

    override func setUp() {
        vault = TempVault("ai")
        store = AIConversationStore(vaultURL: vault.url)
    }

    override func tearDown() {
        vault = nil
        store = nil
    }

    func testAppendAndLoad() throws {
        try store.append(.user("第一个问题", at: 1000), noteID: "n1")
        try store.append(.assistant("第一个回答", at: 2000), noteID: "n1")
        let loaded = store.load(noteID: "n1")
        XCTAssertEqual(loaded.messages.map(\.content), ["第一个问题", "第一个回答"])
        XCTAssertEqual(loaded.badLines, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(noteID: "n1").path))
    }

    func testFileIsUnderAIDirectory() {
        let path = store.fileURL(noteID: "n1").path
        XCTAssertTrue(path.contains("/ai/n1.jsonl"), path)
    }

    func testSaveIsIdempotent() throws {
        let messages = [AIMessage.user("内容", at: 1000)]
        XCTAssertTrue(try store.save(messages, noteID: "n1"))
        XCTAssertFalse(try store.save(messages, noteID: "n1"), "内容没变不该再写")
    }

    func testClearWritesMarkerAndKeepsFile() throws {
        try store.append(.user("问题", at: 1000), noteID: "n1")
        let after = try store.clear(noteID: "n1", at: 2000)
        XCTAssertTrue(after.contains(where: \.isClear))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(noteID: "n1").path),
                      "清空不删文件")
        XCTAssertTrue(AIConversation.visible(after).isEmpty)
    }

    func testNewMessageAfterClearRevivesVisibleList() throws {
        try store.append(.user("问题", at: 1000), noteID: "n1")
        try store.clear(noteID: "n1", at: 2000)
        try store.append(.user("清空后的新问题", at: 3000), noteID: "n1")
        let loaded = store.load(noteID: "n1")
        XCTAssertEqual(AIConversation.visible(loaded.messages).map(\.content), ["清空后的新问题"])
    }

    func testMergeAndSaveUnionsRemote() throws {
        try store.append(.user("远端写的", at: 2000), noteID: "n1")
        let merged = try store.mergeAndSave(
            noteID: "n1",
            local: [.user("本地写的", at: 1000)]
        )
        XCTAssertEqual(merged.map(\.content), ["本地写的", "远端写的"])
        XCTAssertEqual(store.load(noteID: "n1").messages.count, 2)
    }

    func testLoadAllFindsEveryConversation() throws {
        try store.append(.user("一", at: 1000), noteID: "n1")
        try store.append(.user("二", at: 1000), noteID: AIConversation.globalID)
        let all = store.loadAll()
        XCTAssertEqual(Set(all.keys), ["n1", AIConversation.globalID])
    }

    func testLoadAllOnMissingDirectoryIsEmpty() {
        let empty = AIConversationStore(vaultURL: vault.url.appendingPathComponent("nope"))
        XCTAssertTrue(empty.loadAll().isEmpty)
    }

    func testRemoveDeletesFile() throws {
        try store.append(.user("一", at: 1000), noteID: "n1")
        try store.remove(noteID: "n1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(noteID: "n1").path))
    }
}

// MARK: - 会话跨设备同步

/// 用本机 bare 仓库当远端，两个 vault 当两台设备，验证会话是并集而不是互相覆盖。
final class AIConversationSyncTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("silvics-ai-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func git(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = root
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_AUTHOR_NAME"] = "测试"
        env["GIT_AUTHOR_EMAIL"] = "t@example.com"
        env["GIT_COMMITTER_NAME"] = "测试"
        env["GIT_COMMITTER_EMAIL"] = "t@example.com"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        _ = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "git", code: Int(process.terminationStatus))
        }
    }

    private func makeDevice(_ name: String, remote: URL) throws -> (sync: VaultSync, vault: URL) {
        let vault = root.appendingPathComponent(name, isDirectory: true)
        let repo = GRDBNoteRepository(db: try AppDatabase.makeInMemory(), vaultURL: vault)
        var settings = SyncSettings()
        settings.vaultPath = vault.path
        settings.remoteURL = remote.path
        settings.authorName = name
        settings.authorEmail = "\(name)@example.com"
        return (VaultSync(repo: repo, settings: settings), vault)
    }

    func testBothDevicesAppendAndBothSurvive() throws {
        let remote = root.appendingPathComponent("remote.git", isDirectory: true)
        try git(["init", "--bare", "-q", "-b", "main", remote.path])

        let a = try makeDevice("device-a", remote: remote)
        let b = try makeDevice("device-b", remote: remote)
        let noteID = "n-shared"

        // A 先写一条并推上去，B 拉下来。
        try AIConversationStore(vaultURL: a.vault).save(
            [AIMessage(id: "a1", at: 1000, role: AIMessage.roleUser, content: "A 的提问")],
            noteID: noteID
        )
        _ = try a.sync.sync()
        _ = try b.sync.sync()

        // 两端各自再追加一条，互不知道对方。
        let storeA = AIConversationStore(vaultURL: a.vault)
        let storeB = AIConversationStore(vaultURL: b.vault)
        _ = try storeA.append(
            AIMessage(id: "a2", at: 2000, role: AIMessage.roleAssistant, content: "A 的回答"),
            noteID: noteID
        )
        _ = try storeB.append(
            AIMessage(id: "b2", at: 3000, role: AIMessage.roleUser, content: "B 的提问"),
            noteID: noteID
        )

        // A 先推，B 再同步（B 落后一条）。
        _ = try a.sync.sync()
        _ = try b.sync.sync()
        // B 推上去，A 再拉一次，两端都该看到三条。
        _ = try b.sync.sync()
        _ = try a.sync.sync()

        let onA = storeA.load(noteID: noteID).messages
        let onB = storeB.load(noteID: noteID).messages
        XCTAssertEqual(onA.map(\.id).sorted(), ["a1", "a2", "b2"], "A 不能丢 B 的消息")
        XCTAssertEqual(onB.map(\.id).sorted(), ["a1", "a2", "b2"], "B 不能丢 A 的消息")
        XCTAssertEqual(onA.map(\.content), ["A 的提问", "A 的回答", "B 的提问"], "按时间排序")
    }

    func testManifestCarriesConversationHash() throws {
        let remote = root.appendingPathComponent("remote.git", isDirectory: true)
        try git(["init", "--bare", "-q", "-b", "main", remote.path])
        let a = try makeDevice("device-a", remote: remote)
        _ = try AIConversationStore(vaultURL: a.vault).save(
            [AIMessage(id: "x1", at: 1000, role: AIMessage.roleUser, content: "内容")],
            noteID: "n-1"
        )
        _ = try a.sync.exportAll()
        let data = try Data(contentsOf: a.vault.appendingPathComponent(VaultFormat.manifestName))
        let manifest = try XCTUnwrap(VaultFormat.decodeManifest(data))
        XCTAssertEqual(manifest.schema, VaultFormat.manifestSchema)
        XCTAssertEqual(manifest.conversations.map(\.id), ["n-1"])
        XCTAssertNotNil(manifest.conversations.first?.hash)
    }
}
