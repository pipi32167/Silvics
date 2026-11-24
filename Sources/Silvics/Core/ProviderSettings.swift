import Foundation

/// 服务商协议族。决定请求怎么拼。
enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAICompatible
    case anthropic
    case gemini

    var id: Self { self }

    var title: String {
        switch self {
        case .openAICompatible: return "OpenAI 兼容"
        case .anthropic: return "Anthropic"
        case .gemini: return "Gemini"
        }
    }

    var supportsEmbedding: Bool {
        self != .anthropic
    }
}

/// 一个模型服务配置。密钥不在里面，只在 Keychain。
struct ProviderConfig: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var kind: ProviderKind
    /// 不带尾斜杠；endpoint 由 `ProviderKind` 决定。
    var baseURL: String
    var chatModel: String = ""
    var embeddingModel: String = ""
    var enabled: Bool = true
    var keyAccount: String = ""

    init(
        id: UUID = UUID(),
        name: String,
        kind: ProviderKind,
        baseURL: String,
        chatModel: String = "",
        embeddingModel: String = "",
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.chatModel = chatModel
        self.embeddingModel = embeddingModel
        self.enabled = enabled
        self.keyAccount = "provider-\(id.uuidString)"
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, baseURL, chatModel, embeddingModel, enabled, keyAccount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decodeIfPresent(ProviderKind.self, forKey: .kind) ?? .openAICompatible
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        chatModel = try c.decodeIfPresent(String.self, forKey: .chatModel) ?? ""
        embeddingModel = try c.decodeIfPresent(String.self, forKey: .embeddingModel) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        // 旧数据可能没存 account，按 id 补
        let stored = try c.decodeIfPresent(String.self, forKey: .keyAccount) ?? ""
        keyAccount = stored.isEmpty ? "provider-\(id.uuidString)" : stored
    }

    var isConfigured: Bool { !chatModel.isEmpty || !embeddingModel.isEmpty }
    var providesChat: Bool { enabled && !chatModel.isEmpty }
    var providesEmbedding: Bool { enabled && kind.supportsEmbedding && !embeddingModel.isEmpty }

    /// baseURL 归一化：去尾斜杠；没有协议头时补 `https://`；非 http(s) 协议直接判错。
    var normalizedBaseURL: URL? {
        var raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        raw = raw.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)

        // 自己带了协议头就只认 http / https，避免把 ftp:// 补成 https://ftp://
        if let scheme = raw.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*://"#, options: .regularExpression) {
            let prefix = raw[scheme].dropLast(3).lowercased()
            guard prefix == "http" || prefix == "https" else { return nil }
        } else {
            raw = "https://" + raw
        }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }
}

/// 预设。代码里的只读表：用户改预设即另存为自定义，不覆盖预设。
struct ProviderPreset: Identifiable, Equatable, Sendable {
    var id: String { name }
    var name: String
    var kind: ProviderKind
    var baseURL: String
    var chatModel: String
    var embeddingModel: String
    /// 需要用户自己填 baseURL（自定义）。
    var isCustom: Bool = false

    func config() -> ProviderConfig {
        ProviderConfig(
            name: name,
            kind: kind,
            baseURL: baseURL,
            chatModel: chatModel,
            embeddingModel: embeddingModel
        )
    }
}

enum ProviderPresets {
    static let all: [ProviderPreset] = [
        .init(name: "OpenAI", kind: .openAICompatible,
              baseURL: "https://api.openai.com/v1",
              chatModel: "gpt-4o-mini", embeddingModel: "text-embedding-3-large"),
        .init(name: "Anthropic", kind: .anthropic,
              baseURL: "https://api.anthropic.com",
              chatModel: "claude-sonnet-4-20250514", embeddingModel: ""),
        .init(name: "DeepSeek", kind: .openAICompatible,
              baseURL: "https://api.deepseek.com/v1",
              chatModel: "deepseek-chat", embeddingModel: ""),
        .init(name: "Moonshot", kind: .openAICompatible,
              baseURL: "https://api.moonshot.cn/v1",
              chatModel: "moonshot-v1-8k", embeddingModel: ""),
        .init(name: "阿里百炼", kind: .openAICompatible,
              baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
              chatModel: "qwen-plus", embeddingModel: "text-embedding-v3"),
        .init(name: "智谱", kind: .openAICompatible,
              baseURL: "https://open.bigmodel.cn/api/paas/v4",
              chatModel: "glm-4-flash", embeddingModel: "embedding-3"),
        .init(name: "硅基流动", kind: .openAICompatible,
              baseURL: "https://api.siliconflow.cn/v1",
              chatModel: "Qwen/Qwen2.5-7B-Instruct", embeddingModel: "BAAI/bge-m3"),
        .init(name: "OpenRouter", kind: .openAICompatible,
              baseURL: "https://openrouter.ai/api/v1",
              chatModel: "openai/gpt-4o-mini", embeddingModel: ""),
        .init(name: "Jina", kind: .openAICompatible,
              baseURL: "https://api.jina.ai/v1",
              chatModel: "", embeddingModel: "jina-embeddings-v3"),
        .init(name: "Voyage", kind: .openAICompatible,
              baseURL: "https://api.voyageai.com/v1",
              chatModel: "", embeddingModel: "voyage-3"),
        .init(name: "Ollama（本地）", kind: .openAICompatible,
              baseURL: "http://127.0.0.1:11434/v1",
              chatModel: "qwen2.5:7b", embeddingModel: "bge-m3"),
        .init(name: "自定义", kind: .openAICompatible,
              baseURL: "", chatModel: "", embeddingModel: "", isCustom: true),
    ]

    static func named(_ name: String) -> ProviderPreset? {
        all.first { $0.name == name }
    }
}

/// 用途绑定。
enum ProviderRole: String, CaseIterable, Identifiable {
    case chat
    case embedding

    var id: Self { self }

    var title: String {
        switch self {
        case .chat: return "概念线索（L3）"
        case .embedding: return "相关笔记（L4）"
        }
    }

    var hint: String {
        switch self {
        case .chat: return "从正文里抽概念，建议新建或建立引用。"
        case .embedding: return "按语义找相近笔记，只给建议。"
        }
    }
}

/// 全部模型服务设置。存 UserDefaults，密钥在 Keychain。
struct ProviderSettings: Codable, Equatable {
    var schemaVersion: Int = 1
    var providers: [ProviderConfig] = []
    var chatProviderId: UUID?
    var embeddingProviderId: UUID?

    static let defaultsKey = "silvics.providers.settings"

    func provider(id: UUID?) -> ProviderConfig? {
        guard let id else { return nil }
        return providers.first { $0.id == id }
    }

    func bound(_ role: ProviderRole) -> ProviderConfig? {
        switch role {
        case .chat: return provider(id: chatProviderId)
        case .embedding: return provider(id: embeddingProviderId)
        }
    }

    // MARK: - 读写

    static func load(from defaults: UserDefaults = .standard) -> ProviderSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(ProviderSettings.self, from: data)
        else { return ProviderSettings() }
        return decoded.repaired()
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    /// 绑定指向了不存在的 provider（被删或数据损坏）时清掉，避免界面空转。
    func repaired() -> ProviderSettings {
        var copy = self
        if copy.provider(id: chatProviderId) == nil { copy.chatProviderId = nil }
        if copy.provider(id: embeddingProviderId) == nil { copy.embeddingProviderId = nil }
        return copy
    }
}
