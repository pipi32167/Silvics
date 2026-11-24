import XCTest
@testable import Silvics

final class ProviderConfigTests: XCTestCase {

    func testPresetsAreComplete() {
        XCTAssertEqual(ProviderPresets.all.count, 13)
        XCTAssertEqual(Set(ProviderPresets.all.map(\.name)).count, 13, "预设名不能重复")
        let custom = ProviderPresets.named("自定义")
        XCTAssertNotNil(custom)
        XCTAssertTrue(custom?.isCustom ?? false)
        XCTAssertEqual(custom?.baseURL, "")
    }

    func testPresetCarriesKindAndModels() {
        let openAI = ProviderPresets.named("OpenAI")!
        XCTAssertEqual(openAI.kind, .openAICompatible)
        XCTAssertFalse(openAI.chatModel.isEmpty)
        XCTAssertFalse(openAI.embeddingModel.isEmpty)

        let anthropic = ProviderPresets.named("Anthropic")!
        XCTAssertEqual(anthropic.kind, .anthropic)
        XCTAssertTrue(anthropic.embeddingModel.isEmpty, "Anthropic 没有向量模型")
    }

    func testBaseURLNormalization() {
        let config = ProviderConfig(name: "x", kind: .openAICompatible, baseURL: "api.example.com/v1/")
        XCTAssertEqual(config.normalizedBaseURL?.absoluteString, "https://api.example.com/v1")

        let local = ProviderConfig(name: "x", kind: .openAICompatible, baseURL: "http://127.0.0.1:11434/v1")
        XCTAssertEqual(local.normalizedBaseURL?.absoluteString, "http://127.0.0.1:11434/v1")

        let bad = ProviderConfig(name: "x", kind: .openAICompatible, baseURL: "ftp://example.com")
        XCTAssertNil(bad.normalizedBaseURL)
    }

    func testCapabilityFlags() {
        var config = ProviderConfig(name: "x", kind: .openAICompatible, baseURL: "https://a.com/v1", chatModel: "m")
        XCTAssertTrue(config.providesChat)
        XCTAssertFalse(config.providesEmbedding)

        config.embeddingModel = "e"
        XCTAssertTrue(config.providesEmbedding)

        config.enabled = false
        XCTAssertFalse(config.providesChat)
        XCTAssertFalse(config.providesEmbedding)
    }
}

