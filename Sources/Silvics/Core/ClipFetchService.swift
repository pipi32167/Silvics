import Foundation

enum ClipFetchError: LocalizedError, Equatable {
    case badURL
    case blockedScheme(String)
    case http(Int)
    case notHTML(String)
    case tooLarge
    case timedOut
    case offline
    case empty

    var errorDescription: String? {
        switch self {
        case .badURL: return "地址格式不对"
        case .blockedScheme(let scheme): return "只支持 http 或 https，收到 \(scheme)"
        case .http(let code): return "网页返回 \(code)。\(ProviderProbe.explain(status: code))"
        case .notHTML(let type): return "返回的不是网页（\(type)）"
        case .tooLarge: return "网页超过 5 MB，请改用粘贴正文"
        case .timedOut: return "抓取超时，网络可能不通"
        case .offline: return "连不上网络"
        case .empty: return "网页正文是空的"
        }
    }
}

struct ClipPage: Equatable {
    var url: URL
    var html: String
}

/// 抓网页。只取 HTML，正文抽取交给 `ClipExtractor`。
enum ClipFetchService {

    static let maxBytes = 5 * 1024 * 1024

    static func request(for raw: String, timeout: Int) -> Result<URLRequest, ClipFetchError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased()
        else { return .failure(.badURL) }
        guard scheme == "http" || scheme == "https" else {
            return .failure(.blockedScheme(scheme))
        }
        guard let url = components.url, url.host != nil else { return .failure(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = TimeInterval(max(timeout, 5))
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        return .success(request)
    }

    static func fetch(
        raw: String,
        timeout: Int = 15,
        session: URLSession = .shared
    ) async -> Result<ClipPage, ClipFetchError> {
        let built: URLRequest
        switch request(for: raw, timeout: timeout) {
        case .success(let value): built = value
        case .failure(let error): return .failure(error)
        }

        do {
            let (data, response) = try await session.data(for: built)
            guard let http = response as? HTTPURLResponse else { return .failure(.badURL) }
            guard (200..<300).contains(http.statusCode) else {
                return .failure(.http(http.statusCode))
            }
            guard data.count <= maxBytes else { return .failure(.tooLarge) }

            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            let html = ClipExtractor.decode(data, contentType: contentType)
            let looksHTML = html.range(of: "<html", options: .caseInsensitive) != nil
                || html.range(of: "<body", options: .caseInsensitive) != nil
                || html.range(of: "<article", options: .caseInsensitive) != nil
            if !contentType.isEmpty, !contentType.contains("text/html"),
               !contentType.contains("text/plain"), !contentType.contains("xhtml"),
               !looksHTML {
                return .failure(.notHTML(contentType))
            }
            guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(.empty)
            }
            guard let target = http.url ?? built.url else { return .failure(.badURL) }
            return .success(ClipPage(url: target, html: html))
        } catch let error as URLError where error.code == .timedOut {
            return .failure(.timedOut)
        } catch let error as URLError where error.code == .notConnectedToInternet
            || error.code == .cannotConnectToHost || error.code == .networkConnectionLost {
            return .failure(.offline)
        } catch {
            return .failure(.badURL)
        }
    }
}
