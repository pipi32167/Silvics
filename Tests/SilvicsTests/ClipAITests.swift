import XCTest
@testable import Silvics

final class ClipSettingsTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "silvics-clip-settings-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testDefaults() {
        let settings = ClipSettings()
        XCTAssertTrue(settings.autoSummarize)
        XCTAssertEqual(settings.titleStrategy, .smart)
        XCTAssertEqual(settings.summaryLimit, 300)
        XCTAssertEqual(settings.targetTagCount, 4)
        XCTAssertEqual(settings.fetchTimeout, 15)
        XCTAssertTrue(settings.markReadOnOpen)
    }

    func testMissingFieldsUseDefaults() throws {
        let json = #"{"autoSummarize":false,"fetchTimeout":30}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ClipSettings.self, from: json)
        XCTAssertFalse(decoded.autoSummarize)
        XCTAssertEqual(decoded.fetchTimeout, 30)
        XCTAssertEqual(decoded.titleStrategy, .smart)
        XCTAssertEqual(decoded.summaryLimit, 300)
    }

    func testOutOfRangeValuesAreClamped() throws {
        let json = #"{"summaryLimit":999,"targetTagCount":9,"fetchTimeout":1}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ClipSettings.self, from: json)
        XCTAssertEqual(decoded.summaryLimit, 300)
        XCTAssertEqual(decoded.targetTagCount, 4)
        XCTAssertEqual(decoded.fetchTimeout, 15)
    }

    func testSaveLoadAndReset() {
        var settings = ClipSettings()
        settings.autoSummarize = false
        settings.titleStrategy = .never
        settings.save(to: defaults)

        let loaded = ClipSettings.load(from: defaults)
        XCTAssertFalse(loaded.autoSummarize)
        XCTAssertEqual(loaded.titleStrategy, .never)

        ClipSettings.clear(from: defaults)
        XCTAssertEqual(ClipSettings.load(from: defaults), ClipSettings())
    }
}

final class ClipTagPolicyTests: XCTestCase {

    func testPrefersExistingSpelling() {
        let outcome = ClipTagPolicy.apply(
            proposed: ["机器学习", "笔记"],
            existing: ["机器学习", "笔记"],
            target: 4
        )
        XCTAssertEqual(outcome.tags, ["机器学习", "笔记"])
    }

    func testNormalizesCaseAndFullWidth() {
        let outcome = ClipTagPolicy.apply(
            proposed: ["ＭＡＣ", "mac"],
            existing: ["Mac"],
            target: 4
        )
        XCTAssertEqual(outcome.tags, ["Mac"], "全角与大小写归一到已有写法")
    }

    func testNormalizesEnglishPlural() {
        let outcome = ClipTagPolicy.apply(
            proposed: ["note"],
            existing: ["notes"],
            target: 4
        )
        XCTAssertEqual(outcome.tags, ["notes"])
    }

    func testCapsNewTagsAtTwo() {
        let outcome = ClipTagPolicy.apply(
            proposed: ["甲甲", "乙乙", "丙丙", "丁丁"],
            existing: [],
            target: 4
        )
        XCTAssertEqual(outcome.tags, ["甲甲", "乙乙"])
        XCTAssertTrue(outcome.warnings.contains { $0.contains("丢弃") })
    }

    func testSanitizesIllegalCharacters() {
        XCTAssertEqual(ClipTagPolicy.sanitize("#机器 学习!"), "机器学习")
        XCTAssertEqual(ClipTagPolicy.sanitize("a-b_c/d"), "a-b_c/d")
    }

    func testRejectsTooShortOrTooLong() {
        XCTAssertNil(ClipTagPolicy.sanitize("短"))
        XCTAssertNil(ClipTagPolicy.sanitize(String(repeating: "长", count: 13)))
    }

    func testDeduplicates() {
        let outcome = ClipTagPolicy.apply(proposed: ["记忆", "#记忆", "记忆"], existing: [], target: 4)
        XCTAssertEqual(outcome.tags, ["记忆"])
    }