final class ProviderServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var secrets: InMemorySecretStore!
    private var service: ProviderService!
    private let suiteName = "silvics.tests.providers"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        secrets = InMemorySecretStore()
        service = ProviderService(secrets: secrets, defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeConfig(name: String = "OpenAI", baseURL: String = "https://api.openai.com/v1") -> ProviderConfig {
        ProviderConfig(name: name, kind: .openAICompatible, baseURL: baseURL, chatModel: "gpt-4o-mini")
    }

    // MARK: - 校验

    func testValidationRejectsBadInput() {
        var config = makeConfig()
        config.name = "  "
        XCTAssertTrue(service.validate(config).contains { $0.contains("名称") })

        var badURL = makeConfig()
        badURL.baseURL = "not a url"
        XCTAssertTrue(service.validate(badURL).contains { $0.contains("http") })

        var noModel = makeConfig()
        noModel.chatModel = ""
        XCTAssertTrue(service.validate(noModel).contains { $0.contains("模型名") })

        var anthropicEmbedding = ProviderConfig(name: "A", kind: .anthropic,
                                                baseURL: "https://api.anthropic.com",
                                                chatModel: "claude", embeddingModel: "e")
        XCTAssertTrue(service.validate(anthropicEmbedding).contains { $0.contains("Anthropic") })
    }

    func testValidationRejectsDuplicate() {
        XCTAssertTrue(service.upsert(makeConfig()).isEmpty)
        let duplicate = makeConfig(name: "另一个名字", baseURL: "https://api.openai.com/v1/")
        XCTAssertTrue(service.validate(duplicate).contains { $0.contains("已经添加过") })
    }

    // MARK: - 增删与密钥

    func testUpsertStoresSecretAndMasks() {
        var config = makeConfig()
        XCTAssertTrue(service.upsert(config, secret: "sk-abcdefgh1234").isEmpty)
        XCTAssertEqual(service.settings.providers.count, 1)
        XCTAssertEqual(service.maskedSecret(for: config.id), "••••1234")
        XCTAssertTrue(service.hasSecret(for: config.id))

        // 覆盖写
        try? service.setSecret("sk-newkey9999", for: config.id)
        XCTAssertEqual(service.maskedSecret(for: config.id), "••••9999")
    }

    func testDeleteClearsKeyAndBindings() {
        let config = makeConfig()
        service.upsert(config, secret: "k")
        service.bind(.chat, to: config.id)
        service.bind(.embedding, to: config.id)
        XCTAssertNotNil(service.settings.chatProviderId)

        service.delete(config.id)
        XCTAssertTrue(service.settings.providers.isEmpty)
        XCTAssertNil(service.settings.chatProviderId)
        XCTAssertNil(service.settings.embeddingProviderId)
        XCTAssertTrue(secrets.allAccounts().isEmpty, "删除后钥匙串项要清掉")
    }

    // MARK: - 绑定与降级

    func testEffectiveRequiresModelAndKey() {
        let config = makeConfig()
        service.upsert(config)
        service.bind(.chat, to: config.id)

        XCTAssertNil(service.effective(.chat), "没有 key 时不可用")
        XCTAssertEqual(service.unavailableReason(.chat), "《OpenAI》还没填密钥")

        try? service.setSecret("k", for: config.id)
        XCTAssertNotNil(service.effective(.chat))

        service.bind(.embedding, to: config.id)
        XCTAssertNil(service.effective(.embedding), "没填向量模型时不可用")
        XCTAssertEqual(service.unavailableReason(.embedding), "《OpenAI》没有可用的向量模型")
    }

    func testUnavailableReasonWhenUnbound() {
        XCTAssertEqual(service.unavailableReason(.chat), "未选择服务商")
    }

    // MARK: - 导出导入

    func testExportExcludesSecret() throws {
        let config = makeConfig()
        service.upsert(config, secret: "sk-secret-value")
        let data = try XCTUnwrap(service.exportJSON())
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(text.contains("sk-secret-value"), "导出不能含密钥")
        XCTAssertTrue(text.contains("api.openai.com"))

        let decoded = try JSONDecoder().decode(ProviderSettings.self, from: data)
        XCTAssertEqual(decoded.providers.count, 1)
        XCTAssertEqual(decoded.providers[0].id, config.id)
    }

    func testImportMergesWithoutDuplicates() throws {
        let config = makeConfig()
        service.upsert(config, secret: "k")
        let data = try XCTUnwrap(service.exportJSON())

        // 同一份文件再导入一次，不应重复
        let messages = service.importJSON(data)
        XCTAssertEqual(service.settings.providers.count, 1)
        XCTAssertTrue(messages.isEmpty || messages.contains { $0.contains("跳过") })

        // 导入另一个服务
        var other = ProviderConfig(name: "Ollama", kind: .openAICompatible,
                                   baseURL: "http://127.0.0.1:11434/v1", chatModel: "qwen2.5:7b")
        other.id = UUID()
        other.keyAccount = "provider-\(other.id.uuidString)"
        service.bind(.chat, to: config.id)   // 已有绑定
        var payload = ProviderSettings()
        payload.providers = [other]
        payload.chatProviderId = other.id
        let payloadData = try JSONEncoder().encode(payload)

        XCTAssertTrue(service.importJSON(payloadData).isEmpty)
        XCTAssertEqual(service.settings.providers.count, 2)
        XCTAssertEqual(service.settings.chatProviderId, config.id, "已有绑定不被覆盖")
    }

    func testImportRejectsGarbage() {
        XCTAssertEqual(service.importJSON(Data("not json".utf8)), ["文件不是合法的 Silvics 配置"])
    }

    // MARK: - 重置与修复

    func testResetAllClearsEverything() {
        let config = makeConfig()
        service.upsert(config, secret: "k")
        service.bind(.chat, to: config.id)
        var appearance = AppearanceSettings()
        appearance.bodySize = 18
        appearance.save(to: defaults)

        service.resetAll(alsoAppearance: true)

        XCTAssertTrue(service.settings.providers.isEmpty)
        XCTAssertTrue(secrets.allAccounts().isEmpty)
        XCTAssertEqual(AppearanceSettings.load(from: defaults), AppearanceSettings())
    }

    func testRepairDropsDanglingBinding() throws {
        var settings = ProviderSettings()
        settings.chatProviderId = UUID()
        let data = try JSONEncoder().encode(settings)
        defaults.set(data, forKey: ProviderSettings.defaultsKey)

        let loaded = ProviderSettings.load(from: defaults)
        XCTAssertNil(loaded.chatProviderId, "指向不存在的服务要清掉")
    }

    func testPersistenceAcrossInstances() {
        let config = makeConfig()
        service.upsert(config)
        service.bind(.chat, to: config.id)

        let reloaded = ProviderService(secrets: secrets, defaults: defaults)
        XCTAssertEqual(reloaded.settings.providers.count, 1)
        XCTAssertEqual(reloaded.settings.chatProviderId, config.id)
    }
}

