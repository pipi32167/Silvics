import Foundation

/// 模型服务的读写与校验。密钥走 `SecretStore`，其余进 UserDefaults。
final class ProviderService {
    private(set) var settings: ProviderSettings
    private let secrets: SecretStore
    private let defaults: UserDefaults

    init(secrets: SecretStore = KeychainSecretStore(), defaults: UserDefaults = .standard) {
        self.secrets = secrets
        self.defaults = defaults
        self.settings = ProviderSettings.load(from: defaults)
    }

    // MARK: - 校验

    /// 返回空数组表示通过。错误文案直接给用户看。
    func validate(_ config: ProviderConfig, ignoring id: UUID? = nil) -> [String] {
        var errors: [String] = []

        if config.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("名称不能为空")
        }
        if config.normalizedBaseURL == nil {
            errors.append("服务地址必须是 http(s) 链接")
        }
        if config.chatModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           config.embeddingModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("至少要填一个模型名（对话或向量）")
        }
        if config.kind == .anthropic && !config.embeddingModel.isEmpty {
            errors.append("Anthropic 不提供向量模型，请清空向量模型名")
        }

        let key = Self.duplicateKey(kind: config.kind, baseURL: config.baseURL)
        let duplicate = settings.providers.contains {
            $0.id != (id ?? config.id) && Self.duplicateKey(kind: $0.kind, baseURL: $0.baseURL) == key
        }
        if duplicate {
            errors.append("已经添加过同一个服务（协议 + 地址相同）")
        }
        return errors
    }

    private static func duplicateKey(kind: ProviderKind, baseURL: String) -> String {
        let normalized = baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        return "\(kind.rawValue)|\(normalized)"
    }

    // MARK: - 增删改

    /// 保存一个 provider。`secret` 非 nil 时一并写 Keychain。
    /// - Returns: 校验错误；空数组表示成功。
    @discardableResult
    func upsert(_ config: ProviderConfig, secret: String? = nil) -> [String] {
        var candidate = config
        candidate.name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.baseURL = candidate.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.chatModel = candidate.chatModel.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.embeddingModel = candidate.embeddingModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.keyAccount.isEmpty { candidate.keyAccount = "provider-\(candidate.id.uuidString)" }

        let errors = validate(candidate)
        guard errors.isEmpty else { return errors }

        if let index = settings.providers.firstIndex(where: { $0.id == candidate.id }) {
            settings.providers[index] = candidate
        } else {
            settings.providers.append(candidate)
        }
        if let secret, !secret.isEmpty {
            try? secrets.write(secret, account: candidate.keyAccount)
        }
        persist()
        return []
    }

    /// 删除 provider：一并清 Keychain 与绑定。
    func delete(_ id: UUID) {
        guard let provider = settings.provider(id: id) else { return }
        try? secrets.delete(account: provider.keyAccount)
        settings.providers.removeAll { $0.id == id }
        if settings.chatProviderId == id { settings.chatProviderId = nil }
        if settings.embeddingProviderId == id { settings.embeddingProviderId = nil }
        persist()
    }

    // MARK: - 密钥

    func secret(for id: UUID) -> String? {
        guard let provider = settings.provider(id: id) else { return nil }
        return try? secrets.read(account: provider.keyAccount)
    }

    func hasSecret(for id: UUID) -> Bool {
        guard let value = secret(for: id) else { return false }
        return !value.isEmpty
    }

    /// 只显示后四位，不提供「显示明文」。
    func maskedSecret(for id: UUID) -> String? {
        guard let value = secret(for: id), value.count >= 4 else { return nil }
        return "••••" + value.suffix(4)
    }

    func setSecret(_ secret: String, for id: UUID) throws {
        guard let provider = settings.provider(id: id) else { return }
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try secrets.delete(account: provider.keyAccount)
        } else {
            try secrets.write(trimmed, account: provider.keyAccount)
        }
    }

    // MARK: - 绑定

    func bind(_ role: ProviderRole, to id: UUID?) {
        switch role {
        case .chat: settings.chatProviderId = id
        case .embedding: settings.embeddingProviderId = id
        }
        persist()
    }

    /// 某个用途当前可用的 provider。没有配置、没绑、没 key 都返回 nil。
    func effective(_ role: ProviderRole) -> (config: ProviderConfig, key: String)? {
        guard let config = settings.bound(role) else { return nil }
        switch role {
        case .chat:
            guard config.providesChat else { return nil }
        case .embedding:
            guard config.providesEmbedding else { return nil }
        }
        guard let key = secret(for: config.id), !key.isEmpty else { return nil }
        return (config, key)
    }

    /// 用途不可用的原因，直接显示在界面上。
    func unavailableReason(_ role: ProviderRole) -> String? {
        guard let config = settings.bound(role) else { return "未选择服务商" }
        switch role {
        case .chat where !config.providesChat:
            return "《\(config.name)》没有填对话模型"
        case .embedding where !config.providesEmbedding:
            return "《\(config.name)》没有可用的向量模型"
        default: break
        }
        if !hasSecret(for: config.id) { return "《\(config.name)》还没填密钥" }
        return nil
    }

    // MARK: - 导出与重置

    /// 导出配置（不含密钥）。换机器后重新填一次 key 即可。
    func exportJSON() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(settings)
    }

    /// 导入配置。id 与 keyAccount 保持不变；密钥需要重新填。
    @discardableResult
    func importJSON(_ data: Data) -> [String] {
        guard let incoming = try? JSONDecoder().decode(ProviderSettings.self, from: data) else {
            return ["文件不是合法的 Silvics 配置"]
        }
        var merged = settings
        var skipped = 0
        for config in incoming.providers {
            if merged.providers.contains(where: { $0.id == config.id }) { continue }
            let key = Self.duplicateKey(kind: config.kind, baseURL: config.baseURL)
            if merged.providers.contains(where: { Self.duplicateKey(kind: $0.kind, baseURL: $0.baseURL) == key }) {
                skipped += 1
                continue
            }
            merged.providers.append(config)
        }
        if merged.chatProviderId == nil { merged.chatProviderId = incoming.chatProviderId }
        if merged.embeddingProviderId == nil { merged.embeddingProviderId = incoming.embeddingProviderId }
        settings = merged.repaired()
        persist()

        var messages: [String] = []
        if skipped > 0 { messages.append("跳过 \(skipped) 个重复服务") }
        if settings.chatProviderId == nil, incoming.chatProviderId != nil {
            messages.append("导入的对话绑定指向不存在的服务，已忽略")
        }
        return messages
    }

    /// 恢复全部设置：清 UserDefaults 与全部密钥。
    func resetAll(alsoAppearance: Bool) {
        for provider in settings.providers {
            try? secrets.delete(account: provider.keyAccount)
        }
        // 清理可能残留的孤儿密钥
        for account in secrets.allAccounts() where account.hasPrefix("provider-") {
            try? secrets.delete(account: account)
        }
        settings = ProviderSettings()
        ProviderSettings.clear(from: defaults)
        if alsoAppearance {
            AppearanceSettings.clear(from: defaults)
        }
    }

    private func persist() {
        settings.save(to: defaults)
    }
}
