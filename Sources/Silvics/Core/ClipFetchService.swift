import Foundation

enum ClipFetchError: LocalizedError, Equatable {
    case badURL
    case blockedScheme(String)
    case http(Int)
    case notHTML(String)
    case tooLarge
    case pdfTooLarge(Int)
    case timedOut
    case offline
    case empty

    static func httpMessage(_ code: Int) -> String {
        switch code {
        case 401, 403: return "网页拒绝访问（可能需要登录）"
        case 404: return "网页不存在（404）"
        case 410: return "网页已删除（410）"
        case 429: return "请求太频繁（429），稍后再试"
        case 500...599: return "站点出错（\(code)），稍后再试"
        default: return "网页返回 \(code)"
        }
    }

    var errorDescription: String? {
        switch self {
        case .badURL: return "地址格式不对"
        case .blockedScheme(let scheme): return "只支持 http 或 https，收到 \(scheme)"
        case .http(let code): return Self.httpMessage(code)
        case .notHTML(let type): return "返回的不是网页（\(type)）"
        case .tooLarge: return "网页超过 5 MB，请改用粘贴正文"
        case .pdfTooLarge(let bytes):
            return String(format: "这个 PDF 有 %.1f MB，超过 20 MB，请先下载再拖进来", Double(bytes) / 1024 / 1024)
        case .timedOut: return "抓取超时，网络可能不通"
        case .offline: return "连不上网络"
        case .empty: return "网页正文是空的"
        }
    }
}

struct ClipPage: Equatable {

    /// 抓回来的东西只有两种：网页（HTML 文本）与 PDF（原始字节）。
    enum Payload: Equatable {
        case html(String)
        case pdf(Data)
    }

    var url: URL
    var payload: Payload

    init(url: URL, payload: Payload) {
        self.url = url
        self.payload = payload
    }

    init(url: URL, html: String) {
        self.init(url: url, payload: .html(html))
    }

    init(url: URL, pdf: Data) {
        self.init(url: url, payload: .pdf(pdf))
    }

    /// HTML 正文。PDF 时为空串，调用方先看 `payload`。
    var html: String {
        if case .html(let text) = payload { return text }
        return ""
    }

    var isPDF: Bool {
        if case .pdf = payload { return true }
        return false
    }
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
        request.setValue("text/html,application/xhtml+xml,application/pdf;q=0.9,text/plain;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
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

            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            guard let target = http.url ?? built.url else { return .failure(.badURL) }

            // PDF：同时看魔数、响应头、扩展名，服务器常把 PDF 报成 octet-stream。
            if isPDF(data: data, contentType: contentType, url: target) {
                guard data.count <= ClipPDFImport.maxDownloadBytes else {
                    return .failure(.pdfTooLarge(data.count))
                }
                return .success(ClipPage(url: target, pdf: data))
            }

            guard data.count <= maxBytes else { return .failure(.tooLarge) }

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

    /// 判是不是 PDF。魔数最可靠；其次响应头；最后是「octet-stream 或没报 + 地址以 .pdf 结尾」。
    static func isPDF(data: Data, contentType: String, url: URL) -> Bool {
        if data.starts(with: Array("%PDF-".utf8)) { return true }
        if contentType.contains("application/pdf") { return true }
        let loose = contentType.contains("octet-stream") || contentType.isEmpty
        return loose && url.pathExtension.lowercased() == "pdf"
    }
}
