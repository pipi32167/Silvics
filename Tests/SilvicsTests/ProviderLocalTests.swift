import XCTest
@testable import Silvics

/// 本地服务（magpie / Ollama）与模型列表。
final class ProviderLocalTests: XCTestCase {
    private var defaults: UserDefaults!
    private var secrets: InMemorySecretStore!
    private var service: ProviderService!
    private let suiteName = "silvics.tests.providers.local"

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

    private func localConfig() -> ProviderConfig {
        var config = ProviderConfig(
            name: "magpie（本地）", kind: .openAICompatible,
            baseURL: "http://127.0.0.1:3425/v1",
            chatModel: "auto/deepseek-v4.1-flash"
        )
        config.requiresKey = false
        return config
    }

    func testLocalProviderNeedsNoKey() {
        let config = localConfig()
        XCTAssertTrue(service.upsert(config).isEmpty)
        service.bind(.chat, to: config.id)

        XCTAssertNil(service.unavailableReason(.chat))
        let effective = service.effective(.chat)
        XCTAssertNotNil(effective, "免密钥服务不填 key 也应可用")
        XCTAssertEqual(effective?.key, "")
    }

    func testRemoteProviderStillNeedsKey() {
        let config = ProviderConfig(name: "OpenAI", kind: .openAICompatible,
                                    baseURL: "https://api.openai.com/v1", chatModel: "m")
        service.upsert(config)
        service.bind(.chat, to: config.id)
        XCTAssertEqual(service.unavailableReason(.chat), "《OpenAI》还没填密钥")
    }

    func testLocalPresets() throws {
        let magpie = try XCTUnwrap(ProviderPresets.named("magpie（本地）"))
        XCTAssertFalse(magpie.requiresKey)
        XCTAssertEqual(magpie.baseURL, "http://127.0.0.1:3425/v1")
        XCTAssertEqual(magpie.chatModel, "auto/deepseek-v4.1-flash")
        XCTAssertTrue(magpie.embeddingModel.isEmpty, "magpie 不提供向量模型")

        let ollama = try XCTUnwrap(ProviderPresets.named("Ollama（本地）"))
        XCTAssertFalse(ollama.requiresKey)
    }

    func testRequiresKeySurvivesRoundTrip() throws {
        let config = localConfig()
        service.upsert(config)
        let data = try XCTUnwrap(service.exportJSON())
        let decoded = try JSONDecoder().decode(ProviderSettings.self, from: data)
        XCTAssertFalse(decoded.providers[0].requiresKey)
    }

    func testRequestOmitsAuthWhenNoKey() throws {
        let request = try ProviderProbe.request(config: localConfig(), key: "", role: .chat).get()
        XCTAssertNil(request.headers["Authorization"], "免密钥服务不能发空 Bearer")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
    }
}

final class ProviderModelsTests: XCTestCase {

    func testParseMagpieShape() {
        let json = #"{"data":[{"id":"auto/deepseek-v4.1-flash","magpie_label":"DeepSeek V4.1 Flash · routing group"},{"id":"opencode-go/deepseek-v4-pro","display_name":"DeepSeek V4 Pro"}]}"#
        let models = ProviderModels.parse(Data(json.utf8))
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0].id, "auto/deepseek-v4.1-flash")
        XCTAssertEqual(models[0].label, "DeepSeek V4.1 Flash · routing group")
        XCTAssertEqual(models[1].label, "DeepSeek V4 Pro")
    }

    func testParseDedupesAndSorts() {
        let models = ProviderModels.parse(Data(#"{"data":[{"id":"b"},{"id":"a"},{"id":"b"}]}"#.utf8))
        XCTAssertEqual(models.map(\.id), ["a", "b"])
        XCTAssertEqual(models[0].label, "a", "没有标签时用 id 当标签")
    }

    func testParseBareArrayAndModelsKey() {
        XCTAssertEqual(ProviderModels.parse(Data(#"[{"id":"x"}]"#.utf8)).map(\.id), ["x"])
        XCTAssertEqual(ProviderModels.parse(Data(#"{"models":[{"name":"y"}]}"#.utf8)).map(\.id), ["y"])
    }

    func testParseGarbage() {
        XCTAssertTrue(ProviderModels.parse(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(ProviderModels.parse(Data(#"{"data":[]}"#.utf8)).isEmpty)
    }

    func testRequestUsesModelsEndpoint() {
        let url = URL(string: "http://127.0.0.1:3425/v1")!
        let request = ProviderModels.request(baseURL: url, key: "")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:3425/v1/models")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }
}
