import Foundation

/// LLM 调用失败。`message` 直接显示给用户。
struct LLMError: Error, Equatable, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

struct ChatMessage: Equatable {
    var role: String     // user / assistant / system
    var content: String
}

/// 通用对话请求。三种协议族的请求与响应格式不同，收在这里。
enum ChatClient {

    // MARK: - 请求拼装（可单测，不发网络）

    static func request(
        config: ProviderConfig,
        key: String,
        messages: [ChatMessage],
        maxTokens: Int = 800,
        temperature: Double = 0
    ) -> Result<ProbeRequest, ProviderProbeError> {
        guard let base = config.normalizedBaseURL else { return .failure(.badURL) }
        guard !config.chatModel.isEmpty else { return .failure(.missingModel) }

        switch config.kind {
        case .openAICompatible:
            guard let url = URL(string: base.absoluteString + "/chat/completions") else {
                return .failure(.badURL)
            }
            let body: [String: Any] = [
                "model": config.chatModel,
                "messages": messages.map { ["role": $0.role, "content": $0.content] },
                "max_tokens": maxTokens,
                "temperature": temperature,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: body) else {
                return .failure(.encoding)
            }
            var headers = ["Content-Type": "application/json"]
            if !key.isEmpty { headers["Authorization"] = "Bearer \(key)" }
            return .success(ProbeRequest(url: url, method: "POST", headers: headers, body: data))

        case .anthropic:
            guard let url = URL(string: base.absoluteString + "/v1/messages") else { return .failure(.badURL) }
            let system = messages.first { $0.role == "system" }?.content
            let conversation = messages.filter { $0.role != "system" }
                .map { ["role": $0.role, "content": $0.content] }
            var body: [String: Any] = [
                "model": config.chatModel,
                "max_tokens": maxTokens,
                "temperature": temperature,
                "messages": conversation,
            ]
            if let system { body["system"] = system }
            guard let data = try? JSONSerialization.data(withJSONObject: body) else {
                return .failure(.encoding)
            }
            var headers = [
                "anthropic-version": "2023-06-01",
                "Content-Type": "application/json",
            ]
            if !key.isEmpty { headers["x-api-key"] = key }
            return .success(ProbeRequest(url: url, method: "POST", headers: headers, body: data))

        case .gemini:
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            var raw = base.absoluteString + "/v1beta/models/\(config.chatModel):generateContent"
            if !key.isEmpty { raw += "?key=\(encodedKey)" }
            guard let url = URL(string: raw) else { return .failure(.badURL) }
            let contents = messages.filter { $0.role != "system" }.map { message in
                [
                    "role": message.role == "assistant" ? "model" : "user",
                    "parts": [["text": message.content]],
                ]
            }
            var body: [String: Any] = [
                "contents": contents,
                "generationConfig": ["maxOutputTokens": maxTokens, "temperature": temperature],
            ]
            if let system = messages.first(where: { $0.role == "system" })?.content {
                body["systemInstruction"] = ["parts": [["text": system]]]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: body) else {
                return .failure(.encoding)
            }
            return .success(ProbeRequest(
                url: url, method: "POST", headers: ["Content-Type": "application/json"], body: data
            ))
        }
    }

    // MARK: - 解析响应

    static func parseContent(kind: ProviderKind, data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        switch kind {
        case .openAICompatible:
            guard let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any] else { return nil }
            return message["content"] as? String

        case .anthropic:
            guard let content = json["content"] as? [[String: Any]] else { return nil }
            let texts = content.compactMap { $0["text"] as? String }
            return texts.isEmpty ? nil : texts.joined()

        case .gemini:
            guard let candidates = json["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { return nil }
            let texts = parts.compactMap { $0["text"] as? String }
            return texts.isEmpty ? nil : texts.joined()
        }
    }

    // MARK: - 发送

    static func complete(
        config: ProviderConfig,
        key: String,
        messages: [ChatMessage],
        maxTokens: Int = 800,
        temperature: Double = 0,
        session: URLSession = .shared
    ) async -> Result<String, LLMError> {
        let built: ProbeRequest
        switch request(config: config, key: key, messages: messages, maxTokens: maxTokens, temperature: temperature) {
        case .success(let value): built = value
        case .failure(let error): return .failure(LLMError(message: error.message))
        }

        var urlRequest = URLRequest(url: built.url)
        urlRequest.httpMethod = built.method
        urlRequest.httpBody = built.body
        urlRequest.timeoutInterval = 60
        for (field, value) in built.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { return .failure(LLMError(message: "响应格式不对")) }
            guard (200..<300).contains(http.statusCode) else {
                let snippet = String(decoding: data.prefix(600), as: UTF8.self)
                return .failure(LLMError(message: "\(ProviderProbe.explain(status: http.statusCode))：\(ProviderProbe.errorMessage(from: snippet))"))
            }
            guard let text = parseContent(kind: config.kind, data: data), !text.isEmpty else {
                return .failure(LLMError(message: "模型没有返回正文"))
            }
            return .success(text)
        } catch let error as URLError where error.code == .timedOut {
            return .failure(LLMError(message: "模型响应超时"))
        } catch {
            return .failure(LLMError(message: "请求失败：\(error.localizedDescription)"))
        }
    }
}
