import Foundation

/// 服务端返回的一个模型。`label` 用于展示，`id` 用于请求。
struct ProviderModel: Identifiable, Equatable {
    var id: String
    var label: String
}

/// 拉取 OpenAI 兼容的 `/models` 列表。magpie 的 group 会带 `magpie_label`。
enum ProviderModels {

    static func request(baseURL: URL, key: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// 解析 `{"data":[{"id":…,"magpie_label":…}]}`，也容忍裸数组与 `{"models":[…]}`。
    static func parse(_ data: Data) -> [ProviderModel] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }

        func entries(from raw: Any?) -> [[String: Any]]? {
            if let list = raw as? [[String: Any]] { return list }
            return nil
        }

        var list: [[String: Any]] = []
        if let dict = json as? [String: Any] {
            list = entries(from: dict["data"]) ?? entries(from: dict["models"]) ?? []
        } else if let array = json as? [[String: Any]] {
            list = array
        }

        var seen = Set<String>()
        var models: [ProviderModel] = []
        for entry in list {
            guard let id = entry["id"] as? String ?? entry["name"] as? String, !id.isEmpty else { continue }
            guard seen.insert(id).inserted else { continue }
            let label = entry["magpie_label"] as? String
                ?? entry["display_name"] as? String
                ?? id
            models.append(ProviderModel(id: id, label: label))
        }
        return models.sorted { $0.id < $1.id }
    }

    /// - Returns: 成功是模型列表；失败是给用户看的中文原因。
    static func fetch(
        baseURL: URL,
        key: String,
        session: URLSession = .shared
    ) async -> ModelFetchResult {
        let request = request(baseURL: baseURL, key: key)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.message("响应格式不对")) }
            guard (200..<300).contains(http.statusCode) else {
                return .failure(.message(ProviderProbe.explain(status: http.statusCode)))
            }
            let models = parse(data)
            return models.isEmpty ? .failure(.message("服务返回的模型列表是空的")) : .success(models)
        } catch let error as URLError where error.code == .cannotConnectToHost {
            return .failure(.message("连不上本地服务，确认它已经启动"))
        } catch let error as URLError where error.code == .timedOut {
            return .failure(.message("拉取模型列表超时"))
        } catch {
            return .failure(.message("拉取失败：\(error.localizedDescription)"))
        }
    }
}

enum ModelFetchResult {
    case success([ProviderModel])
    case failure(ModelFetchFailure)

    var models: [ProviderModel]? {
        if case .success(let list) = self { return list }
        return nil
    }

    var message: String? {
        if case .failure(let failure) = self { return failure.text }
        return nil
    }
}

enum ModelFetchFailure {
    case message(String)

    var text: String {
        switch self {
        case .message(let text): return text
        }
    }
}
