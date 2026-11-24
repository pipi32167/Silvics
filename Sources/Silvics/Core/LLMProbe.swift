import Foundation

/// 一次探测请求。抽出来是为了单测能断言 URL、方法、请求头与请求体，而不真的发网络请求。
struct ProbeRequest: Equatable {
    var url: URL
    var method: String
    var headers: [String: String]
    var body: Data
}

/// 探测结果。
struct ProbeResult: Equatable {
    var ok: Bool
    /// 给用户看的一句话。
    var message: String
    /// 耗时（毫秒）。
    var latencyMs: Int
    /// 成功时是服务端返回的模型名；失败时是状态码与响应片段。
    var detail: String
}

enum ProviderProbe {

    // MARK: - 拼请求

    static func request(
        config: ProviderConfig,
        key: String,
        role: ProviderRole
    ) -> Result<ProbeRequest, ProviderProbeError> {
        guard let base = config.normalizedBaseURL else {
            return .failure(.badURL)
        }

        switch config.kind {
        case .openAICompatible:
            let path = role == .chat ? "/chat/completions" : "/embeddings"
            let model = role == .chat ? config.chatModel : config.embeddingModel
            guard !model.isEmpty else { return .failure(.missingModel) }
            guard let url = URL(string: base.absoluteString + path) else { return .failure(.badURL) }

            let body: [String: Any] = role == .chat
                ? ["model": model, "messages": [["role": "user", "content": "ping"]], "max_tokens": 1]
                : ["model": model, "input": "ping"]
            guard let data = try? JSONSerialization.data(withJSONObject: body) else {
                return .failure(.encoding)
            }
            return .success(ProbeRequest(
                url: url,
                method: "POST",
                headers: [
                    "Authorization": "Bearer \(key)",
                    "Content-Type": "application/json",
                ],
                body: data
            ))

        case .anthropic:
            guard role == .chat else { return .failure(.embeddingUnsupported) }
            guard !config.chatModel.isEmpty else { return .failure(.missingModel) }
            guard let url = URL(string: base.absoluteString + "/v1/messages") else { return .failure(.badURL) }
            let body: [String: Any] = [
                "model": config.chatModel,
                "max_tokens": 1,
                "messages": [["role": "user", "content": "ping"]],
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: body) else {
                return .failure(.encoding)
            }
            return .success(ProbeRequest(
                url: url,
                method: "POST",
                headers: [
                    "x-api-key": key,
                    "anthropic-version": "2023-06-01",
                    "Content-Type": "application/json",
                ],
                body: data
            ))

        case .gemini:
            let model = role == .chat ? config.chatModel : config.embeddingModel
            guard !model.isEmpty else { return .failure(.missingModel) }
            let action = role == .chat ? "generateContent" : "embedContent"
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            guard let url = URL(string: base.absoluteString + "/v1beta/models/\(model):\(action)?key=\(encodedKey)") else {
                return .failure(.badURL)
            }
            let body: [String: Any] = role == .chat
                ? ["contents": [["parts": [["text": "ping"]]]]]
                : ["content": ["parts": [["text": "ping"]]]]
            guard let data = try? JSONSerialization.data(withJSONObject: body) else {
                return .failure(.encoding)
            }
            return .success(ProbeRequest(
                url: url,
                method: "POST",
                headers: ["Content-Type": "application/json"],
                body: data
            ))
        }
    }

    // MARK: - 发请求

    static func run(
        config: ProviderConfig,
        key: String,
        role: ProviderRole,
        session: URLSession = .shared
    ) async -> ProbeResult {
        let built: ProbeRequest
        switch request(config: config, key: key, role: role) {
        case .success(let request): built = request
        case .failure(let error):
            return ProbeResult(ok: false, message: error.message, latencyMs: 0, detail: "")
        }

        var request = URLRequest(url: built.url)
        request.httpMethod = built.method
        request.httpBody = built.body
        request.timeoutInterval = 10
        for (field, value) in built.headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let started = CFAbsoluteTimeGetCurrent()
        do {
            let (data, response) = try await session.data(for: request)
            let latency = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
            guard let http = response as? HTTPURLResponse else {
                return ProbeResult(ok: false, message: "响应格式不对", latencyMs: latency, detail: "")
            }
            let snippet = String(data: data.prefix(2000), encoding: .utf8) ?? ""

            guard (200..<300).contains(http.statusCode) else {
                return ProbeResult(
                    ok: false,
                    message: explain(status: http.statusCode),
                    latencyMs: latency,
                    detail: "HTTP \(http.statusCode) · \(errorMessage(from: snippet))"
                )
            }

            let model = modelName(from: snippet) ?? (role == .chat ? config.chatModel : config.embeddingModel)
            return ProbeResult(ok: true, message: "连接成功", latencyMs: latency, detail: "模型 \(model)")

        } catch let error as URLError where error.code == .timedOut {
            let latency = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
            return ProbeResult(ok: false, message: "连接超时，检查服务地址或网络", latencyMs: latency, detail: "")
        } catch {
            let latency = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
            return ProbeResult(ok: false, message: "请求失败：\(error.localizedDescription)", latencyMs: latency, detail: "")
        }
    }

    // MARK: - 错误映射

    static func explain(status: Int) -> String {
        switch status {
        case 400: return "请求被拒绝：检查模型名是否可用"
        case 401: return "密钥无效或已过期"
        case 403: return "密钥没有调用权限"
        case 404: return "地址或模型名不对（404）"
        case 429: return "被限流或额度不足"
        case 500...599: return "服务端错误（\(status)），稍后再试"
        default: return "请求失败（HTTP \(status)）"
        }
    }

    /// 从响应里挖 `error.message` 或 `message`，挖不到就给原文前 200 字。
    static func errorMessage(from body: String) -> String {
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                return clip(message)
            }
            if let message = json["message"] as? String {
                return clip(message)
            }
        }
        return clip(body)
    }

    /// 成功后取模型名：OpenAI 在 `model`，Anthropic 在 `model`，Gemini 在 `modelVersion`。
    static func modelName(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let model = json["model"] as? String, !model.isEmpty { return model }
        if let model = json["modelVersion"] as? String, !model.isEmpty { return model }
        return nil
    }

    private static func clip(_ text: String) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return flat.count > 200 ? String(flat.prefix(200)) + "…" : flat
    }
}

enum ProviderProbeError: Error, Equatable {
    case badURL
    case missingModel
    case encoding
    case embeddingUnsupported

    var message: String {
        switch self {
        case .badURL: return "服务地址不合法"
        case .missingModel: return "先填模型名"
        case .encoding: return "请求体拼装失败"
        case .embeddingUnsupported: return "这个服务商不提供向量模型"
        }
    }
}
