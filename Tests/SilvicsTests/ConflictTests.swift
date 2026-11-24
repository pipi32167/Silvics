import XCTest
@testable import Silvics

/// 拦截 URLSession 请求，返回固定响应。
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (status, data) = responder(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }
}

final class ChatClientTests: XCTestCase {

    private func openAIConfig() -> ProviderConfig {
        ProviderConfig(name: "magpie（本地）", kind: .openAICompatible,
                       baseURL: "http://127.0.0.1:3425/v1",
                       chatModel: "auto/deepseek-v4.1-flash", requiresKey: false)
    }

    func testOpenAIRequestShape() throws {
        let request = try ChatClient.request(
            config: openAIConfig(), key: "",
            messages: [ChatMessage(role: "system", content: "s"), ChatMessage(role: "user", content: "u")]
        ).get()

        XCTAssertEqual(request.url.absoluteString, "http://127.0.0.1:3425/v1/chat/completions")
        XCTAssertNil(request.headers["Authorization"])
        let body = try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        XCTAssertEqual(body?["model"] as? String, "auto/deepseek-v4.1-flash")
        XCTAssertEqual((body?["messages"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(body?["temperature"] as? Int, 0)
    }

    func testAnthropicSplitsSystemPrompt() throws {
        var config = openAIConfig()
        config.kind = .anthropic
        config.baseURL = "https://api.anthropic.com"
        let request = try ChatClient.request(
            config: config, key: "k",
            messages: [ChatMessage(role: "system", content: "s"), ChatMessage(role: "user", content: "u")]
        ).get()

        XCTAssertEqual(request.headers["x-api-key"], "k")
        let body = try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        XCTAssertEqual(body?["system"] as? String, "s", "system 要单独放，不能留在 messages 里")
        XCTAssertEqual((body?["messages"] as? [[String: Any]])?.count, 1)
    }

    func testGeminiRequestShape() throws {
        var config = openAIConfig()
        config.kind = .gemini
        config.baseURL = "https://generativelanguage.googleapis.com"
        config.chatModel = "gemini-2.0-flash"
        let request = try ChatClient.request(
            config: config, key: "g",
            messages: [ChatMessage(role: "user", content: "u"), ChatMessage(role: "assistant", content: "a")]
        ).get()

        XCTAssertTrue(request.url.absoluteString.contains(":generateContent"))
        XCTAssertTrue(request.url.absoluteString.contains("key=g"))
        let body = try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        let contents = body?["contents"] as? [[String: Any]]
        XCTAssertEqual(contents?.first?["role"] as? String, "user")
        XCTAssertEqual(contents?.last?["role"] as? String, "model", "assistant 在 Gemini 里叫 model")
    }

    func testParseContentForEachKind() {
        let openAI = Data(#"{"choices":[{"message":{"content":"hi"}}]}"#.utf8)
        XCTAssertEqual(ChatClient.parseContent(kind: .openAICompatible, data: openAI), "hi")

        let anthropic = Data(#"{"content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]}"#.utf8)
        XCTAssertEqual(ChatClient.parseContent(kind: .anthropic, data: anthropic), "ab")

        let gemini = Data(#"{"candidates":[{"content":{"parts":[{"text":"g"}]}}]}"#.utf8)
        XCTAssertEqual(ChatClient.parseContent(kind: .gemini, data: gemini), "g")

        XCTAssertNil(ChatClient.parseContent(kind: .openAICompatible, data: Data("{}".utf8)))
    }

    func testCompleteReturnsContent() async throws {
        StubURLProtocol.responder = { _ in
            (200, Data(#"{"choices":[{"message":{"content":"合并好了"}}]}"#.utf8))
        }
        let result = await ChatClient.complete(
            config: openAIConfig(), key: "", messages: [ChatMessage(role: "user", content: "u")],
            session: StubURLProtocol.makeSession()
        )
        XCTAssertEqual(try result.get(), "合并好了")
    }

    func testCompleteMapsHTTPError() async {
        StubURLProtocol.responder = { _ in
            (401, Data(#"{"error":{"message":"bad key"}}"#.utf8))
        }
        let result = await ChatClient.complete(
            config: openAIConfig(), key: "", messages: [ChatMessage(role: "user", content: "u")],
            session: StubURLProtocol.makeSession()
        )
        guard case .failure(let error) = result else { return XCTFail("应当失败") }
        XCTAssertTrue(error.message.contains("密钥无效"))
        XCTAssertTrue(error.message.contains("bad key"))
    }
}

final class ConflictResolverTests: XCTestCase {

    private let base = "第一段：基线。\n第二段：原句。\n第三段：结尾。"
    private let ours = "第一段：基线。\n第二段：改成每天 20 分钟。\n第三段：结尾。"
    private let theirs = "第一段：基线。\n第二段：改成总时长相同才行。\n第三段：结尾。"

    private var conflict: VaultConflict {
        VaultConflict(noteId: "n1", title: "测试笔记", base: base, ours: ours, theirs: theirs)
    }

    func testPromptCarriesAllThreeVersions() {
        let text = ConflictResolver.messages(for: conflict).map(\.content).joined(separator: "\n")
        XCTAssertTrue(text.contains("原句"))
        XCTAssertTrue(text.contains("每天 20 分钟"))
        XCTAssertTrue(text.contains("总时长相同"))
        XCTAssertTrue(text.contains("测试笔记"))
        let userPrompt = ConflictResolver.userPrompt(for: conflict)
        XCTAssertFalse(userPrompt.contains("<<<<<<<"), "喂给模型的正文里不要出现冲突标记")
    }

    func testCleanStripsFenceAndPreamble() {
        let raw = "```markdown\n以下是合并后的正文：合并好了\n```"
        XCTAssertEqual(ConflictResolver.clean(raw), "合并好了")
    }

    /// 模型会把输入里的分隔标记照抄回来，必须逐行丢掉。
    func testCleanStripsEchoedScaffolding() {
        let raw = """
        标题：测试笔记

        【共同基线】
        第一段：基线。

        【本机版本】
        第二段：A。

        【远端版本】
        第二段：B。

        第二段：两者都保留。
        待定：需要确认口径。
        """
        let cleaned = ConflictResolver.clean(raw, title: "测试笔记")
        XCTAssertFalse(cleaned.contains("【"))
        XCTAssertFalse(cleaned.contains("标题："))
        XCTAssertTrue(cleaned.contains("第二段：两者都保留。"))
        XCTAssertTrue(cleaned.contains("待定："))
    }

    func testValidateRejectsBadOutput() {
        XCTAssertNotNil(ConflictResolver.validate("", conflict: conflict), "空内容要拒绝")
        XCTAssertNotNil(ConflictResolver.validate("<<<<<<< ours", conflict: conflict), "冲突标记要拒绝")
        XCTAssertNotNil(ConflictResolver.validate(ours, conflict: conflict), "与本机相同没有意义")
        let long = String(repeating: "很长的一行。", count: 500)
        XCTAssertNotNil(ConflictResolver.validate(long, conflict: conflict), "异常长要拒绝")
        XCTAssertNil(ConflictResolver.validate("合并后的正文", conflict: conflict))
    }

    func testResolveSuccess() async throws {
        StubURLProtocol.responder = { _ in
            (200, Data(#"{"choices":[{"message":{"content":"```\n第二段：两者都保留。\n```"}}]}"#.utf8))
        }
        let result = await ConflictResolver.resolve(
            conflict, provider: config(), key: "", session: StubURLProtocol.makeSession()
        )
        XCTAssertEqual(try result.get(), "第二段：两者都保留。")
    }

    func testResolveRejectsMarkers() async {
        StubURLProtocol.responder = { _ in
            (200, Data(#"{"choices":[{"message":{"content":"<<<<<<< HEAD\nx\n"}}]}"#.utf8))
        }
        let result = await ConflictResolver.resolve(
            conflict, provider: config(), key: "", session: StubURLProtocol.makeSession()
        )
        guard case .failure(let error) = result else { return XCTFail("应当拒绝") }
        XCTAssertTrue(error.message.contains("冲突标记"))
    }

    func testResolvePropagatesNetworkError() async {
        StubURLProtocol.responder = { _ in (500, Data("boom".utf8)) }
        let result = await ConflictResolver.resolve(
            conflict, provider: config(), key: "", session: StubURLProtocol.makeSession()
        )
        guard case .failure(let error) = result else { return XCTFail("应当失败") }
        XCTAssertTrue(error.message.contains("500") || error.message.contains("服务端"))
    }

    private func config() -> ProviderConfig {
        ProviderConfig(name: "magpie（本地）", kind: .openAICompatible,
                       baseURL: "http://127.0.0.1:3425/v1",
                       chatModel: "auto/deepseek-v4.1-flash", requiresKey: false)
    }
}