    func testWarnsWhenLessThanThree() {
        let outcome = ClipTagPolicy.apply(proposed: ["记忆"], existing: [], target: 4)
        XCTAssertTrue(outcome.warnings.contains { $0.contains("手动补") })
    }

    func testTrimsToTarget() {
        let outcome = ClipTagPolicy.apply(
            proposed: ["甲甲", "乙乙", "丙丙", "丁丁", "戊戊"],
            existing: ["甲甲", "乙乙", "丙丙", "丁丁", "戊戊"],
            target: 3
        )
        XCTAssertEqual(outcome.tags.count, 3)
    }
}

final class ClipAIServiceTests: XCTestCase {

    private func request(body: String = "正文内容", existing: [String] = []) -> ClipAIRequest {
        ClipAIRequest(
            sourceTitle: "原文标题",
            site: "少数派",
            body: body,
            existingTags: existing,
            summaryLimit: 300,
            tagCount: 4
        )
    }

    func testMessagesCarryCandidatesAndLimits() {
        let messages = ClipAIService.messages(for: request(existing: ["记忆", "学习方法"]))
        let user = messages.first { $0.role == "user" }?.content ?? ""
        XCTAssertTrue(messages.first?.content.contains("不可信数据") ?? false)
        XCTAssertTrue(user.contains("记忆、学习方法"))
        XCTAssertTrue(user.contains("目标标签数：4"))
        XCTAssertTrue(user.contains("摘要不超过 300 字"))
    }

    func testTruncatesLongBodyWithMarker() {
        let body = String(repeating: "甲", count: 20_000)
        let messages = ClipAIService.messages(for: request(body: body))
        let user = messages.last?.content ?? ""
        XCTAssertTrue(user.contains("中间省略"))
        XCTAssertFalse(user.contains(body), "不能把全文塞给模型")
        XCTAssertLessThan(user.count, 14_000)
    }

    func testParsesFencedJSON() {
        let raw = """
        ```json
        {"title":"标题","summary":"这是一段足够长的摘要内容，用于通过校验。","tags":["记忆"]}
        ```
        """
        let parsed = ClipAIService.parse(raw)
        XCTAssertEqual(parsed?.title, "标题")
        XCTAssertEqual(parsed?.tags, ["记忆"])
    }

    func testParsesJSONWithProseAround() {
        let raw = "好的，结果如下：{\"title\":\"标题\",\"summary\":\"摘要\",\"tags\":[\"a\"]} 希望有帮助。"
        XCTAssertEqual(ClipAIService.parse(raw)?.title, "标题")
    }

    func testRejectsInvalidJSON() {
        XCTAssertNil(ClipAIService.parse("模型说了很多话，但没有 JSON"))
    }

    func testSummaryTooShortIsRejected() {
        let suggestion = ClipSuggestion(title: "标题", summary: "太短", tags: [])
        XCTAssertNil(ClipAIService.validated(suggestion, summaryLimit: 300))
    }

    func testSummaryIsTruncatedToLimit() {
        let long = String(repeating: "字", count: 400)
        let validated = ClipAIService.validated(ClipSuggestion(summary: long), summaryLimit: 150)
        XCTAssertEqual(validated?.summary.count, 151, "150 字加省略号")
    }

    func testFinalizeSmartPrefersSourceTitle() {
        var draft = ClipDraft(title: "", sourceTitle: "原文标题", site: "少数派", body: "正文")
        let suggestion = ClipSuggestion(title: "模型标题", summary: "这是一段足够长的摘要内容，用于通过校验。", tags: ["记忆"])
        let result = ClipAIService.finalize(
            draft: draft,
            suggestion: suggestion,
            settings: ClipSettings(),
            existingTags: ["记忆"],
            isTaken: { _ in false }
        )
        XCTAssertEqual(result.draft.title, "原文标题")
        XCTAssertEqual(result.draft.summary, suggestion.summary)
        XCTAssertEqual(result.draft.tags, ["记忆"])
        XCTAssertEqual(result.draft.aiState, .done)
        draft.title = ""
    }

