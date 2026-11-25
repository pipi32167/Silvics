import Foundation

/// 把三种输入（网页、粘贴、文件）统一成 `ClipDraft`。
///
/// 这里只做「取到正文 + 元信息」，调模型与落库分别由 `ClipAIService`、`ClipStore` 负责。
enum ClipIngest {

    enum IngestError: LocalizedError, Equatable {
        case emptyBody
        case noTitle

        var errorDescription: String? {
            switch self {
            case .emptyBody: return "没有取到正文，请改用粘贴正文"
            case .noTitle: return "没能确定标题，请手动填写"
            }
        }
    }

    static func draft(fromPage page: ClipPage) throws -> ClipDraft {
        let article = ClipExtractor.extract(html: page.html)
        let body = article.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw IngestError.emptyBody }

        let site = article.site.isEmpty ? (page.url.host ?? "") : article.site
        return ClipDraft(
            url: page.url.absoluteString,
            title: article.title,
            sourceTitle: article.title,
            site: site,
            author: article.author,
            published: article.published,
            body: body
        )
    }

    static func draft(fromText body: String, title: String = "", url: String = "") throws -> ClipDraft {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw IngestError.emptyBody }
        return ClipDraft(url: url, title: title, sourceTitle: title, body: text)
    }

    static func draft(fromFile url: URL) throws -> ClipDraft {
        try ClipFileImport.draft(from: url)
    }

    /// 正文太短时给的提示。返回 nil 表示不用提示。
    static func shortBodyWarning(_ body: String) -> String? {
        guard body.count < ClipExtractor.minBodyLength else { return nil }
        return "抓到的正文只有 \(body.count) 字，可能被登录墙挡住了。可以手动补正文。"
    }
}