final class ProviderProbeTests: XCTestCase {

    private func config(kind: ProviderKind = .openAICompatible, baseURL: String = "https://api.example.com/v1") -> ProviderConfig {
        ProviderConfig(name: "t", kind: kind, baseURL: baseURL, chatModel: "chat-1", embeddingModel: "embed-1")
    }

    func testOpenAIChatRequest() throws {
        let request = try ProviderProbe.request(config: config(), key: "sk-1", role: .chat).get()
        XCTAssertEqual(request.url.absoluteString, "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["Authorization"], "Bearer sk-1")

        let body = try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        XCTAssertEqual(body?["model"] as? String, "chat-1")
        XCTAssertEqual(body?["max_tokens"] as? Int, 1)
    }

    func testOpenAIEmbeddingRequest() throws {
        let request = try ProviderProbe.request(config: config(), key: "sk-1", role: .embedding).get()
        XCTAssertEqual(request.url.absoluteString, "https://api.example.com/v1/embeddings")
        let body = try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        XCTAssertEqual(body?["model"] as? String, "embed-1")
    }

    func testAnthropicUsesAPIKeyHeader() throws {
        let request = try ProviderProbe.request(
            config: config(kind: .anthropic, baseURL: "https://api.anthropic.com"),
            key: "ak-1",
            role: .chat
        ).get()
        XCTAssertEqual(request.url.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.headers["x-api-key"], "ak-1")
        XCTAssertEqual(request.headers["anthropic-version"], "2023-06-01")
        XCTAssertNil(request.headers["Authorization"])
    }

    func testAnthropicEmbeddingUnsupported() {
        let result = ProviderProbe.request(
            config: config(kind: .anthropic, baseURL: "https://api.anthropic.com"),
            key: "ak-1",
            role: .embedding
        )
        guard case .failure(let error) = result else { return XCTFail("应当失败") }
        XCTAssertEqual(error, .embeddingUnsupported)
    }

    func testGeminiPutsKeyInQuery() throws {
        let request = try ProviderProbe.request(
            config: config(kind: .gemini, baseURL: "https://generativelanguage.googleapis.com"),
            key: "g-1",
            role: .chat
        ).get()
        XCTAssertTrue(request.url.absoluteString.contains(":generateContent"))
        XCTAssertTrue(request.url.absoluteString.contains("key=g-1"))
    }

    func testMissingModelRejected() {
        var c = config()
        c.chatModel = ""
        c.embeddingModel = ""
        guard case .failure(let error) = ProviderProbe.request(config: c, key: "k", role: .chat) else {
            return XCTFail("应当失败")
        }
        XCTAssertEqual(error, .missingModel)
    }

    func testStatusMapping() {
        XCTAssertEqual(ProviderProbe.explain(status: 401), "密钥无效或已过期")
        XCTAssertEqual(ProviderProbe.explain(status: 404), "地址或模型名不对（404）")
        XCTAssertEqual(ProviderProbe.explain(status: 429), "被限流或额度不足")
        XCTAssertTrue(ProviderProbe.explain(status: 503).contains("服务端错误"))
    }

    func testErrorMessageAndModelExtraction() {
        let body = #"{"error":{"message":"Invalid API key provided"}}"#
        XCTAssertEqual(ProviderProbe.errorMessage(from: body), "Invalid API key provided")
        XCTAssertEqual(ProviderProbe.modelName(from: #"{"model":"gpt-4o-mini"}"#), "gpt-4o-mini")
        XCTAssertEqual(ProviderProbe.modelName(from: #"{"modelVersion":"gemini-1.5"}"#), "gemini-1.5")
        XCTAssertNil(ProviderProbe.modelName(from: "{}"))
    }
}