    func testFinalizeAlwaysModelUsesModelTitle() {
        var settings = ClipSettings()
        settings.titleStrategy = .alwaysModel
        let draft = ClipDraft(title: "", sourceTitle: "首页 - 站点", site: "", body: "正文")
        let suggestion = ClipSuggestion(title: "真正的文章标题", summary: "这是一段足够长的摘要内容，用于通过校验。", tags: [])
        let result = ClipAIService.finalize(
            draft: draft,
            suggestion: suggestion,
            settings: settings,
            existingTags: [],
            isTaken: { _ in false }
        )
        XCTAssertEqual(result.draft.title, "真正的文章标题")
    }

    func testFinalizeNeverIgnoresModelTitle() {
        var settings = ClipSettings()
        settings.titleStrategy = .never
        let draft = ClipDraft(title: "", sourceTitle: "", site: "", body: "# 正文里的标题\n\n正文")
        let suggestion = ClipSuggestion(title: "模型标题", summary: "这是一段足够长的摘要内容，用于通过校验。", tags: [])
        let result = ClipAIService.finalize(
            draft: draft,
            suggestion: suggestion,
            settings: settings,
            existingTags: [],
            isTaken: { _ in false }
        )
        XCTAssertEqual(result.draft.title, "正文里的标题")
    }

    func testFinalizeWithoutSuggestionMarksPendingOrFailed() {
        let draft = ClipDraft(title: "", sourceTitle: "原文标题", site: "", body: "正文")
        var settings = ClipSettings()
        settings.autoSummarize = false
        XCTAssertEqual(
            ClipAIService.finalize(draft: draft, suggestion: nil, settings: settings, existingTags: [], isTaken: { _ in false }).draft.aiState,
            .pending
        )
        settings.autoSummarize = true
        XCTAssertEqual(
            ClipAIService.finalize(draft: draft, suggestion: nil, settings: settings, existingTags: [], isTaken: { _ in false }).draft.aiState,
            .failed
        )
    }
}

final class ClipFetchServiceTests: XCTestCase {

    func testBuildsRequestForHTTP() throws {
        guard case .success(let request) = ClipFetchService.request(for: "https://example.com/a", timeout: 15) else {
            return XCTFail("应该能拼出请求")
        }
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/a")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.timeoutInterval, 15)
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.contains("Macintosh") ?? false)
    }

    func testRejectsNonHTTPScheme() {
        guard case .failure(let error) = ClipFetchService.request(for: "file:///etc/passwd", timeout: 15) else {
            return XCTFail("应该被拒")
        }
        XCTAssertEqual(error, .blockedScheme("file"))
    }

    func testRejectsBadURL() {
        guard case .failure(let error) = ClipFetchService.request(for: "不是地址", timeout: 15) else {
            return XCTFail("应该被拒")
        }
        XCTAssertEqual(error, .badURL)
    }

    func testErrorMessagesAreReadable() {
        XCTAssertNotNil(ClipFetchError.timedOut.errorDescription)
        XCTAssertNotNil(ClipFetchError.http(403).errorDescription)
        XCTAssertFalse(ClipFetchError.tooLarge.errorDescription?.isEmpty ?? true)
    }
}

final class ClipIngestTests: XCTestCase {

    func testBuildsDraftFromPage() throws {
        let html = "<html><head><meta property=\"og:site_name\" content=\"少数派\"></head><body><article><p>正文段落。</p></article></body></html>"
        let page = ClipPage(url: URL(string: "https://example.com/a")!, html: html)
        let draft = try ClipIngest.draft(fromPage: page)
        XCTAssertEqual(draft.url, "https://example.com/a")
        XCTAssertEqual(draft.site, "少数派")
        XCTAssertEqual(draft.body, "正文段落。")
    }

    func testEmptyPageThrows() {
        let page = ClipPage(url: URL(string: "https://example.com")!, html: "<html><body></body></html>")
        XCTAssertThrowsError(try ClipIngest.draft(fromPage: page))
    }

    func testShortBodyWarning() {
        XCTAssertNotNil(ClipIngest.shortBodyWarning("太短"))
        XCTAssertNil(ClipIngest.shortBodyWarning(String(repeating: "长", count: 300)))
    }
}
